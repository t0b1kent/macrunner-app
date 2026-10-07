#!/usr/bin/env python3
"""Assemble the self-contained engine package embedded in MacRunner.app (Contents/Resources/engine).

    python3 build/repro109app/assemble_engine.py work/engine-inputs.json OUT_DIR [--strip-pe] [--defer-signing]

Layout of OUT_DIR:
    wine/bin/{wine,wine-preloader,wineserver}   wine/lib/wine/<arch>/...   wine/share/wine/...
    fex/{aarch64-windows,aarch64-unix}/...       graphics/{x86_64-windows,aarch64-unix,x86_64-unix}/...
    wine/lib/wine/aarch64-unix/*.dylib            selected source-built dylibs, ids rewritten to @rpath
    media/gstreamer-1.0/*.dylib                  offline playback, demux, parser and software decoder plugins
    media/bin/gst-plugin-scanner                scanner from the same GStreamer installation as Wine's core
    licenses/                                     third-party license texts found next to the sources
    ENGINE.json                                   name, environment template, sha256 of every file

Rules: symlinks are resolved; backup copies (*.БЫЛО-*, *.BYLO-*, *.NOVYJ, .DS_Store) are skipped.
By default, rewritten Mach-O files are signed ad hoc with their original entitlements.
--defer-signing performs no signature inspection or signing; the SHA-pinned entitlement intent is
preserved for the owner's final signing. This mode does not claim a launchable or signed engine.
--strip-pe removes DWARF sections from PE modules and verifies the "Wine builtin DLL" marker survives.
Dylibs go next to the Wine unix modules, not into a separate lib/: win32u.so loads
"@loader_path/libfreetype.6.dylib", bcrypt.so and winebus.so dlopen gnutls/SDL2 by leaf name through their
LC_RPATH "@loader_path/". So the engine needs no DYLD_* variables, which a hardened-runtime process never gets.
The engine itself is not modified otherwise: the environment is copied from the working launch record.
"""
import hashlib, json, os, plistlib, re, shutil, subprocess, sys, tempfile
from pathlib import Path

SKIP = re.compile(r'(\.БЫЛО-|\.BYLO-|\.NOVYJ$|\.DS_Store$|\.orig$|\.rej$)')
SYSTEM_PREFIXES = ('/usr/lib/', '/System/')
BUILTIN_MARKER = b'Wine builtin DLL'
GSTREAMER_CORE = 'libgstreamer-1.0.0.dylib'
# A stable offline-media capability set, not the host's entire plugin directory
# (which also contains camera, GPU, network, cloud and language-runtime plugins).
# libav supplies additional software codecs used by Windows Media Foundation.
GSTREAMER_PLUGINS = tuple(sorted((
    'coreelements', 'app', 'playback', 'typefindfunctions',
    'audioconvert', 'audioresample', 'videoconvertscale', 'volume',
    # Wine 11's raw-video parser always creates deinterlace and videoflip;
    # codec discovery alone does not exercise these converter dependencies.
    # https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/winegstreamer/wg_parser.c
    'deinterlace', 'videofilter',
    'rawparse', 'audioparsers', 'videoparsersbad',
    'isomp4', 'matroska', 'avi', 'asf', 'flv', 'ogg', 'wavparse', 'aiff',
    'mpegpsdemux', 'mpegtsdemux', 'libav', 'vorbis', 'opus', 'theora',
    'flac', 'mpg123', 'vpx', 'jpeg', 'png', 'subparse',
)))


def die(msg):
    sys.exit('assemble_engine: ' + msg)


def run(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode:
        die(f'{" ".join(map(str, cmd))} failed: {r.stderr.strip()[:400]}')
    return r


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def copy_tree(src, dst):
    """Copy with symlinks resolved; skip backups. Returns number of files."""
    src, dst, count = Path(src), Path(dst), 0
    for root, dirs, files in os.walk(src, followlinks=True):
        dirs[:] = [d for d in dirs if not SKIP.search(d)]
        rel = Path(root).relative_to(src)
        (dst / rel).mkdir(parents=True, exist_ok=True)
        for name in files:
            if SKIP.search(name):
                continue
            s = Path(root) / name
            if not s.exists():
                die(f'dangling link {s}')
            shutil.copy2(s.resolve(), dst / rel / name)
            count += 1
    return count


def is_macho(path):
    try:
        with open(path, 'rb') as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xce\xfa\xed\xfe')


def parse_macho_info(output):
    """Keep library IDs distinct from dependencies: executables have no ID."""
    result = {'id': None, 'deps': [], 'rpaths': []}
    for block in re.split(r'Load command \d+\s*\n', output)[1:]:
        command = re.search(r'^\s*cmd (LC_\w+)', block, re.M)
        if not command:
            continue
        command = command.group(1)
        value = re.search(r'^\s*(?:name|path) (.+) \(offset \d+\)', block, re.M)
        if not value:
            continue
        value = value.group(1)
        if command == 'LC_ID_DYLIB':
            result['id'] = value
        elif command == 'LC_RPATH':
            if value not in result['rpaths']:
                result['rpaths'].append(value)
        elif command in {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB',
                         'LC_LAZY_LOAD_DYLIB', 'LC_LOAD_UPWARD_DYLIB'}:
            if value not in result['deps']:
                result['deps'].append(value)
    return result


def macho_info(path):
    return parse_macho_info(run('otool', '-l', str(path)).stdout)


def macho_deps(path):
    return macho_info(path)['deps']


def external_reference(value):
    return value.startswith('/') and not value.startswith(SYSTEM_PREFIXES)


def load_config(path, strip_pe=False):
    """Resolve selected build outputs relative to this config, never to the host."""
    path = Path(path).resolve()
    config = json.loads(path.read_bytes())
    def selected(value):
        if not isinstance(value, str) or not value:
            die('selected path must be a nonempty string')
        return str((path.parent / value).resolve())
    for field in ('wine', 'fex', 'graphics', 'wineEntitlements'):
        config[field] = selected(config[field])
    roots = config.get('dependencyRoots')
    if not isinstance(roots, list) or not roots:
        die('dependencyRoots must explicitly select source-built prefixes')
    config['dependencyRoots'] = [selected(value) for value in roots]
    if any(not Path(value).is_dir() for value in config['dependencyRoots']):
        die('selected dependency root is not a directory')
    licenses = config.get('licenseInputs')
    if not isinstance(licenses, list) or not licenses:
        die('licenseInputs must explicitly select pinned license files')
    names = set()
    for row in licenses:
        if not isinstance(row, dict):
            die('license input must be an object')
        name = row.get('name')
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,95}', name) or name in names:
            die('license input name is invalid or duplicated')
        names.add(name)
        row['path'] = selected(row.get('path'))
        if not re.fullmatch(r'[0-9a-f]{64}', str(row.get('sha256', ''))) or sha256(row['path']) != row['sha256']:
            die('license input SHA256 mismatch: ' + name)
    config['dlopenLibraries'] = [selected(value) for value in config.get('dlopenLibraries', [])]
    if strip_pe:
        config['stripTool'] = selected(config.get('stripTool'))
        if not re.fullmatch(r'[0-9a-f]{64}', str(config.get('stripToolSHA256', ''))) or sha256(config['stripTool']) != config['stripToolSHA256']:
            die('selected llvm-strip SHA256 mismatch')
    return config


def selected_dependency(path, roots):
    real = Path(path).resolve()
    if not any(real == root or root in real.parents for root in map(Path, roots)):
        die('dependency is outside selected source-built prefixes: ' + str(path))
    if not real.is_file():
        die('missing dependency ' + str(path))
    return real


def dependency_closure(machos, libdir, roots, extra=(), media=None):
    """Use the existing closure traversal for arbitrary selected build prefixes."""
    queue = [Path(value) for value in extra]
    for macho in machos:
        queue.extend(Path(dep) for dep in macho_deps(macho) if external_reference(dep))
    bundled, inputs = {}, {}
    while queue:
        queue.sort(key=str, reverse=True)
        dep = queue.pop()
        real = selected_dependency(dep, roots)
        digest = sha256(real)
        if dep.name in inputs:
            if inputs[dep.name]['sha256'] != digest:
                die('conflicting dependency sources for ' + dep.name)
            continue
        if media and dep.name.startswith('libgst') and real.parent != media['root'] / 'lib':
            die('GStreamer dependency is outside the selected core installation: ' + str(real))
        inputs[dep.name] = {'source': str(real), 'sha256': digest}
        target = libdir / dep.name
        if target.exists():
            if sha256(target) != digest:
                die('Wine dist dependency differs from selected input: ' + dep.name)
            bundled[dep.name] = 'wine-dist'
        else:
            shutil.copy2(real, target)
            os.chmod(target, 0o755)
            bundled[dep.name] = str(real)
        for value in macho_deps(real):
            if external_reference(value):
                queue.append(Path(value))
            elif value.startswith(('@loader_path/', '@rpath/')):
                # Preserve the original sibling rule; this is not a dyld loader.
                sibling = real.parent / value.split('/', 1)[1]
                if sibling.exists():
                    queue.append(sibling)
    return bundled, inputs


def relocation_args(info, path, libdir, bundled):
    """Return a complete relocation, including plugin IDs and scanner rpaths."""
    args = []
    for dep in info['deps']:
        if external_reference(dep) and Path(dep).name in bundled:
            args += ['-change', dep, '@rpath/' + Path(dep).name]
    if info['id'] and external_reference(info['id']):
        args += ['-id', '@rpath/' + Path(path).name]
    for rpath in info['rpaths']:
        if external_reference(rpath):
            args += ['-delete_rpath', rpath]
    if args:
        rel = os.path.relpath(libdir, Path(path).parent)
        rpath = '@loader_path/' + rel if rel != '.' else '@loader_path'
        if rpath.rstrip('/') not in [p.rstrip('/') for p in info['rpaths']]:
            args += ['-add_rpath', rpath]
    return args


def discover_gstreamer(wine_module):
    """Derive plugin provenance from Wine's actual linked core, never live PATH."""
    wine_module = Path(wine_module)
    if not wine_module.exists():
        return None
    cores = {Path(d).resolve() for d in macho_deps(wine_module)
             if Path(d).name == GSTREAMER_CORE and d.startswith('/')}
    if len(cores) != 1:
        die('winegstreamer requires exactly one absolute GStreamer core source; '
            'cannot infer matching plugins from a relocated or incomplete runtime')
    core = cores.pop()
    if not core.is_file() or not is_macho(core):
        die(f'missing or invalid GStreamer core {core}')
    root = core.parent.parent
    plugin_dir = root / 'lib/gstreamer-1.0'
    scanner = root / 'libexec/gstreamer-1.0/gst-plugin-scanner'
    sources = [(plugin_dir / f'libgst{n}.dylib', f'media/gstreamer-1.0/libgst{n}.dylib')
               for n in GSTREAMER_PLUGINS]
    sources.append((scanner, 'media/bin/gst-plugin-scanner'))
    for src, _ in sources:
        if not src.is_file() or not is_macho(src):
            die(f'missing GStreamer media component {src}')
        if not src.resolve().is_relative_to(root):
            die(f'GStreamer media component escapes core installation: {src}')
        linked = []
        for dep in macho_deps(src):
            if Path(dep).name == GSTREAMER_CORE:
                linked.append(Path(dep).resolve() if dep.startswith('/') else
                              (root / 'lib' / Path(dep).name).resolve())
        if linked != [core]:
            die(f'GStreamer media component uses a different or missing core: {src}')
    return {'root': root, 'core': core, 'sources': sources}


def stage_gstreamer(media, out):
    if media is None:
        return None
    inputs = {}
    for source, relative in media['sources']:
        target = out / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source.resolve(), target)
        os.chmod(target, 0o755)
        inputs[relative] = {'source': str(source.resolve()), 'sha256': sha256(source)}
    return {'coreSource': str(media['core']), 'coreSHA256': sha256(media['core']),
            'installation': str(media['root']), 'plugins': list(GSTREAMER_PLUGINS),
            'inputs': inputs}


def media_environment(environment):
    result = dict(environment)
    # Both forms are set because GStreamer versions prefer the suffixed form,
    # then consult the unsuffixed fallback. Never inherit the host registry.
    for key, value in {
        'GST_PLUGIN_PATH': '',
        'GST_PLUGIN_SYSTEM_PATH': '${ENGINE}/media/gstreamer-1.0',
        'GST_PLUGIN_SCANNER': '${ENGINE}/media/bin/gst-plugin-scanner',
        'GST_REGISTRY': '${DATA}/gstreamer-registry.bin',
    }.items():
        result[key] = result[key + '_1_0'] = value
    return result


def entitlements(path):
    r = run('codesign', '-d', '--entitlements', ':-', str(path), check=False)
    data = r.stdout.encode() if r.stdout.strip().startswith('<?xml') else b''
    return plistlib.loads(data) if data else None


def assembly_options(argv):
    flags = argv[3:]
    if not 3 <= len(argv) <= 5 or len(set(flags)) != len(flags) or any(
            flag not in ('--strip-pe', '--defer-signing') for flag in flags):
        die(__doc__)
    return '--strip-pe' in flags, '--defer-signing' in flags


def signing_intent(config):
    """Read exact, explicitly pinned source bytes without inspecting any identity."""
    expected = config.get('wineEntitlementsSHA256')
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        die('wineEntitlementsSHA256 is required for deferred signing')
    path = Path(config['wineEntitlements'])
    if not path.is_file():
        die('deferred signing intent is not a file')
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected:
        die('deferred signing intent SHA256 mismatch')
    try:
        wanted = plistlib.loads(raw)
    except Exception:
        die('deferred signing intent must be a valid plist')
    if not isinstance(wanted, dict) or not wanted:
        die('deferred signing intent must be a nonempty dictionary')
    return raw


def wine_runtime_layout(wine):
    """Preserve Wine's installed dispatcher/native layout or its older bin layout."""
    wine = Path(wine)
    for name in ('wine', 'wineserver'):
        if not (wine / 'bin' / name).is_file():
            die('missing Wine runtime program: bin/' + name)
    native = wine / 'lib/wine/aarch64-unix'
    if (native / 'wine').is_file():
        if not (native / 'wine-preloader').is_file():
            die('missing Wine runtime program: lib/wine/aarch64-unix/wine-preloader')
        programs = ['wine', 'wineserver']
        if (wine / 'bin/wine-preloader').is_file():
            programs.insert(1, 'wine-preloader')
        return dict(layout='MULTIARCH_DISPATCHER', bin_programs=programs,
                    loader='lib/wine/aarch64-unix/wine',
                    preloader='lib/wine/aarch64-unix/wine-preloader')
    if not (wine / 'bin/wine-preloader').is_file():
        die('missing Wine runtime program: bin/wine-preloader; no multiarch native loader')
    return dict(layout='LEGACY_BIN', bin_programs=['wine', 'wine-preloader', 'wineserver'],
                loader='bin/wine', preloader='bin/wine-preloader')


def main(argv):
    strip_pe, defer_signing = assembly_options(argv)
    config, out = load_config(argv[1], strip_pe), Path(argv[2]).resolve()
    if defer_signing:
        signing_intent(config)  # Reject missing/corrupt intent before creating any output.
    if out.exists():
        die(f'{out} exists; assemble into a new directory')
    wine = Path(config['wine'])
    wine_runtime = wine_runtime_layout(wine)
    out.mkdir(parents=True)
    report = {'name': config['name'], 'sources': {}, 'counts': {},
              'wineRuntime': wine_runtime}

    # 1. Wine: only the runtime parts, not build tools or old copies in bin/.
    (out / 'wine/bin').mkdir(parents=True)
    for name in wine_runtime['bin_programs']:
        shutil.copy2((wine / 'bin' / name).resolve(), out / 'wine/bin' / name)
    report['counts']['wine/lib'] = copy_tree(wine / 'lib/wine', out / 'wine/lib/wine')
    report['counts']['wine/share'] = copy_tree(wine / 'share/wine', out / 'wine/share/wine')
    report['sources']['wine'] = str(wine)
    media = discover_gstreamer(wine / 'lib/wine/aarch64-unix/winegstreamer.so')
    if media:
        for source, _ in media['sources']:
            selected_dependency(source, config['dependencyRoots'])
        report['gstreamer'] = stage_gstreamer(media, out)
        report['counts']['mediaPlugins'] = len(GSTREAMER_PLUGINS)

    # 2. FEX and DXMT graphics as separate trees, exactly as the working launch uses them.
    report['counts']['fex'] = copy_tree(config['fex'], out / 'fex')
    report['counts']['graphics'] = copy_tree(config['graphics'], out / 'graphics')
    report['sources'].update(fex=config['fex'], graphics=config['graphics'])
    for extra in ('BUNDLE.json', 'MANIFEST.json', 'previous-d3d9.dll'):
        for base in (out / 'fex', out / 'graphics'):
            if (base / extra).exists():
                (base / extra).unlink()

    # 3. Strip DWARF from PE modules (optional), keeping the builtin marker.
    if strip_pe:
        strip, stripped = config['stripTool'], 0
        for p in out.rglob('*'):
            if p.is_file() and p.suffix.lower() in ('.dll', '.exe', '.sys', '.drv', '.ocx', '.cpl', '.acm', '.ax', '.tlb', '.com'):
                head = p.read_bytes()[:0x60]
                if head[:2] != b'MZ':
                    continue
                marker = BUILTIN_MARKER in head
                run(str(strip), '--strip-debug', str(p))
                if marker and BUILTIN_MARKER not in p.read_bytes()[:0x60]:
                    die(f'strip lost the builtin marker: {p}')
                stripped += 1
        report['counts']['strippedPE'] = stripped

    # 4. Source-built dylib closure: linked deps plus explicit dlopen libraries.
    libdir = out / 'wine/lib/wine/aarch64-unix'
    machos = [p for p in sorted(out.rglob('*')) if p.is_file() and not p.is_symlink() and is_macho(p)]
    bundled, dependency_inputs = dependency_closure(
        machos, libdir, config['dependencyRoots'], config['dlopenLibraries'], media)
    report['bundledLibraries'] = bundled
    report['dependencyInputs'] = dependency_inputs

    # 5. Rewrite references; final cloud assembly can defer all signing to the owner.
    rewritten = []
    added = [libdir / n for n, src in bundled.items() if src != 'wine-dist']
    for m in [x for x in machos if x not in added] + added:
        args = relocation_args(macho_info(m), m, libdir, bundled)
        if not args:
            continue
        ent = entitlements(m) if not defer_signing else None
        run('install_name_tool', *args, str(m))
        if not defer_signing:
            sign = ['codesign', '-f', '-s', '-']
            if ent:
                with tempfile.NamedTemporaryFile(suffix='.plist') as t:
                    plistlib.dump(ent, t)
                    t.flush()
                    run(*sign, '--entitlements', t.name, str(m))
            else:
                run(*sign, str(m))
        rewritten.append(str(m.relative_to(out)))
    report['rewrittenMachO'] = rewritten

    # 6. Preserve exact signing intent or check the selected native loader's keys.
    if defer_signing:
        raw_intent = signing_intent(config)  # Recheck after input copying/relocation.
        intent_path = 'signing/wine-loader.entitlements.plist'
        (out / 'signing').mkdir()
        (out / intent_path).write_bytes(raw_intent)
        report['signing'] = dict(mode='DEFERRED_FOR_OWNER', intent_path=intent_path,
                                 intent_sha256=hashlib.sha256(raw_intent).hexdigest(),
                                 actual_entitlements='NOT_ENABLED', signature_validation='NOT_ENABLED',
                                 adhoc_signing='NOT_ENABLED', final_owner_signing_required=True)
    else:
        with open(config['wineEntitlements'], 'rb') as stream:
            want = plistlib.load(stream)
        got = entitlements(out / 'wine' / wine_runtime['loader']) or {}
        if got != want:
            die('wine loader entitlements mismatch (values omitted)')
        report['signing'] = dict(mode='ADHOC_RELOCATION', actual_entitlements='EXPECTED_KEYS_MATCH',
                                 signature_validation='NOT_ENABLED', final_owner_signing_required=True)

    # 7. Leftover references to Homebrew or the repository are a packaging bug.
    leaks = []
    for m in [p for p in out.rglob('*') if p.is_file() and is_macho(p)]:
        info = macho_info(m)
        references = info['deps'] + info['rpaths'] + ([info['id']] if info['id'] else [])
        leaks += [f'{m.relative_to(out)} -> {d}' for d in references if external_reference(d)]
    if leaks:
        die('absolute references remain:\n' + '\n'.join(leaks[:40]))

    # 8. Byte-pinned licenses selected by the source build, never host kegs.
    lic = out / 'licenses'
    lic.mkdir()
    report['licenseInputs'] = config['licenseInputs']
    for row in config['licenseInputs']:
        if sha256(row['path']) != row['sha256']:
            die('license input changed during assembly: ' + row['name'])
        shutil.copy2(row['path'], lic / row['name'])

    # 9. Graphics capability matrix (authored in the sources list with evidence): every layer must be complete
    #    in the package, every route must name a known layer, "wine", or nothing.
    graphics = config.get('graphicsMatrix')
    if graphics:
        statuses = {'verified', 'fixtures', 'experimental', 'unavailable', 'deferred'}
        layer_ids = set()
        for layer in graphics['layers']:
            layer_ids.add(layer['id'])
            wanted = [f'{d}/{m}' for d, mods in layer['modules'].items() for m in mods] + layer.get('unix', [])
            missing = [w for w in wanted if not (out / w).is_file()]
            if missing:
                die(f'graphics layer {layer["id"]} incomplete in package: {missing}')
        for route in graphics['routes']:
            if route['status'] not in statuses:
                die(f'bad route status {route}')
            if route.get('layer') not in layer_ids | {'wine', None}:
                die(f'route names unknown layer {route}')
            if route['status'] in ('verified', 'fixtures') and not route.get('evidence'):
                die(f'route claims {route["status"]} without evidence {route}')
        for arch in graphics.get('architectures', []):
            if arch['status'] not in statuses:
                die(f'bad architecture status {arch}')
        report['graphicsRoutes'] = len(graphics['routes'])

    # 10. Manifest.
    files = {str(p.relative_to(out)): sha256(p) for p in sorted(out.rglob('*')) if p.is_file()}
    environment = media_environment(config['environment']) if media else config['environment']
    manifest = {'schema': 2 if graphics else 1, 'name': config['name'], 'environment': environment,
                **({'graphics': graphics} if graphics else {}),
                'launcher': 'wine/bin/wine', 'wineserver': 'wine/bin/wineserver',
                'report': report, 'files': files}
    (out / 'ENGINE.json').write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
    size = sum(p.stat().st_size for p in out.rglob('*') if p.is_file())
    print(json.dumps({'out': str(out), 'files': len(files), 'bytes': size, 'counts': report['counts'],
                      'bundledLibraries': len(bundled), 'rewrittenMachO': len(rewritten),
                      'licenseInputs': len(config['licenseInputs']),
                      'licenseCoverage': 'INPUTS_HASHED_COMPONENT_MAPPING_NOT_AUDITED'}, ensure_ascii=False))


if __name__ == '__main__':
    main(sys.argv)

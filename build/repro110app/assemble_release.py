#!/usr/bin/env python3
"""Compose the complete release on GitHub from identified successful source-build artifacts."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import assemble_engine as engine


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def unpack(archive, destination):
    if destination.exists() or destination.is_symlink():
        raise ValueError('Fresh release extraction destination required')
    with tarfile.open(archive) as stream:
        rows = stream.getmembers()
        if len(rows) > 300000 or sum(x.size for x in rows) > 3 * 1024**3:
            raise ValueError('Release input tar exceeds cap')
        destination.mkdir(parents=True)
        stream.extractall(destination, members=rows, filter='data')


def artifact(pin, destination, transport, reports):
    transport.REPO = pin['repo']
    run = transport.api('/actions/runs/' + str(pin['run']))
    if run['head_sha'] != pin['revision'] or run['status'] != 'completed':
        raise ValueError('Source producer revision/state differs')
    if pin.get('job'):
        jobs = transport.api('/actions/runs/' + str(pin['run']) + '/jobs?per_page=100')['jobs']
        if not any(x['name'] == pin['job'] and x['conclusion'] == 'success' for x in jobs):
            raise ValueError('Selected source producer job did not succeed')
    elif run['conclusion'] != 'success':
        raise ValueError('Selected source producer run did not succeed')
    metadata = transport.api('/actions/artifacts/' + str(pin['artifact']))
    if metadata['expired'] or metadata['workflow_run']['id'] != pin['run'] or metadata['digest'] != 'sha256:' + pin['sha256']:
        raise ValueError('Source artifact identity differs')
    (reports / (destination.name + '-artifact.json')).write_text(json.dumps(metadata, indent=2) + '\n')
    archive = destination.with_suffix('.zip')
    transport.download_artifact(pin['artifact'], archive, pin['sha256'], reports)
    transport.unpack_zip(archive, destination)
    return destination


def receipt(path, expected):
    value = json.loads(path.read_text())
    if value.get('status') != expected or value.get('first_failure') is not None or value.get('install_skipped') != 0:
        raise ValueError('Source producer receipt is incomplete: ' + str(path))
    return value


def merge_tree(source, destination):
    """Merge immutable source outputs; collisions must be byte identical."""
    for path in sorted(source.rglob('*')):
        if not path.is_file():
            continue
        if path.is_symlink():
            raise ValueError('Unexpected link in flat runtime source output')
        target = destination / path.relative_to(source)
        if target.exists():
            if sha(path) != sha(target):
                raise ValueError('Runtime source collision: ' + str(path.relative_to(source)))
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)


def source_libraries(names, directories):
    libraries, missing = [], []
    for name in names:
        found = [root / name for root in directories if (root / name).is_file()]
        if not found:
            missing.append(name)
        elif len({sha(path) for path in found}) != 1:
            raise ValueError('Conflicting selected dependency: ' + name)
        else:
            libraries.append(str(found[0]))
    if missing:
        raise ValueError('Source dependency leaves missing: ' + ', '.join(missing))
    return libraries


def license_inputs(roots):
    selected = []
    for namespace, root in roots:
        for path in sorted(root.rglob('*')):
            if not path.is_file() or path.is_symlink():
                continue
            relative = str(path.relative_to(root))
            name = namespace + '-' + re.sub('[^A-Za-z0-9_.-]', '_', relative)
            if len(name) > 95:
                name = name[:80] + '-' + hashlib.sha256(relative.encode()).hexdigest()[:12]
            selected.append(dict(name=name, path=str(path), sha256=sha(path)))
    return selected


def require_tools():
    for name in ['gh', 'tar', 'install_name_tool', 'xcrun']:
        if shutil.which(name) is None:
            raise ValueError('Required release composition tool missing: ' + name)


def source_inputs(args):
    selected = [args.transport, args.wine / 'build/repro110wine/build_wine.py',
                args.wine / 'build/repro110wine/full.lock.json',
                args.dxmt / 'build/repro109dxmt/repro109_dxmt_after_wine27.py',
                args.hyperbridge / 'build/repro110fex/c32/ENGINE.json']
    missing = [str(path) for path in selected if not path.is_file()]
    if missing:
        raise ValueError('Required source recipe inputs missing: ' + ', '.join(missing))
    return [dict(path=str(path), sha256=sha(path)) for path in selected]


def build(args):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('Whole release composition requires the native ARM64 GitHub builder')
    require_tools()
    source_receipts = source_inputs(args)
    args.work.mkdir(parents=True, exist_ok=False)
    reports = args.work / 'reports'; reports.mkdir()
    result = dict(status='STARTED', first_failure=None, install_skipped=0, inputs={}, commands=[],
                  games='NOT_ENABLED', signing='DEFERRED_FOR_OWNER', release_gates='NOT_RUN',
                  source_recipes=source_receipts)
    def run(name, argv):
        path = reports / (name + '.log')
        started = time.monotonic()
        with path.open('xb') as stream:
            child = subprocess.run([str(x) for x in argv], stdin=subprocess.DEVNULL,
                                   stdout=stream, stderr=subprocess.STDOUT, timeout=1800)
        result['commands'].append(dict(name=name, rc=child.returncode, sha256=sha(path),
                                       seconds=round(time.monotonic() - started, 3)))
        if child.returncode or path.stat().st_size > 32 * 1024**2:
            raise ValueError(name + ' failed; complete raw log retained')
    try:
        pins = json.loads(args.pins.read_text())
        names = ['app', 'helpers', 'inno', 'fex64', 'fex32', 'graphics_x64', 'graphics_ec', 'graphics_native']
        if set(pins) != set(names):
            raise ValueError('Exactly the selected release source components are required')
        transport = load_module('release_source_transport', args.transport)
        # The existing receiver restores source Wine/deps/MoltenVK/LLVM and the pinned compiler.
        restored = args.work / 'source-runtime'
        if transport.restore(argparse.Namespace(work=restored, wine=args.wine, dxmt=args.dxmt)) != 0:
            raise ValueError('Source-built runtime dependency restoration failed')
        paths = json.loads((restored / 'reports/RESULT.json').read_text())['paths']
        components = args.work / 'components'; components.mkdir()
        roots = {name: artifact(pins[name], components / name, transport, reports) for name in names}
        result['inputs'] = pins
        app_report = receipt(roots['app'] / 'repro110-app-results/APP-RESULT.json',
                             'APP_SOURCE_COMPILED_TESTED_NOT_WHOLE_BUNDLE')
        if app_report['swift_tests'].get('unexplained_failures'):
            raise ValueError('Application source test failures remain unexplained')
        archive = roots['app'] / 'app-prefix.tar.gz'
        if sha(archive) != Path(str(archive) + '.sha256').read_text().split()[0]:
            raise ValueError('Application prefix tar differs')
        prefix = args.work / 'app-prefix'; unpack(archive, prefix)
        app = prefix / 'MacRunner.app'; contents = app / 'Contents'; resources = contents / 'Resources'
        info = plistlib.loads((contents / 'Info.plist').read_bytes())
        if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != ('1.1.1', '120'):
            raise ValueError('Application release metadata differs')
        helpers_report = receipt(roots['helpers'] / 'release110-helpers/reports/RESULT.json',
                                 'SOURCE_HELPERS_BUILT_NOT_FINAL_APP')
        archive = roots['helpers'] / 'release110-helper-products/helpers.tar.gz'
        if sha(archive) != helpers_report['archive']['sha256']:
            raise ValueError('Helper product tar differs')
        helpers = args.work / 'helpers'; unpack(archive, helpers)
        (resources / 'tools').mkdir(exist_ok=True)
        for name in ['legendary', 'gogdl']:
            if not os.access(helpers / name, os.X_OK):
                raise ValueError('Source helper lost executable mode: ' + name)
            shutil.copy2(helpers / name, resources / 'tools' / name)
        shutil.copytree(helpers / 'licenses', resources / 'licenses/python-helpers')
        receipt(roots['inno'] / 'release110-inno/reports/RESULT.json', 'INNOEXTRACT_SOURCE_BUILT_SIGNING_DEFERRED')
        archive = roots['inno'] / 'innoextract.tar.gz'
        if sha(archive) != Path(str(archive) + '.sha256').read_text().split()[0]:
            raise ValueError('Installer product tar differs')
        installer = args.work / 'installer'; unpack(archive, installer)
        shutil.copytree(installer / 'innoextract', resources / 'tools/innoextract')
        fex = args.work / 'fex'
        for name in ['fex64', 'fex32']:
            merge_tree(roots[name] / ('build/' + name + '/engine/fex'), fex)
        template = json.loads((args.hyperbridge / 'build/repro110fex/c32/ENGINE.json').read_text())
        for name in ['xtajit.dll', 'xtajit64.dll']:
            path = fex / 'aarch64-windows' / name
            if sha(path) != template['files']['fex/aarch64-windows/' + name]:
                raise ValueError('Translator output differs from the accepted c32 bytes: ' + name)
        graphics = args.work / 'graphics'; graphics.mkdir()
        for name, architecture in [('graphics_x64', 'x86_64-windows'), ('graphics_ec', 'aarch64-windows'),
                                    ('graphics_native', 'aarch64-unix')]:
            detail = receipt(roots[name] / 'release110-graphics-build/reports/RESULT.json',
                             'GRAPHICS_SOURCE_BUILT_NOT_RELEASE_ACCEPTED')
            archive = roots[name] / ('graphics-' + ('native' if name.endswith('native') else 'ec' if name.endswith('ec') else 'x64') + '.tar.gz')
            if sha(archive) != Path(str(archive) + '.sha256').read_text().split()[0]:
                raise ValueError('Graphics output tar differs')
            unpack(archive, graphics / architecture)
            for row in detail['outputs']:
                if sha(graphics / architecture / row['path']) != row['sha256']:
                    raise ValueError('Graphics source output identity differs')
        # The converter CLI is retained in diagnostic outputs, outside the shipping graphics tree.
        cli = graphics / 'aarch64-unix/airconv'
        diagnostics = args.work / 'diagnostic-tools'; diagnostics.mkdir()
        shutil.move(cli, diagnostics / 'airconv')
        (diagnostics / 'airconv').chmod(0o755)
        tools_work = args.work / 'engine-tools'
        run('engine-tools', [sys.executable, '-I', '-B', HERE / 'build_engine_tools.py', '--build',
                            '--work', tools_work, '--mingw-bin', Path(paths['compiler']) / 'bin'])
        tools = json.loads((tools_work / 'RESULT.json').read_text())
        if tools.get('status') != 'ENGINE_TOOLS_BUILT_AS_ACCEPTED':
            raise ValueError('Engine tool source build incomplete: ' + str(tools.get('status')))
        source_roots = [Path(paths['deps']), Path(paths['moltenvk'])]
        required_libraries = sorted(Path(name).name for name in template['files']
                                    if name.startswith('wine/lib/wine/aarch64-unix/') and name.endswith('.dylib'))
        # FEX produces its native TSO companion, not Wine or the third-party dependency prefix.
        libraries = source_libraries(required_libraries,
                                     [root / 'lib' for root in source_roots] + [fex / 'aarch64-unix'])
        licenses = license_inputs([('deps', Path(paths['deps']) / 'share/licenses'),
                                   ('moltenvk', Path(paths['moltenvk']) / 'share/licenses')])
        for namespace, root in [('wine', args.wine), ('dxmt', args.dxmt), ('fex', args.hyperbridge)]:
            for name in ['LICENSE', 'COPYING.LIB', 'LICENSE.OLD']:
                path = root / name
                if path.is_file():
                    licenses.append(dict(name=namespace + '-' + name, path=str(path), sha256=sha(path)))
        intent = HERE / 'wine-loader.entitlements.plist'
        config = dict(name='MacRunner 1.1.1 c32r - GitHub source build', wine=paths['wine'], fex=str(fex),
                      graphics=str(graphics), dependencyRoots=[str(x) for x in source_roots] + [paths['wine']],
                      dlopenLibraries=libraries, licenseInputs=licenses,
                      wineEntitlements=str(intent), wineEntitlementsSHA256=sha(intent),
                      environment=template['environment'], graphicsMatrix=template['graphics'],
                      tools=[dict(name=row['name'], path=str(tools_work / 'outputs/tools' / row['name']),
                                  sha256=row['sha256']) for row in tools['tools']])
        selected = args.work / 'engine-inputs.json'; selected.write_text(json.dumps(config, indent=2) + '\n')
        run('assemble-engine', [sys.executable, '-I', '-B', HERE / 'assemble_engine.py', selected,
                                resources / 'engine', '--defer-signing'])
        runtime = resources / 'engine'
        # Keep Wine's separately source-built bridge DLLs. Only the actual translator aliases are installed.
        for name in ['xtajit.dll', 'xtajit64.dll']:
            target = runtime / 'wine/lib/wine/aarch64-windows' / name
            if target.exists() and sha(target) != sha(fex / 'aarch64-windows' / name):
                backups = args.work / 'replaced-wine-aliases'; backups.mkdir(exist_ok=True)
                backup = backups / (name + '.BYLO-' + time.strftime('%H%M%S', time.gmtime()))
                shutil.copy2(target, backup)
                result.setdefault('replaced_wine_aliases', []).append(dict(path=name, before_sha256=sha(target),
                                                                           backup=str(backup)))
            shutil.copy2(fex / 'aarch64-windows' / name, target)
        manifest_path = runtime / 'ENGINE.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['capabilities'] = template.get('capabilities', {})
        manifest['files'] = {str(p.relative_to(runtime)):sha(p) for p in sorted(runtime.rglob('*'))
                             if p.is_file() and p != manifest_path}
        manifest['report']['release_source_inputs'] = pins
        manifest_path.write_text(json.dumps(manifest, indent=1) + '\n')
        run('app-architecture', [sys.executable, '-I', '-B', HERE / 'check-macho-arch.py', app])
        if not os.access(contents / 'MacOS' / info['CFBundleExecutable'], os.X_OK):
            raise ValueError('Application executable lost mode')
        run('archive-app', ['tar', '-czf', args.work / 'MacRunner-1.1.1-unsigned-source-built.tar.gz',
                            '-C', prefix, 'MacRunner.app'])
        result.update(status='WHOLE_APP_SOURCE_ASSEMBLED_SIGNING_AND_GATES_REQUIRED',
                      archive=dict(name='MacRunner-1.1.1-unsigned-source-built.tar.gz',
                                   sha256=sha(args.work / 'MacRunner-1.1.1-unsigned-source-built.tar.gz')),
                      app=str(app), engine_sha256=sha(manifest_path))
        return 0
    except Exception as error:
        result.update(status='FAILED', first_failure=str(error))
        return 1
    finally:
        result['install_skipped'] = sum('install skipped' in line.lower() for p in reports.glob('*.log')
                                        for line in p.read_text(errors='replace').splitlines())
        (reports / 'RESULT.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k:result[k] for k in ['status','first_failure','install_skipped']}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['pins', 'transport', 'wine', 'dxmt', 'hyperbridge', 'work']:
        parser.add_argument('--' + name, type=Path, required=True)
    raise SystemExit(build(parser.parse_args()))

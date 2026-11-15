#!/usr/bin/env python3
"""Prepare pinned Indiana sources or compile them in an authorized ARM64 macOS cloud job."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import struct
import subprocess
import sys
import tarfile

HERE = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative(name):
    path = PurePosixPath(name)
    require(not path.is_absolute() and path.parts and '..' not in path.parts and path.as_posix() == name,
            'Unsafe source path')
    return path


def inventory(root):
    rows = {}
    for path in sorted(Path(root).rglob('*')):
        require(not path.is_symlink(), 'Source symlink refused')
        if path.is_file():
            rows[path.relative_to(root).as_posix()] = sha(path)
    raw = ''.join(name + '\t' + digest + '\n' for name, digest in sorted(rows.items())).encode()
    return dict(files=len(rows), sha256=hashlib.sha256(raw).hexdigest())


def archives(lock):
    return [dict(lock['sources']['macrunner'], name='indiana'), *lock['sources']['pinned']]


def verify_archives(lock, directory):
    result = {}
    for row in archives(lock):
        path = Path(directory) / (row['name'] + '.tar.gz')
        require(path.is_file() and not path.is_symlink(), 'Missing pinned archive: ' + row['name'])
        require(path.stat().st_size == row['bytes'] and sha(path) == row['sha256'],
                'Archive pin differs: ' + row['name'])
        result[row['name']] = path
    return result


def select_archive(archive, selections, allowed_symlinks=None):
    """Materialize only selected regular source files; no archive Package output is copied."""
    allowed_symlinks = allowed_symlinks or {}
    matched_links = set()
    selected = []
    seen = set()
    with tarfile.open(archive, 'r:gz') as stream:
        for member in stream.getmembers():
            for prefix, destination, excluded in selections:
                if not member.name.startswith(prefix):
                    continue
                name = member.name[len(prefix):]
                if not name or member.isdir():
                    continue
                name = relative(name).as_posix()
                parts = PurePosixPath(name).parts
                if parts[0] in excluded or '.git' in parts or parts[-1] == '.DS_Store':
                    continue
                if member.issym() and member.name in allowed_symlinks:
                    require(member.linkname == allowed_symlinks[member.name] and member.name not in matched_links,
                            'Pinned source symlink differs')
                    matched_links.add(member.name)
                    continue
                require(member.isfile() and 0 <= member.size <= 32 * 1024**2, 'Foreign selected archive member')
                target = Path(destination) / name
                require(target not in seen and not target.exists(), 'Duplicate selected archive source')
                seen.add(target)
                selected.append((member, target))
        require(matched_links == set(allowed_symlinks), 'Pinned source symlink missing')
        require(len(selected) <= 30000 and sum(row.size for row, _ in selected) <= 512 * 1024**2,
                'Source extraction budget exceeded')
        # Validate every selected path/type before writing the first source.
        for member, target in selected:
            target.parent.mkdir(parents=True, exist_ok=True)
            with stream.extractfile(member) as src, target.open('xb') as dst:
                shutil.copyfileobj(src, dst)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
    return len(selected)


def restore_links(root, links):
    """Restore the pinned source layout only after regular files have been verified."""
    root = Path(root)
    pending = []
    for name, value in links.items():
        target = root / relative(name)
        require(not PurePosixPath(value).is_absolute() and
                (target.parent / value).resolve().is_relative_to(root.resolve()),
                'Source symlink target escapes source root')
        require(not target.exists() and not target.is_symlink() and
                not any(parent.is_symlink() for parent in target.parents if parent.is_relative_to(root)),
                'Source symlink path conflicts')
        pending.append((target, value))
    for target, value in pending:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(value)


def unpack_single(archive, destination):
    with tarfile.open(archive, 'r:gz') as stream:
        roots = {relative(m.name.rstrip('/')).parts[0] for m in stream.getmembers() if m.name.rstrip('/')}
    require(len(roots) == 1, 'Dependency archive must have one source root')
    prefix = roots.pop() + '/'
    select_archive(archive, [(prefix, destination, set())])


def prepare(lock, directory, output, here=HERE):
    inputs = verify_archives(lock, directory)
    output = Path(output)
    require(not output.exists(), 'Fresh Indiana source path required')
    profile = lock['source_profile']
    links = profile.get('core_symlinks', {})
    source, cross = output / 'MoltenVK', output / 'SPIRV-Cross'
    select_archive(inputs['indiana'], [
        (profile['core_prefix'], source, set(profile['excluded_core_trees'])),
        (profile['cross_prefix'], cross, set()),
    ], {profile['core_prefix'] + name: value for name, value in links.items()})
    require(inventory(source) == dict(files=profile['core_files'], sha256=profile['core_before_inventory_sha256']),
            'MoltenVK base source inventory differs')
    require(inventory(cross) == dict(files=profile['cross_files'], sha256=profile['cross_inventory_sha256']),
            'SPIRV-Cross source inventory differs')
    changes = []
    for row in profile['postimages']:
        target = source / relative(row['path'])
        stored = Path(here) / relative(row['store'])
        require(stored.is_file() and not stored.is_symlink() and stored.resolve().is_relative_to(Path(here).resolve()),
                'Missing or foreign Indiana postimage')
        require(sha(target) == row['before_sha256'] and sha(stored) == row['after_sha256']
                and stored.stat().st_size == row['bytes'], 'Indiana rebuild preimage/postimage differs')
        changes.append((stored, target))
    for stored, target in changes:
        shutil.copyfile(stored, target)
    core = inventory(source)
    require(core == dict(files=profile['core_files'], sha256=profile['core_after_inventory_sha256']),
            'MoltenVK rebuild source inventory differs')
    # The original producer pins the revision after checking its source snapshot.
    revision = source / 'Scripts/gen_moltenvk_rev_hdr.sh'
    require(re.fullmatch('[0-9a-f]{40}', profile['revision']) is not None, 'Pinned MoltenVK revision differs')
    text, count = re.subn(r'^MVK_GIT_REV=.*$', 'MVK_GIT_REV=' + profile['revision'],
                          revision.read_text(), flags=re.M)
    require(count == 1, 'MoltenVK revision assignment differs')
    revision.write_text(text)
    external = source / 'External'; external.mkdir()
    shutil.copytree(cross, external / 'SPIRV-Cross')
    for name in ['Vulkan-Headers', 'SPIRV-Tools', 'cereal']:
        unpack_single(inputs[name], external / name)
    unpack_single(inputs['SPIRV-Headers'], external / 'SPIRV-Tools/external/spirv-headers')
    restore_links(source, links)
    return dict(status='INDIANA_EXACT_REBUILD_SOURCES_PREPARED', core=core, cross=inventory(cross),
                source_symlinks=links,
                revision_script_sha256=sha(revision), archives={k: sha(v) for k, v in inputs.items()},
                source=str(source), downloads='NOT_PERFORMED', compilation='NOT_PERFORMED')


def cloud_guard():
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64' and
            (os.environ.get('GITHUB_ACTIONS') == 'true' or os.environ.get('CI_XCODE_CLOUD') == 'TRUE'),
            'Compilation requires an authorized ARM64 macOS cloud job')


def compile_source(args, lock, source, out, reports):
    cloud_guard()
    for path in [args.cmake, args.ninja]:
        require(path is not None and path.is_file(), 'Source-built CMake/Ninja paths required')
        require(not str(path.resolve()).startswith(('/opt/homebrew/', '/usr/local/')), 'Foreign build tool prefix')
    env = {k: v for k, v in os.environ.items() if k in ['HOME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL', 'PATH']}
    env['PATH'] = str(args.ninja.parent) + os.pathsep + str(args.cmake.parent) + os.pathsep + env.get('PATH', '')
    tc = lock['source_profile']['toolchain']
    env['MACOSX_DEPLOYMENT_TARGET'] = tc['deployment_target']
    def read(argv):
        return subprocess.check_output(argv, env=env, text=True, timeout=30).strip()
    require(read(['xcodebuild', '-version']).splitlines() == ['Xcode ' + tc['xcode'], 'Build version ' + tc['xcode_build']],
            'Pinned Indiana Xcode differs')
    require(read(['xcrun', '--sdk', 'macosx', '--show-sdk-version']) == tc['sdk'], 'Pinned Indiana SDK differs')
    sdk = read(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    clang, clangxx = read(['xcrun', '--find', 'clang']), read(['xcrun', '--find', 'clang++'])
    env['SDKROOT'] = sdk
    commands = []
    def run(name, argv):
        path = reports / (name + '.log')
        with path.open('xb') as stream:
            child = subprocess.run([str(x) for x in argv], cwd=source, env=env, stdin=subprocess.DEVNULL,
                stdout=stream, stderr=subprocess.STDOUT, timeout=1800)
        commands.append(dict(name=name, argv=[str(x) for x in argv], rc=child.returncode, sha256=sha(path)))
        require(child.returncode == 0 and path.stat().st_size <= 32 * 1024**2, name + ' failed; full log retained')
        require('install skipped' not in path.read_text(errors='replace').lower(), 'Install skipped in ' + name)
    tools = source / 'External/SPIRV-Tools'
    build = tools / '_build'
    run('spirv-tools-configure', [args.cmake, '-S', tools, '-B', build, '-G', 'Ninja',
        '-DCMAKE_MAKE_PROGRAM=' + str(args.ninja), '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_C_COMPILER=' + clang, '-DCMAKE_CXX_COMPILER=' + clangxx, '-DCMAKE_OSX_SYSROOT=' + sdk,
        '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + tc['deployment_target'],
        '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local', '-DSPIRV_SKIP_TESTS=ON', '-DSPIRV_SKIP_EXECUTABLES=ON'])
    run('spirv-tools-build', [args.cmake, '--build', build, '--parallel', '2'])
    shutil.copytree(build, tools / 'build')
    for project, scheme, name, derived in [
        ('ExternalDependencies.xcodeproj', 'ExternalDependencies-macOS', 'xcode-external', source / 'External/build'),
        ('MoltenVKPackaging.xcodeproj', 'MoltenVK Package (macOS only)', 'xcode-moltenvk', source / 'build')]:
        run(name, ['xcodebuild', '-project', project, '-scheme', scheme, '-configuration', 'Release',
            '-destination', 'generic/platform=macOS', '-derivedDataPath', derived, '-jobs', '2', 'ARCHS=arm64',
            'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO',
            'MACOSX_DEPLOYMENT_TARGET=' + tc['deployment_target'], 'SDKROOT=' + sdk,
            'SYMROOT=' + str(derived), 'OBJROOT=' + str(derived), 'build'])
    library = source / 'Package/Release/MoltenVK/dylib/macOS/libMoltenVK.dylib'
    require(library.is_file() and struct.unpack_from('<II', library.read_bytes()) == (0xfeedfacf, 0x0100000c),
            'Expected ARM64 MoltenVK build output missing')
    links = read(['otool', '-L', str(library)])
    own_id = read(['otool', '-D', str(library)]).splitlines()[1].strip()
    dependencies = [line.strip().split(' (', 1)[0] for line in links.splitlines()[1:] if line.strip()]
    require(all(name == own_id or name.startswith(('/System/Library/', '/usr/lib/')) for name in dependencies),
            'Foreign MoltenVK dependency')
    load_commands = read(['otool', '-l', str(library)])
    minimum = re.search(r'\bminos\s+([0-9.]+)', load_commands)
    require(minimum is not None and minimum[1] == tc['deployment_target'], 'MoltenVK minimum macOS differs')
    out.mkdir()
    shutil.copy2(library, out / library.name)
    shutil.copy2(source / 'LICENSE', out / 'LICENSE')
    return dict(status='INDIANA_SOURCE_BUILT_NOT_RELEASE_ACCEPTED', sha256=sha(library), bytes=library.stat().st_size,
                raw_reference_equal=sha(library) == lock['source_profile']['binary_reference_sha256'],
                reference_sha256=lock['source_profile']['binary_reference_sha256'], dependencies=links,
                minimum_macos=minimum[1],
                tools=dict(cmake_sha256=sha(args.cmake), ninja_sha256=sha(args.ninja)), commands=commands)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=['plan', 'source', 'compile'], required=True)
    parser.add_argument('--archives', type=Path, help='Pinned archives named indiana.tar.gz and NAME.tar.gz')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--cmake', type=Path)
    parser.add_argument('--ninja', type=Path)
    args = parser.parse_args()
    lock = json.loads((HERE / 'moltenvk-indiana.lock.json').read_bytes())
    if args.stage == 'plan':
        print(json.dumps(dict(status='INDIANA_SOURCE_BUILD_PLANNED', inputs=[dict(name=r['name'], bytes=r['bytes'], sha256=r['sha256'])
            for r in archives(lock)], downloads=0, compilation='NOT_PERFORMED')))
        return 0
    if args.stage == 'compile':
        cloud_guard()
    require(args.work is not None and args.archives is not None and not args.work.exists(), 'Fresh --work and pinned --archives required')
    args.work.mkdir(parents=True)
    reports = args.work / 'reports'; reports.mkdir()
    result = dict(status='STARTED', failure=None, signing='NOT_PERFORMED', games='NOT_ENABLED')
    try:
        result['sources'] = prepare(lock, args.archives, args.work / 'sources')
        result['status'] = result['sources']['status']
        if args.stage == 'compile':
            result['build'] = compile_source(args, lock, Path(result['sources']['source']), args.work / 'outputs', reports)
            result['status'] = result['build']['status']
    except Exception as error:
        result.update(status='FAILED', failure=str(error))
    (reports / 'RESULT.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(status=result['status'], failure=result['failure'])))
    return int(result['failure'] is not None)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError) as error:
        print('REFUSED: ' + str(error), file=sys.stderr)
        raise SystemExit(2)

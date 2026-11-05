#!/usr/bin/env python3
"""Build the three BottleSetup PE helpers and install their resource family."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
NAMES = ('macrunner-bottle-register-native.exe', 'macrunner-bottle-register-32.exe',
         'macrunner-bottle-devices.exe', 'checked-registration.inf')
BUNDLE = 'MacRunnerControlCenter_MacRunnerControlCenter.bundle'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def pe_machine(path):
    data = Path(path).read_bytes()
    if not 128 <= len(data) <= 16 * 1024 * 1024 or data[:2] != b'MZ':
        raise ValueError('Bottle helper is not a bounded PE file')
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    if offset + 24 > len(data) or data[offset:offset + 4] != b'PE\0\0':
        raise ValueError('Bottle helper PE header is invalid')
    return struct.unpack_from('<H', data, offset + 4)[0]


def read_lock(path=None):
    lock = json.loads(Path(path or HERE / 'bottle-tools.lock.json').read_bytes())
    if lock.get('schema') != 1 or [row['name'] for row in lock['tools']] != list(NAMES[:3]):
        raise ValueError('Bottle tools lock differs')
    expected = [('aarch64-w64-mingw32-clang', 0xaa64), ('i686-w64-mingw32-clang', 0x14c),
                ('aarch64-w64-mingw32-clang', 0xaa64)]
    for row, (driver, machine) in zip(lock['tools'], expected):
        if row['driver'] != driver or row['machine'] != machine:
            raise ValueError('Bottle helper registration view differs')
    if lock['inf']['name'] != NAMES[3]:
        raise ValueError('Registration INF name differs')
    engine_tools = json.loads((HERE / 'engine-tools.lock.json').read_bytes())
    if lock.get('compiler') != engine_tools['tools'][0]['compiler']:
        raise ValueError('BottleTools must use the same pinned llvm-mingw as the engine tools')
    return lock


def checked_source(root, row):
    path = Path(root) / row['source']
    if path.is_symlink() or not path.is_file() or path.parent.resolve() != Path(root).resolve():
        raise ValueError('Bottle helper source is missing or outside its source root')
    if sha(path) != row['source_sha256']:
        raise ValueError('Bottle helper source differs from the pin')
    return path


def run_compiler(argv, log):
    with Path(log).open('xb') as stream:
        subprocess.run([str(value) for value in argv], stdin=subprocess.DEVNULL,
                       stdout=stream, stderr=subprocess.STDOUT, timeout=120, check=True)


def build(source, work, mingw_bin, lock=None, run=run_compiler):
    lock = lock or read_lock()
    source, work, mingw_bin = Path(source), Path(work), Path(mingw_bin)
    if work.exists():
        raise ValueError('Preserve previous bottle tool build evidence')
    work.mkdir(parents=True)
    outputs = work / 'outputs'; outputs.mkdir()
    result = {'status': 'STARTED', 'tools': [], 'files': {}, 'signing': 'NOT_PERFORMED',
              'install': 'NOT_PERFORMED', 'first_failure': None,
              'compiler_requirement': lock.get('compiler')}
    try:
        # Verify the complete source family before invoking a compiler.
        for row in [*lock['tools'], lock['inf']]:
            checked_source(source, row)
        for row in lock['tools']:
            compiler = mingw_bin / row['driver']
            if compiler.is_symlink() and not compiler.resolve().is_relative_to(mingw_bin.resolve()):
                raise ValueError('Bottle compiler resolves outside the selected toolchain')
            if not compiler.is_file():
                raise ValueError('Selected BottleTools compiler is missing')
            target = outputs / row['name']
            argv = [compiler, *row['argv'], checked_source(source, row), '-o', target]
            run(argv, work / (row['name'] + '.compile.log'))
            if target.is_symlink() or pe_machine(target) != row['machine']:
                raise ValueError('Bottle helper PE machine differs from its registration view')
            result['tools'].append({'name': row['name'], 'machine': row['machine'],
                                    'source_sha256': row['source_sha256'],
                                    'argv': [str(value) for value in argv],
                                    'matches_previous_release': sha(target) == row['reference_sha256']})
        shutil.copy2(checked_source(source, lock['inf']), outputs / NAMES[3])
        result['files'] = {name: {'bytes': (outputs / name).stat().st_size,
                                  'sha256': sha(outputs / name)} for name in NAMES}
        result['status'] = 'BOTTLE_TOOLS_SOURCE_BUILT'
        return result
    except Exception as error:
        result.update(status='FAILED', first_failure=str(error))
        raise
    finally:
        (work / 'RESULT.json').write_text(json.dumps(result, indent=2) + '\n')


def install(work, app):
    work, app = Path(work), Path(app)
    result = json.loads((work / 'RESULT.json').read_bytes())
    if result.get('status') != 'BOTTLE_TOOLS_SOURCE_BUILT' or set(result['files']) != set(NAMES):
        raise ValueError('Complete source-built BottleTools family is required')
    bundle = app / 'Contents/Resources' / BUNDLE
    if not bundle.is_dir() or bundle.is_symlink():
        raise ValueError('Application module resource bundle is missing')
    destination = bundle / 'Contents/Resources' if (bundle / 'Contents/Resources').is_dir() else bundle
    for name in NAMES:
        source, target = work / 'outputs' / name, destination / name
        if source.is_symlink() or sha(source) != result['files'][name]['sha256']:
            raise ValueError('BottleTools output drifted before resource placement')
        if target.is_symlink() or (target.exists() and sha(target) != sha(source)):
            raise ValueError('Conflicting application BottleTools resource')
        shutil.copy2(source, target)
    return {'files': result['files'], 'resources': str(destination.relative_to(app)),
            'status': 'BOTTLE_TOOLS_SOURCE_BUILT_AND_PLACED'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=HERE / 'bottle-tools')
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--mingw-bin', type=Path, required=True)
    args = parser.parse_args()
    result = build(args.source, args.work, args.mingw_bin)
    print(json.dumps({'status': result['status'], 'files': result['files']}))


if __name__ == '__main__':
    main()

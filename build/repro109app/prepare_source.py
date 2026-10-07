#!/usr/bin/env python3
"""Verify the released app source snapshot and prepare source-built inputs.

This does not compile, download, run frameworks, sign, or package an app.
"""
import argparse
import base64
import binascii
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import sys

HERE = Path(__file__).resolve().parent
COMPILED = {b'MZ', b'\x7fELF', b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
            b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe',
            b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
PORTABLE_GATE = '''#!/bin/bash
set -euo pipefail
repo=${MACRUNNER_ROOT:?Set MACRUNNER_ROOT to the selected complete MacRunner checkout}
[ -f "$repo/config/env.sh" ]
[ -f "$repo/scripts/probes/app32/gate.py" ]
cd "$repo"
. ./config/env.sh
exec python3 scripts/probes/app32/gate.py "$@"
'''


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(part)
    return h.hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')


def source_inventory(source):
    if source.is_symlink() or not source.is_dir():
        raise ValueError('Source root missing or symlink')
    rows = []
    for path in sorted(source.rglob('*')):
        if path.is_symlink():
            raise ValueError('Source snapshot contains a symlink')
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError('Unsupported source node')
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic[:2] in COMPILED or magic in COMPILED:
            raise ValueError('Compiled input in source snapshot')
        rows.append(dict(path=path.relative_to(source).as_posix(), sha256=sha(path),
                         bytes=path.stat().st_size,
                         executable=bool(path.stat().st_mode & 0o111)))
        if len(rows) > 4096 or sum(r['bytes'] for r in rows) > 64 * 1024 * 1024:
            raise ValueError('Source census cap exceeded')
    return rows


def verify_source(source, lock):
    rows = source_inventory(source)
    result = dict(files=len(rows), bytes=sum(r['bytes'] for r in rows),
                  inventory_sha256=hashlib.sha256(canonical(rows)).hexdigest(),
                  compiled_inputs=0)
    if (result['files'], result['bytes'], result['inventory_sha256']) != (
            lock['source_files'], lock['source_bytes'], lock['source_inventory_sha256']):
        raise ValueError('Selected source snapshot differs from release lock')
    return result


def fixture_bytes(lock):
    data = bytearray(512)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 128)
    data[128:132] = b'PE\0\0'
    struct.pack_into('<H', data, 132, 0x8664)
    expected = lock['generated_fixture']
    if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
        raise ValueError('Generated fixture differs from released bytes')
    if expected['path'] != 'Tests/Fixtures/test-pe.exe':
        raise ValueError('Fixture destination differs')
    return bytes(data)


def asset_bytes(source, lock):
    """Restore source images only after validating all destinations and bytes."""
    rows = lock.get('encoded_assets')
    expected = {'scripts/assets/AppIcon-1024.png': b'\x89PNG\r\n\x1a\n',
                'scripts/assets/AppIcon.icns': b'icns'}
    if not isinstance(rows, list) or len(rows) != len(expected):
        raise ValueError('Source asset census differs')
    restored = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('Source asset metadata differs')
        destination = row.get('path')
        if not isinstance(destination, str) or destination not in expected or destination in restored:
            raise ValueError('Source asset destination differs')
        if row.get('encoded_path') != destination + '.b64':
            raise ValueError('Source asset input differs')
        size, digest = row.get('bytes'), row.get('sha256')
        if type(size) is not int or not 0 < size <= 4 * 1024 * 1024:
            raise ValueError('Source asset size differs')
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('Source asset hash differs')
        encoded = source / row['encoded_path']
        if encoded.is_symlink() or not encoded.is_file() or encoded.stat().st_size > 8 * 1024 * 1024:
            raise ValueError('Source asset file differs')
        try:
            data = base64.b64decode(encoded.read_bytes().rstrip(b'\n'), validate=True)
        except (ValueError, binascii.Error):
            raise ValueError('Source asset encoding differs') from None
        if len(data) != size or hashlib.sha256(data).hexdigest() != digest or not data.startswith(expected[destination]):
            raise ValueError('Source asset bytes differ')
        restored[destination] = data
    return restored


def framework_module(lock):
    pins = lock['frameworks_recipe']
    if sha(HERE / 'build_app_frameworks.py') != pins['driver_sha256'] or sha(
            HERE / 'frameworks.lock.json') != pins['lock_sha256']:
        raise ValueError('Selected framework recipe differs')
    spec = importlib.util.spec_from_file_location('repro109_frameworks_source', HERE / 'build_app_frameworks.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prefix_inventory(prefix):
    root = prefix.resolve()
    if prefix.is_symlink() or not prefix.is_dir():
        raise ValueError('Framework prefix missing or symlink')
    rows = []
    for path in sorted(prefix.rglob('*')):
        if not path.resolve().is_relative_to(root):
            raise ValueError('Framework prefix symlink escapes')
        if path.is_file():
            rows.append(dict(path=path.relative_to(prefix).as_posix(), sha256=sha(path),
                             bytes=path.stat().st_size,
                             symlink=os.readlink(path) if path.is_symlink() else None))
        elif not path.is_dir():
            raise ValueError('Framework prefix has broken or unsupported node')
    if not rows:
        raise ValueError('Empty framework prefix')
    return rows


def verify_frameworks(work, lock, module):
    receipt = work / 'reports/RESULT.json'
    if work.is_symlink() or receipt.is_symlink():
        raise ValueError('Framework work or receipt is a symlink')
    result = json.loads(receipt.read_text())
    pins = lock['frameworks_recipe']
    if (result.get('status'), result.get('driver_sha256'), result.get('lock_sha256')) != (
            'FRAMEWORKS_SOURCE_BUILT_NOT_R2_COMPARED', pins['driver_sha256'], pins['lock_sha256']):
        raise ValueError('Framework source-build receipt not accepted')
    skipped = result.get('install_skipped')
    if type(skipped) is not int or skipped < 0:
        raise ValueError('Framework install-skipped coverage missing')
    rows = module.read_lock()['components']
    components = result.get('components')
    if not isinstance(components, list) or len(components) != len(rows):
        raise ValueError('Framework component census differs')
    prefix = work / 'prefix'
    inventory = prefix_inventory(prefix)
    if inventory != result.get('prefix_inventory'):
        raise ValueError('Framework prefix bytes differ from source-build receipt')
    for item, row in zip(components, rows):
        if (item.get('name'), item.get('status'), item.get('revision'), item.get('version'),
                item.get('xcframework')) != (row['name'], 'BUILT', row['revision'], row['version'],
                                           row['target'] + '.xcframework'):
            raise ValueError('Framework source identity or status differs')
        product = prefix / row['product']
        binaries = module.product_paths(product, row)
        actual = [dict(path=p.relative_to(product).as_posix(), sha256=sha(p),
                       bytes=p.stat().st_size, architecture='arm64') for p in binaries]
        if item.get('binaries') != actual or item.get('compiled_paths') != len(binaries):
            raise ValueError('Framework binary receipt differs')
        xc = prefix / item['xcframework']
        info = plistlib.loads((xc / 'Info.plist').read_bytes())
        libraries = info.get('AvailableLibraries')
        if not isinstance(libraries, list) or len(libraries) != 1:
            raise ValueError('XCFramework slice census differs')
        lib = libraries[0]
        if lib.get('SupportedPlatform') != 'macos' or lib.get('SupportedArchitectures') != ['arm64']:
            raise ValueError('XCFramework platform or architecture differs')
        # Never form a path from unchecked plist metadata.
        if lib.get('LibraryIdentifier') != 'macos-arm64' or lib.get('LibraryPath') != row['product']:
            raise ValueError('XCFramework library path differs')
        copied = module.product_paths(xc / 'macos-arm64' / row['product'], row)
        if [sha(p) for p in copied] != [sha(p) for p in binaries]:
            raise ValueError('XCFramework transport differs')
    return dict(receipt_sha256=sha(receipt), inventory_sha256=hashlib.sha256(canonical(inventory)).hexdigest(),
                compiled_paths=sum(len(r['required_binaries']) for r in rows),
                install_skipped=skipped,
                components=[dict(name=r['name'], revision=r['revision'], version=r['version']) for r in rows])


def prepare(source, work, framework_work, lock):
    if work.exists() or work.is_symlink():
        raise ValueError('Fresh preparation workspace required')
    selected = verify_source(source, lock)
    data = fixture_bytes(lock)
    assets = asset_bytes(source, lock)
    module = framework_module(lock)
    frameworks = verify_frameworks(framework_work, lock, module)
    destination = work.resolve()
    for parent in [source.resolve(), framework_work.resolve()]:
        if destination.is_relative_to(parent) or parent.is_relative_to(destination):
            raise ValueError('Preparation workspace overlaps inputs')
    gate = source / 'scripts/app32-gate.sh'
    if sha(gate) != lock['portable_gate']['input_sha256']:
        raise ValueError('Portable gate input differs')
    work.mkdir(parents=True)
    app = work / 'app'
    shutil.copytree(source, app)
    if verify_source(app, lock) != selected:
        raise ValueError('Source copy differs')
    generated = app / lock['generated_fixture']['path']
    generated.parent.mkdir(parents=True, exist_ok=True)
    with generated.open('xb') as stream:
        stream.write(data)
    for name, image in assets.items():
        with (app / name).open('xb') as stream:
            stream.write(image)
    out_gate = app / 'scripts/app32-gate.sh'
    out_gate.write_text(PORTABLE_GATE)
    shutil.copytree(framework_work / 'prefix', app / 'Frameworks', symlinks=True)
    if prefix_inventory(app / 'Frameworks') != prefix_inventory(framework_work / 'prefix'):
        raise ValueError('Framework copy differs')
    result = dict(schema=1, status='APP_INPUTS_PREPARED_NOT_COMPILED_NOT_WHOLE_BUNDLE',
                  source=selected, source_lock_sha256=sha(HERE / 'source.lock.json'),
                  frameworks=frameworks, generated_fixture=lock['generated_fixture'],
                  restored_assets=lock['encoded_assets'],
                  transformation=dict(path='scripts/app32-gate.sh', input_sha256=sha(gate),
                                      output_sha256=sha(out_gate), mode='MACRUNNER_ROOT_SELECTED_CHECKOUT'),
                  runtime_inputs={name: 'NOT_ENABLED' for name in lock['incomplete_runtime_inputs']},
                  app_build='NOT_ENABLED', comparison='NOT_ENABLED', stands='NOT_ENABLED',
                  ARM64EC='NOT_APPLICABLE_NATIVE_SOURCE_PREPARATION',
                  install_skipped=frameworks['install_skipped'])
    with (work / 'PREPARED.json').open('x') as stream:
        json.dump(result, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write('\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--plan', action='store_true')
    actions.add_argument('--prepare', action='store_true')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--framework-work', type=Path)
    args = parser.parse_args()
    lock = json.loads((HERE / 'source.lock.json').read_text())
    if args.plan:
        result = dict(status='SOURCE_SNAPSHOT_VERIFIED_NOT_COMPILED',
                      source=verify_source(HERE / 'source', lock),
                      fixture_sha256=hashlib.sha256(fixture_bytes(lock)).hexdigest(),
                      framework_recipe_sha256=sha(HERE / 'build_app_frameworks.py'),
                      runtime_inputs=lock['incomplete_runtime_inputs'])
        framework_module(lock)
    else:
        if os.environ.get('CI_XCODE_CLOUD') != 'TRUE' or platform.system() != 'Darwin' or platform.machine() != 'arm64':
            raise ValueError('Real framework preparation is Xcode Cloud ARM64 only')
        if args.work is None or args.framework_work is None:
            parser.error('--prepare requires --work and --framework-work')
        result = prepare(HERE / 'source', args.work, args.framework_work, lock)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print('REFUSED: ' + str(exc), file=sys.stderr)
        sys.exit(2)

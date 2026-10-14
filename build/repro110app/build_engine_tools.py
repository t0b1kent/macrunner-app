#!/usr/bin/env python3
"""Build the two small engine tools of the 1.1.0 candidate (c12) from the snapshot sources.

macrunner-job.exe      Windows x86_64 PE, llvm-mingw 20260505 (the archive pinned by the Wine recipe).
macrunner-session      macOS arm64, Apple clang of the selected Xcode.

Both are compared with the files of the accepted composition by SHA-256: the PE must be byte-identical (the link timestamp is
pinned to the accepted file's value); the Mach-O tool must be equal once the linker's ad-hoc signature is removed and the 16
bytes of LC_UUID, which the linker derives from the build, are zeroed. Nothing is signed and nothing is installed here;
assemble_engine.py copies the two results into engine/tools.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
LOCK = HERE / 'engine-tools.lock.json'
LC_UUID = 0x1b
MACHO_MAGIC_64 = 0xfeedfacf


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha(path):
    return sha_bytes(Path(path).read_bytes())


def read_lock(path=LOCK):
    lock = json.loads(Path(path).read_bytes())
    require(lock.get('schema') == 1 and [t['name'] for t in lock['tools']] == ['macrunner-job.exe', 'macrunner-session'],
            'Engine tools lock differs')
    for row in lock['tools']:
        require(len(row['source_sha256']) == 64 and len(row['reference']['sha256']) == 64, 'Unpinned engine tool')
        require(not any(c in ' \t\n;|&$`' for part in row['argv'] for c in part), 'Unsafe compiler argument')
    return lock


def zero_macho_uuid(data):
    """Return the bytes of a 64-bit Mach-O with the LC_UUID value zeroed, and whether one was found."""
    magic = struct.unpack_from('<I', data, 0)[0]
    require(magic == MACHO_MAGIC_64, 'Not a thin 64-bit Mach-O')
    count = struct.unpack_from('<I', data, 16)[0]
    out = bytearray(data)
    offset, found = 32, False
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if command == LC_UUID:
            out[offset + 8:offset + 24] = bytes(16)
            found = True
        offset += size
    return bytes(out), found


def normalized_macho_sha(path, work, run):
    """SHA-256 of the tool without its code signature and with a zeroed UUID."""
    copy = Path(work) / ('normalize-' + Path(path).name)
    shutil.copyfile(path, copy)
    run(['/usr/bin/codesign', '--remove-signature', str(copy)], 'codesign-remove-' + Path(path).name)
    data, found = zero_macho_uuid(copy.read_bytes())
    require(found, 'Mach-O tool without LC_UUID')
    return sha_bytes(data)


def default_run(argv, label, cwd=None, timeout=1800):
    done = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    if done.returncode:
        raise ValueError(label + ' failed rc=' + str(done.returncode) + ': ' + (done.stderr or done.stdout)[-600:])
    return done.stdout


def fetch_mingw(row, work, run=default_run):
    """Download the pinned llvm-mingw archive, check its SHA-256 before extraction, return its bin directory."""
    comp = row['compiler']
    archive = Path(work) / 'llvm-mingw.tar.xz'
    run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error', '--proto', '=https', '--output', str(archive), comp['url']],
        'download-llvm-mingw', timeout=1200)
    require(sha(archive) == comp['archive_sha256'], 'llvm-mingw archive differs from the pin')
    target = Path(work) / 'llvm-mingw'
    target.mkdir()
    with tarfile.open(archive, 'r:xz') as stream:
        members = stream.getmembers()
        require(len(members) <= 20000, 'llvm-mingw archive has too many members')
        for member in members:
            name = Path(member.name)
            require(not name.is_absolute() and '..' not in name.parts, 'llvm-mingw archive member leaves its directory')
            if member.issym() or member.islnk():
                link = (target / name.parent / member.linkname) if member.issym() else (target / member.linkname)
                require(os.path.commonpath([os.path.realpath(target), os.path.realpath(link)]) == os.path.realpath(target),
                        'llvm-mingw archive link leaves its directory')
            else:
                require(member.isfile() or member.isdir(), 'llvm-mingw archive member type is not allowed')
        stream.extractall(target, members=members)  # no filter= keyword: the system Python of the image is 3.9
    roots = [p for p in target.iterdir() if p.is_dir()]
    require(len(roots) == 1 and (roots[0] / 'bin/x86_64-w64-mingw32-clang').is_file(), 'llvm-mingw layout differs')
    return roots[0] / 'bin'


def compile_argv(row, source, out, mingw_bin=None, clang='clang'):
    if row['kind'] == 'pe-x86_64-mingw':
        require(mingw_bin is not None, 'llvm-mingw bin directory required')
        return [str(Path(mingw_bin) / row['driver']), *row['argv'], '-o', str(out), str(Path(source) / row['source'])]
    return [clang, *row['argv'], '-o', str(out), str(Path(source) / row['source'])]


def build(args, run=default_run):
    lock = read_lock()
    source, work = Path(args.source).resolve(), Path(args.work).resolve()
    require(not work.exists(), 'Fresh work directory required')
    work.mkdir(parents=True)
    out = work / 'outputs/tools'
    out.mkdir(parents=True)
    result = dict(schema=1, status='STARTED', first_failure=None, tools=[], install='NOT_PERFORMED', signing='NOT_PERFORMED')
    phase = 'INPUTS'
    try:
        mingw_bin = Path(args.mingw_bin) if args.mingw_bin else None
        clang = run(['/usr/bin/xcrun', '--find', 'clang'], 'find-clang').strip() if sys.platform == 'darwin' else 'clang'
        result['xcode'] = run(['/usr/bin/xcodebuild', '-version'], 'xcode-version').strip() if sys.platform == 'darwin' else ''
        for row in lock['tools']:
            phase = row['name'] + ':SOURCE'
            require(sha(source / row['source']) == row['source_sha256'], 'Engine tool source differs from the pin: ' + row['name'])
            item = dict(name=row['name'], source_sha256=row['source_sha256'], argv=row['argv'])
            if row['kind'] == 'pe-x86_64-mingw' and mingw_bin is None:
                phase = row['name'] + ':COMPILER'
                mingw_bin = fetch_mingw(row, work, run)
            phase = row['name'] + ':COMPILE'
            target = out / row['name']
            run(compile_argv(row, source, target, mingw_bin, clang), 'compile-' + row['name'], cwd=work)
            item.update(bytes=target.stat().st_size, sha256=sha(target))
            phase = row['name'] + ':COMPARE'
            ref = row['reference']
            if row['kind'] == 'pe-x86_64-mingw':
                item['comparison'] = 'EXACT_ACCEPTED_BYTES' if item['sha256'] == ref['sha256'] else 'DIFFERENT_FROM_ACCEPTED_BYTES'
            else:
                item['normalized_sha256'] = normalized_macho_sha(target, work, run)
                item['comparison'] = ('EQUAL_EXCEPT_LC_UUID' if item['normalized_sha256'] == ref['normalized_sha256']
                                      else 'DIFFERENT_FROM_ACCEPTED_BYTES')
            item['expected'] = row['expected']
            result['tools'].append(item)
        phase = 'FINAL'
        result['status'] = ('ENGINE_TOOLS_BUILT_AS_ACCEPTED' if all(t['comparison'] == t['expected'] for t in result['tools'])
                            else 'ENGINE_TOOLS_BUILT_REPORT_DIFFERS')
    except Exception as error:
        result.update(status='FAILED', first_failure=dict(phase=phase, error=str(error)[:1200]))
        raise
    finally:
        (work / 'RESULT.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
        print(json.dumps({k: result[k] for k in ('status', 'first_failure')}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--plan', action='store_true')
    actions.add_argument('--build', action='store_true')
    parser.add_argument('--source', type=Path, default=HERE / 'source')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--mingw-bin', type=Path, help='Prepared llvm-mingw bin directory; the pinned archive is downloaded when omitted')
    args = parser.parse_args()
    if args.plan:
        lock = read_lock()
        print(json.dumps(dict(status='ENGINE_TOOLS_PLANNED_NOT_BUILT', tools=[t['name'] for t in lock['tools']]), sort_keys=True))
        return 0
    require(args.work is not None, 'Fresh --work required')
    return build(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as exc:
        print('REFUSED: ' + str(exc), file=sys.stderr)
        sys.exit(2)

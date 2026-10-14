"""Offline controls for the engine tools step (a fake runner replaces every compiler; nothing is built or downloaded)."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import build_engine_tools as step


def macho(uuid=b'\x11' * 16):
    uuid_command = struct.pack('<II', step.LC_UUID, 24) + uuid
    header = struct.pack('<IiiIIIII', step.MACHO_MAGIC_64, 0x0100000c, 0, 2, 1, len(uuid_command), 0, 0)
    return header + uuid_command + b'\x00' * 64


class Lock(unittest.TestCase):
    def test_sources_in_the_snapshot_match_the_pins(self):
        lock = step.read_lock()
        for row in lock['tools']:
            self.assertEqual(step.sha(HERE / 'source' / row['source']), row['source_sha256'], row['name'])

    def test_pe_flags_are_the_measured_ones_and_the_macho_target_matches_the_accepted_tool(self):
        job, session = step.read_lock()['tools']
        self.assertEqual(job['argv'], ['-O2', '-municode', '-Wl,--subsystem,windows', '-Wl,-e,WinMainCRTStartup',
                                       '-Wl,--Xlink=/timestamp:1791424979'])
        self.assertEqual(job['compiler']['archive_sha256'], '050379de888f0c843787819dadf183df3693330a5724643919e9121f16355295')
        self.assertEqual(session['argv'], ['-O2', '-arch', 'arm64', '-mmacosx-version-min=27.0'])
        self.assertEqual(len(session['reference']['normalized_sha256']), 64)

    def test_unsafe_arguments_are_refused(self):
        lock = json.loads(step.LOCK.read_bytes())
        lock['tools'][0]['argv'].append('-O2;rm')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'lock.json'
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                step.read_lock(path)

    def test_compile_argv(self):
        job, session = step.read_lock()['tools']
        argv = step.compile_argv(job, '/src', '/out/j.exe', '/mingw/bin')
        self.assertEqual((argv[0], argv[-3:]), ('/mingw/bin/x86_64-w64-mingw32-clang', ['-o', '/out/j.exe', '/src/engine-tools/macrunner-job.c']))
        argv = step.compile_argv(session, '/src', '/out/s', clang='/x/clang')
        self.assertEqual(argv[:2], ['/x/clang', '-O2'])
        with self.assertRaises(ValueError):
            step.compile_argv(job, '/src', '/out/j.exe')


class Extraction(unittest.TestCase):
    def archive(self, tmp, members):
        import io
        import tarfile
        path = Path(tmp) / 'a.tar.xz'
        with tarfile.open(path, 'w:xz') as stream:
            for name, kind, link in members:
                info = tarfile.TarInfo(name)
                if kind == 'sym':
                    info.type, info.linkname = tarfile.SYMTYPE, link
                    stream.addfile(info)
                else:
                    data = b'x'
                    info.size = len(data)
                    stream.addfile(info, io.BytesIO(data))
        return path

    def test_the_archive_is_unpacked_without_the_python_312_filter_and_hostile_members_are_refused(self):
        row = step.read_lock()['tools'][0]
        for members, ok in (([('llvm-mingw-x/bin/x86_64-w64-mingw32-clang', 'file', None)], True),
                            ([('../escape', 'file', None)], False),
                            ([('/abs', 'file', None)], False),
                            ([('d/link', 'sym', '../../outside')], False)):
            with tempfile.TemporaryDirectory() as tmp:
                archive = self.archive(tmp, members)
                work = Path(tmp) / 'work'
                work.mkdir()
                def download(argv, label, cwd=None, timeout=1800, archive=archive, work=work):
                    shutil.copyfile(archive, work / 'llvm-mingw.tar.xz')
                    return ''
                row2 = json.loads(json.dumps(row))
                row2['compiler']['archive_sha256'] = step.sha(archive)
                if ok:
                    self.assertTrue(str(step.fetch_mingw(row2, work, download)).endswith('llvm-mingw-x/bin'))
                else:
                    with self.assertRaises(ValueError):
                        step.fetch_mingw(row2, work, download)


class MachO(unittest.TestCase):
    def test_only_the_uuid_is_zeroed(self):
        a, b = macho(b'\x11' * 16), macho(b'\x22' * 16)
        za, found = step.zero_macho_uuid(a)
        self.assertTrue(found)
        self.assertEqual(za, step.zero_macho_uuid(b)[0])
        self.assertNotEqual(a, b)
        with self.assertRaises(ValueError):
            step.zero_macho_uuid(b'\x00' * 64)


class FakeBuild(unittest.TestCase):
    def setUp(self):
        base = os.environ.get('REPRO109_TEST_TMP')
        if not base or not Path(base).is_dir():
            raise RuntimeError('REPRO109_TEST_TMP must name an owned existing fixture root')
        self.temp = tempfile.TemporaryDirectory(prefix='engine-tools-', dir=base)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'source/engine-tools').mkdir(parents=True)
        for name in ('macrunner-job.c', 'macrunner-session.c'):
            shutil.copyfile(HERE / 'source/engine-tools' / name, self.root / 'source/engine-tools' / name)

    def lock(self, pe=b'MZ fake job', uuid=b'\x33' * 16):
        lock = step.read_lock()
        lock['tools'][0]['reference'] = dict(lock['tools'][0]['reference'], sha256=hashlib.sha256(pe).hexdigest())
        lock['tools'][1]['reference'] = dict(lock['tools'][1]['reference'],
                                             normalized_sha256=hashlib.sha256(step.zero_macho_uuid(macho(uuid))[0]).hexdigest())
        return lock

    def run_build(self, lock, pe=b'MZ fake job', uuid=b'\x44' * 16, wipe_source=False):
        calls = []
        def run(argv, label, cwd=None, timeout=1800):
            calls.append(label)
            if label.startswith('compile-'):
                target = Path(argv[argv.index('-o') + 1])
                target.write_bytes(pe if label.endswith('.exe') else macho(uuid))
            return {'find-clang': '/usr/bin/clang\n', 'xcode-version': 'Xcode 27.0\n'}.get(label, '')
        if wipe_source:
            (self.root / 'source/engine-tools/macrunner-job.c').write_text('/* changed */\n')
        args = type('A', (), dict(source=self.root / 'source', work=self.root / 'work', mingw_bin=self.root / 'mingw'))()
        with patch.object(step, 'read_lock', return_value=lock), patch.object(step.sys, 'platform', 'darwin'):
            try:
                step.build(args, run)
            finally:
                self.result = json.loads((self.root / 'work/RESULT.json').read_text())
        return calls

    def test_matching_tools_report_the_accepted_status_and_sign_and_install_nothing(self):
        calls = self.run_build(self.lock())
        self.assertEqual(self.result['status'], 'ENGINE_TOOLS_BUILT_AS_ACCEPTED')
        self.assertEqual([t['comparison'] for t in self.result['tools']], ['EXACT_ACCEPTED_BYTES', 'EQUAL_EXCEPT_LC_UUID'])
        self.assertEqual((self.result['install'], self.result['signing']), ('NOT_PERFORMED', 'NOT_PERFORMED'))
        self.assertTrue(all(not c.startswith(('codesign-sign', 'install')) for c in calls))
        self.assertTrue((self.root / 'work/outputs/tools/macrunner-job.exe').is_file())

    def test_a_different_pe_is_reported_not_hidden(self):
        self.run_build(self.lock(pe=b'MZ other'), pe=b'MZ fake job')
        self.assertEqual(self.result['status'], 'ENGINE_TOOLS_BUILT_REPORT_DIFFERS')
        self.assertEqual(self.result['tools'][0]['comparison'], 'DIFFERENT_FROM_ACCEPTED_BYTES')

    def test_a_changed_source_is_refused_before_any_compiler_runs(self):
        with self.assertRaisesRegex(ValueError, 'source differs'):
            calls = self.run_build(self.lock(), wipe_source=True)
        self.assertEqual(self.result['status'], 'FAILED')
        self.assertFalse((self.root / 'work/outputs/tools/macrunner-job.exe').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)

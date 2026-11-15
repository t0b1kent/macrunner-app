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
        self.assertEqual(job['compiler']['archive_sha256'], 'd1dc5d1ecf3a3ced5ed5544c72f1acd0c8e84eb3024d520ecc6b143eec62a149')
        self.assertEqual((job['compiler']['version'], job['compiler']['clang']), ('20260908', '23.1.1'))
        self.assertEqual(session['argv'], ['-O2', '-arch', 'arm64', '-mmacosx-version-min=26.5'])
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
        argv = step.compile_argv(session, '/src', '/out/s', clang='/x/clang', sdk='/sdk/MacOSX.sdk')
        self.assertEqual(argv[:4], ['/x/clang', '-isysroot', '/sdk/MacOSX.sdk', '-O2'])
        self.assertNotIn('-isysroot', step.compile_argv(job, '/src', '/out/j.exe', '/mingw/bin', sdk='/sdk'))
        with self.assertRaisesRegex(ValueError, 'macOS SDK required'):
            step.compile_argv(session, '/src', '/out/s')
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


class CommandEvidence(unittest.TestCase):
    def test_compiler_failure_preserves_both_byte_exact_streams_and_command(self):
        base = os.environ['REPRO109_TEST_TMP']
        with tempfile.TemporaryDirectory(prefix='engine-tool-logs-', dir=base) as tmp:
            argv = [sys.executable, '-I', '-B', '-c',
                    "import os; os.write(1,b'out\\r\\n'); os.write(2,b'bad\\xff\\r\\n'); raise SystemExit(3)"]
            with self.assertRaisesRegex(ValueError, 'failed rc=3'):
                step.default_run(argv, 'compiler', log_root=tmp)
            self.assertEqual((Path(tmp) / 'compiler.stdout.log').read_bytes(), b'out\r\n')
            self.assertEqual((Path(tmp) / 'compiler.stderr.log').read_bytes(), b'bad\xff\r\n')
            self.assertEqual(json.loads((Path(tmp) / 'compiler.command.json').read_bytes())['returncode'], 3)


class FakeBuild(unittest.TestCase):
    def setUp(self):
        base = os.environ.get('REPRO109_TEST_TMP')
        if not base or not Path(base).is_dir():
            raise RuntimeError('REPRO109_TEST_TMP must name an owned existing fixture root')
        self.temp = tempfile.TemporaryDirectory(prefix='engine-tools-', dir=base)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk = self.root / 'MacOSX.sdk'
        (self.sdk / 'usr/include').mkdir(parents=True)
        (self.sdk / 'usr/include/errno.h').write_text('/* fixture SDK */\n')
        (self.root / 'source/engine-tools').mkdir(parents=True)
        for name in ('macrunner-job.c', 'macrunner-session.c'):
            shutil.copyfile(HERE / 'source/engine-tools' / name, self.root / 'source/engine-tools' / name)

    def lock(self, pe=b'MZ fake job', uuid=b'\x33' * 16):
        lock = step.read_lock()
        lock['tools'][0]['reference'] = dict(lock['tools'][0]['reference'], sha256=hashlib.sha256(pe).hexdigest())
        lock['tools'][1]['reference'] = dict(lock['tools'][1]['reference'],
                                             normalized_sha256=hashlib.sha256(step.zero_macho_uuid(macho(uuid))[0]).hexdigest())
        return lock

    def run_build(self, lock, pe=b'MZ fake job', uuid=b'\x44' * 16, wipe_source=False, sdk_response=None, fetch_compiler=False,
                  compiler_version='clang version 23.1.1 (fixture)', relative_compiler=False):
        calls = []
        def run(argv, label, cwd=None, timeout=1800):
            calls.append(label)
            if label.startswith('compile-'):
                self.assertTrue(Path(argv[0]).is_absolute())
                if label == 'compile-macrunner-session':
                    self.assertEqual(argv[argv.index('-isysroot') + 1], str(self.sdk))
                target = Path(argv[argv.index('-o') + 1])
                target.write_bytes(pe if label.endswith('.exe') else macho(uuid))
            return {'pe-compiler-version': compiler_version,
                    'find-clang': '/usr/bin/clang\n', 'find-sdk': str(self.sdk) if sdk_response is None else sdk_response,
                    'xcode-version': 'Xcode 27.0\n'}.get(label, '')
        if wipe_source:
            (self.root / 'source/engine-tools/macrunner-job.c').write_text('/* changed */\n')
        supplied = Path(os.path.relpath(self.root / 'mingw')) if relative_compiler else self.root / 'mingw'
        args = type('A', (), dict(source=self.root / 'source', work=self.root / 'work',
                                 mingw_bin=None if fetch_compiler else supplied))()
        with patch.object(step, 'read_lock', return_value=lock), patch.object(step.sys, 'platform', 'darwin'), \
                patch.object(step, 'fetch_mingw', return_value=self.root / 'mingw') as fetch:
            try:
                step.build(args, run)
            finally:
                self.result = json.loads((self.root / 'work/RESULT.json').read_text())
            self.fetch_calls = fetch.call_args_list
        return calls

    def test_matching_tools_report_recipe_reproduction_and_sign_and_install_nothing(self):
        calls = self.run_build(self.lock())
        self.assertEqual(self.result['status'], 'ENGINE_TOOLS_BUILT_AS_PINNED')
        self.assertEqual([t['comparison'] for t in self.result['tools']], ['EXACT_RECIPE_BYTES', 'EQUAL_RECIPE_EXCEPT_LC_UUID'])
        self.assertEqual((self.result['install'], self.result['signing']), ('NOT_PERFORMED', 'NOT_PERFORMED'))
        self.assertTrue(all(not c.startswith(('codesign-sign', 'install')) for c in calls))
        self.assertTrue((self.root / 'work/outputs/tools/macrunner-job.exe').is_file())
        self.assertEqual(self.result['pe_toolchain']['provenance'], 'SUPPLIED_BIN')

    def test_no_supplied_compiler_fetches_the_independent_sealed_pin(self):
        lock = self.lock()
        self.run_build(lock, fetch_compiler=True)
        self.assertEqual(self.result['status'], 'ENGINE_TOOLS_BUILT_AS_PINNED')
        self.assertEqual(len(self.fetch_calls), 1)
        self.assertEqual(self.fetch_calls[0].args[0]['compiler'], lock['tools'][0]['compiler'])
        self.assertEqual(self.result['pe_toolchain']['provenance'], 'PINNED_ARCHIVE')
        self.assertEqual(self.result['pe_toolchain']['compiler'], lock['tools'][0]['compiler'])

    def test_a_different_pe_is_reported_not_hidden(self):
        self.run_build(self.lock(pe=b'MZ other'), pe=b'MZ fake job')
        self.assertEqual(self.result['status'], 'ENGINE_TOOLS_BUILT_REPORT_DIFFERS')
        self.assertEqual(self.result['tools'][0]['comparison'], 'DIFFERENT_FROM_RECIPE_BYTES')

    def test_llvm22_is_refused_before_compilation_even_when_the_lock_claims_llvm23(self):
        with self.assertRaisesRegex(ValueError, 'compiler version differs'):
            self.run_build(self.lock(), compiler_version='clang version 22.1.6 (fixture)')
        self.assertEqual(self.result['status'], 'FAILED')
        self.assertFalse((self.root / 'work/outputs/tools/macrunner-job.exe').exists())

    def test_relative_supplied_compiler_remains_absolute_after_compile_changes_cwd(self):
        self.run_build(self.lock(), relative_compiler=True)
        self.assertEqual(self.result['status'], 'ENGINE_TOOLS_BUILT_AS_PINNED')

    def test_a_changed_source_is_refused_before_any_compiler_runs(self):
        with self.assertRaisesRegex(ValueError, 'source differs'):
            calls = self.run_build(self.lock(), wipe_source=True)
        self.assertEqual(self.result['status'], 'FAILED')
        self.assertFalse((self.root / 'work/outputs/tools/macrunner-job.exe').exists())

    def test_missing_sdk_is_refused_before_compilation(self):
        with self.assertRaisesRegex(ValueError, 'macOS SDK is missing'):
            self.run_build(self.lock(), sdk_response='')
        self.assertEqual(self.result['status'], 'FAILED')
        self.assertFalse((self.root / 'work/outputs/tools/macrunner-job.exe').exists())

    def test_sdk_without_standard_headers_is_refused_before_compilation(self):
        empty_sdk = self.root / 'Empty.sdk'
        empty_sdk.mkdir()
        with self.assertRaisesRegex(ValueError, 'lacks standard C headers'):
            self.run_build(self.lock(), sdk_response=str(empty_sdk))
        self.assertEqual(self.result['status'], 'FAILED')
        self.assertFalse((self.root / 'work/outputs/tools/macrunner-job.exe').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)

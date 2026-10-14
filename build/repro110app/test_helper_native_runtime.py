"""Own inert controls. No vendor archive, import, compiler, or network."""
import os
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import helper_native_runtime as native


class NativeRuntimeTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ['REPRO109_TEST_TMP']).resolve()
        if not parent.is_dir():
            raise ValueError('Existing own fixture directory required')
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_existing_source_pins_and_minimum(self):
        python, openssl, tool = native.inputs()
        self.assertEqual(python['sha256'], native.PYTHON_SHA)
        self.assertEqual(openssl['sha256'], native.OPENSSL_SHA)
        self.assertEqual(tool['deployment_target'], '26.5')
        self.assertEqual(openssl['deployment_target'], '26.5')
        self.assertEqual(tool['profile'], 'xcode-cloud')

    def test_configure_executes_own_selected_source(self):
        source = self.root / 'selected source'
        build = self.root / 'build'
        source.mkdir(); build.mkdir()
        # This executable is authored here; it is not CPython configure.
        configure = source / 'configure'
        configure.write_text('#!' + sys.executable + '\n'
            'from pathlib import Path\n'
            'Path("Makefile").write_text("srcdir = " + str(Path(__file__).parent) + "\\n")\n')
        configure.chmod(0o700)
        steps = native.python_steps(source, self.root / 'prefix', 2)
        result = subprocess.run(steps[0], cwd=build, stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(native.source_ownership(build, source)['status'], 'OWN_SOURCE')
        self.assertIn('--without-ensurepip', steps[0])
        self.assertIn('--enable-shared', steps[0])
        self.assertIn('--with-openssl=' + str(self.root / 'prefix'), steps[0])
        self.assertIn('--with-openssl-rpath=auto', steps[0])

    def test_foreign_srcdir_refused(self):
        build = self.root / 'build'; build.mkdir()
        (build / 'Makefile').write_text('srcdir = ' + str(self.root / 'foreign') + '\n')
        with self.assertRaisesRegex(ValueError, 'foreign source'):
            native.source_ownership(build, self.root / 'owned')

    def test_missing_and_duplicate_srcdir_refused(self):
        build = self.root / 'build'; build.mkdir()
        for text in ['', 'srcdir = ../owned\nsrcdir = ../owned\n']:
            with self.subTest(text=text):
                (build / 'Makefile').write_text(text)
                with self.assertRaisesRegex(ValueError, 'exactly one'):
                    native.source_ownership(build, self.root / 'owned')

    def test_relative_owned_srcdir_accepted(self):
        build = self.root / 'build'; build.mkdir()
        source = self.root / 'source'; source.mkdir()
        (build / 'Makefile').write_text('srcdir = ../source\n')
        self.assertEqual(native.source_ownership(build, source)['status'], 'OWN_SOURCE')

    def test_noncloud_refused_before_side_effects(self):
        work = self.root / 'must-not-exist'
        with mock.patch.dict(os.environ, {'CI_XCODE_CLOUD': ''}), \
                mock.patch.object(native.public_archive, 'download') as download:
            with self.assertRaisesRegex(ValueError, 'Xcode Cloud ARM64 only'):
                native.build(work, self.root / 'reports', float('inf'))
            download.assert_not_called()
        self.assertFalse(work.exists())

    def test_job_count_refused(self):
        for jobs in [0, 17, True, 1.5]:
            with self.subTest(jobs=jobs), self.assertRaises(ValueError):
                native.python_steps(self.root, self.root / 'prefix', jobs)

    def smoke_fixture(self, number, *, version_info=(3, 6, 0, 4, 0),
                      python=(3, 14, 5), architecture='arm64'):
        modules = {
            'ctypes': types.SimpleNamespace(), 'json': json,
            'platform': types.SimpleNamespace(machine=lambda: architecture),
            'sqlite3': types.SimpleNamespace(sqlite_version='OWN_SQLITE'),
            'ssl': types.SimpleNamespace(OPENSSL_VERSION_NUMBER=number,
                                         OPENSSL_VERSION_INFO=version_info,
                                         OPENSSL_VERSION='OpenSSL OWN_INERT'),
            'sys': types.SimpleNamespace(version_info=python),
            'zlib': types.SimpleNamespace(ZLIB_RUNTIME_VERSION='OWN_ZLIB'),
        }
        self.smoke_stdout = io.StringIO()
        with mock.patch.dict(sys.modules, modules), contextlib.redirect_stdout(self.smoke_stdout):
            exec(native.runtime_smoke_code(), {})

    def test_openssl3_patch_is_not_legacy_fix_field(self):
        self.assertNotEqual((3, 6, 0, 4, 0)[:3], (3, 6, 4))
        self.smoke_fixture(0x30600040)
        row = json.loads(self.smoke_stdout.getvalue())
        self.assertEqual(row['openssl_semver'], [3, 6, 4])
        self.assertEqual(row['openssl_version_info'], [3, 6, 0, 4, 0])

    def test_wrong_openssl_versions_refuse_with_actual_values(self):
        for number in [0x30600000, 0x30600030, 0x30600050, 0x30700040, 0x10101000]:
            with self.subTest(number=hex(number)), self.assertRaises(RuntimeError):
                self.smoke_fixture(number)
            self.assertEqual(json.loads(self.smoke_stdout.getvalue())['openssl_version_number'], hex(number))

    def test_legacy_tuple_false_positive_is_refused(self):
        with self.assertRaises(RuntimeError):
            self.smoke_fixture(0x30604000, version_info=(3, 6, 4, 0, 0))
        self.assertEqual(json.loads(self.smoke_stdout.getvalue())['openssl_semver'], [3, 6, 0])

    def test_python_and_architecture_guards_remain_active(self):
        for python, architecture in [((3, 14, 4), 'arm64'), ((3, 14, 5), 'x86_64')]:
            with self.subTest(python=python, architecture=architecture), self.assertRaises(RuntimeError):
                self.smoke_fixture(0x30600040, python=python, architecture=architecture)
            self.assertTrue(self.smoke_stdout.getvalue())


if __name__ == '__main__':
    unittest.main()

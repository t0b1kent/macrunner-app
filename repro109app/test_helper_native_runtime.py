"""Own inert controls. No vendor archive, import, compiler, or network."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
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


if __name__ == '__main__':
    unittest.main()

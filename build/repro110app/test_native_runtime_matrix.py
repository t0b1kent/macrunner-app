"""Full native producer branch and actual wrapper controls; no vendor execution."""
import json
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_python_helpers as builder


class NativeRuntimeMatrix(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def args(self, name, native_only=False, **extra):
        return SimpleNamespace(work=self.root / name, minutes=120, jobs=3,
                               publish_dir=self.root / 'out', native_only=native_only, **extra)

    def test_full_and_native_only_reach_same_producer_and_propagate_failure(self):
        calls = []
        for name, native_only in [('full', False), ('native', True)]:
            args = self.args(name, native_only)
            with mock.patch.object(builder.native, 'require_cloud'), \
                 mock.patch.object(builder.native, 'build', side_effect=RuntimeError('OWN_OPENSSL_FAILURE')) as native:
                with self.assertRaisesRegex(RuntimeError, 'OWN_OPENSSL_FAILURE'):
                    builder.build(args, builder.read_lock())
            call = native.call_args.args
            calls.append((call[0].relative_to(args.work).as_posix(),
                          call[1].relative_to(args.work).as_posix(), call[3]))
            report = json.loads((args.work / 'reports/RESULT.json').read_bytes())
            self.assertEqual(report['status'], 'FAILED')
            self.assertEqual(report['first_failure']['phase'], 'native-runtime')
            self.assertEqual(report['first_failure']['message'], 'OWN_OPENSSL_FAILURE')
        self.assertEqual(calls, [('native', 'reports/native', 3)] * 2)

    def test_native_success_stops_before_any_package_or_helper(self):
        args = self.args('success', True)
        runner = SimpleNamespace(command=mock.Mock(), environment=mock.Mock())
        with mock.patch.object(builder.native, 'require_cloud'), \
             mock.patch.object(builder.native.framework, 'load_runner', return_value=runner), \
             mock.patch.object(builder.native, 'build', return_value=(Path('/OWN_PYTHON'), Path('/OWN_PREFIX'))) as native:
            builder.build(args, builder.read_lock())
        native.assert_called_once()
        runner.command.assert_not_called()
        runner.environment.assert_not_called()
        report = json.loads((args.work / 'reports/RESULT.json').read_bytes())
        self.assertEqual(report['status'], 'FULL_MODE_NATIVE_RUNTIME_BUILT_DIAGNOSTIC_ONLY')
        self.assertEqual(report['packages'], [])
        self.assertEqual(report['helpers'], 'NOT_ENABLED')
        self.assertEqual(report['whole_app'], 'NOT_ENABLED')

    def test_package_selectors_cannot_silently_bypass_native_mode(self):
        for selector in [dict(only_step=1), dict(only_package='pip')]:
            args = self.args('conflict-' + next(iter(selector)), True, **selector)
            with mock.patch.object(builder.native, 'require_cloud'), mock.patch.object(builder.native, 'build') as native:
                with self.assertRaisesRegex(ValueError, 'cannot use package selectors'):
                    builder.build(args, builder.read_lock())
            self.assertFalse(args.work.exists())
            native.assert_not_called()

    def test_native_plan_is_offline(self):
        result = subprocess.run([sys.executable, '-I', '-B', str(HERE / 'build_python_helpers.py'), '--native-only'],
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report['native_only'])
        self.assertEqual((report['network'], report['builds'], report['install']), (0, 0, 'skipped'))

    def test_cli_refuses_native_and_package_selector(self):
        result = subprocess.run([sys.executable, '-I', '-B', str(HERE / 'build_python_helpers.py'),
                                 '--native-only', '--only-step', '1'], capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'not allowed with argument', result.stderr)

    def wrapper(self, mode, python_present=True):
        repo = self.root / ('wrapper-' + mode)
        jobs = repo / 'jobs'; jobs.mkdir(parents=True)
        app = repo / 'repro109app'; app.mkdir()
        wrapper = jobs / 'repro109-python-helper-build-github.sh'
        wrapper.write_bytes((HERE.parent / 'jobs' / wrapper.name).read_bytes())
        (app / 'build_python_helpers.py').write_text(
            'import json,pathlib,sys\nargs=sys.argv\n'
            'work=pathlib.Path(args[args.index("--work")+1])\n'
            'reports=work/"reports"; reports.mkdir(parents=True)\n'
            '(reports/"argv.json").write_text(json.dumps(args))\n')
        tools = repo / 'bin'; tools.mkdir()
        (tools / 'uname').write_text('#!/bin/bash\nif [ "$1" = -s ]; then echo Darwin; else echo arm64; fi\n')
        (tools / 'uname').chmod(0o755)
        os.symlink('/bin/mkdir', tools / 'mkdir')
        os.symlink('/usr/bin/dirname', tools / 'dirname')
        if python_present:
            os.symlink(sys.executable, tools / 'python3')
        work = repo / 'runner'; work.mkdir()
        out = repo / 'out'
        env = dict(os.environ, PATH=str(tools), GITHUB_ACTIONS='true', RUNNER_OS='macOS', RUNNER_ARCH='ARM64',
                   RUNNER_TEMP=str(work), REPRO109_HELPER_NATIVE_ONLY='1' if mode=='native' else '0',
                   REPRO109_HELPER_ONLY_PACKAGE='', REPRO109_HELPER_ONLY_STEP='')
        result = subprocess.run(['/bin/bash', str(wrapper), str(out)], env=env, capture_output=True, timeout=20)
        return result, out

    def test_actual_bash_native_mode_keeps_full_jobs_and_timeout(self):
        result, out = self.wrapper('native')
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = json.loads((out / 'argv.json').read_bytes())
        self.assertIn('--native-only', argv)
        self.assertNotIn('--only-step', argv)
        self.assertEqual(argv[argv.index('--minutes') + 1], '120')
        self.assertEqual(argv[argv.index('--jobs') + 1], '3')

    def test_actual_bash_full_mode_does_not_gain_selector(self):
        result, out = self.wrapper('full')
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = json.loads((out / 'argv.json').read_bytes())
        self.assertNotIn('--native-only', argv)
        self.assertNotIn('--only-step', argv)
        self.assertEqual(argv[argv.index('--minutes') + 1], '120')

    def test_missing_python_preserves_failure_code(self):
        result, out = self.wrapper('missing', python_present=False)
        self.assertEqual(result.returncode, 127)
        self.assertEqual((out / 'helper-wrapper-rc.txt').read_text(), '127\n')
        self.assertIn('python3: command not found', (out / 'helper-driver.log').read_text())
        self.assertNotIn(b'dirname: command not found', result.stderr)


if __name__ == '__main__':
    unittest.main()

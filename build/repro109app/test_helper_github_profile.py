"""Provider/source/worker/dispatch controls using only authored inert fixtures."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import helper_native_runtime as native

GH = dict(REPRO109_HELPER_PROFILE='github-macos15-arm64', GITHUB_ACTIONS='true',
          RUNNER_OS='macOS', RUNNER_ARCH='ARM64')


class GithubProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_cloud_inputs_are_unchanged(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            python, openssl, tool = native.inputs()
        self.assertEqual(python['sha256'], native.PYTHON_SHA)
        self.assertEqual(openssl['sha256'], native.OPENSSL_SHA)
        self.assertEqual(tool['profile'], 'xcode-cloud')
        self.assertEqual((tool['sdk'], tool['deployment_target']), ('27.0', '26.5'))

    def test_github_changes_tools_and_target_only(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            cloud_python, cloud_ssl, _ = native.inputs()
        with mock.patch.dict(os.environ, GH, clear=True):
            python, openssl, tool = native.inputs()
        self.assertEqual(python, cloud_python)
        cloud_ssl['deployment_target'] = '14.0'
        self.assertEqual(openssl, cloud_ssl)
        self.assertEqual((tool['xcode'], tool['xcode_build'], tool['sdk']),
                         ('16.4', '16F6', '15.5'))

    def test_unknown_provider_is_refused(self):
        with mock.patch.dict(os.environ, {'REPRO109_HELPER_PROFILE': 'local'}, clear=True):
            with self.assertRaises(ValueError):
                native.inputs()

    def test_github_worker_accepts_source_built_python(self):
        with mock.patch.dict(os.environ, GH, clear=True), \
             mock.patch.object(native.platform, 'system', return_value='Darwin'), \
             mock.patch.object(native.platform, 'machine', return_value='arm64'), \
             mock.patch.object(native.platform, 'python_version', return_value='3.14.5'):
            native.require_cloud()

    def test_provider_and_architecture_mismatch_are_refused(self):
        cases = [dict(GH, GITHUB_ACTIONS='false'), dict(GH, RUNNER_ARCH='X64'),
                 dict(GH, RUNNER_OS='Linux'), dict(GH, CI_XCODE_CLOUD='TRUE')]
        for env in cases:
            with self.subTest(env=env), mock.patch.dict(os.environ, env, clear=True), \
                 mock.patch.object(native.platform, 'system', return_value='Darwin'), \
                 mock.patch.object(native.platform, 'machine', return_value='arm64'):
                with self.assertRaises(ValueError):
                    native.require_cloud()
        with mock.patch.dict(os.environ, GH, clear=True), \
             mock.patch.object(native.platform, 'system', return_value='Darwin'), \
             mock.patch.object(native.platform, 'machine', return_value='x86_64'):
            with self.assertRaises(ValueError):
                native.require_cloud()

    def test_bootstrap_drift_refuses_before_native_workspace(self):
        work, reports = self.root / 'work', self.root / 'reports'
        with mock.patch.dict(os.environ, GH, clear=True), \
             mock.patch.object(native.platform, 'system', return_value='Darwin'), \
             mock.patch.object(native.platform, 'machine', return_value='arm64'), \
             mock.patch.object(native.platform, 'python_version', return_value='3.14.5'):
            with self.assertRaisesRegex(ValueError, 'bootstrap Python'):
                native.build(work, reports, time.monotonic() + 30, 3)
        self.assertFalse(work.exists())
        self.assertFalse(reports.exists())

    def test_actual_github_wrapper_retains_reports_omits_bodies(self):
        repo = self.root / 'repo'
        (repo / 'jobs').mkdir(parents=True)
        (repo / 'repro109app').mkdir()
        script = repo / 'jobs' / 'build.sh'
        script.write_bytes((HERE.parent / 'jobs/repro109-python-helper-build-github.sh').read_bytes())
        (repo / 'repro109app/build_python_helpers.py').write_text(
            "import json,os,pathlib,sys\n"
            "assert os.environ['REPRO109_HELPER_PROFILE']=='github-macos15-arm64'\n"
            "assert os.environ.get('CI_XCODE_CLOUD')!='TRUE'\n"
            "work=pathlib.Path(sys.argv[sys.argv.index('--work')+1])\n"
            "reports=work/'reports';reports.mkdir(parents=True)\n"
            "(reports/'RESULT.json').write_text(json.dumps({'status':'OWN_INERT_FIXTURE'})+'\\n')\n"
            "(reports/'source.body').write_bytes(b'OWN_BODY')\n")
        fake_bin = self.root / 'bin'; fake_bin.mkdir()
        uname = fake_bin / 'uname'
        uname.write_text('#!/bin/bash\nif [ "$1" = -s ]; then echo Darwin; else echo arm64; fi\n')
        uname.chmod(0o755)
        (fake_bin / 'python3').symlink_to(sys.executable)
        out = self.root / 'out'
        env = dict(os.environ, **GH, RUNNER_TEMP=str(self.root),
                   PATH=str(fake_bin) + os.pathsep + '/usr/bin:/bin')
        env.pop('CI_XCODE_CLOUD', None)
        run = subprocess.run(['/bin/bash', str(script), str(out)], env=env,
                             capture_output=True, timeout=15)
        self.assertEqual(run.returncode, 0, run.stderr.decode())
        self.assertEqual((out / 'helper-build-rc.txt').read_text(), '0\n')
        self.assertFalse((out / 'source.body').exists())
        omitted = json.loads((out / 'omitted-source-bodies.json').read_text())
        self.assertEqual(omitted[0]['sha256'], hashlib.sha256(b'OWN_BODY').hexdigest())
        self.assertEqual(json.loads((out / 'RESULT.json').read_text())['status'], 'OWN_INERT_FIXTURE')
        self.assertEqual((out / 'helper-wrapper-rc.txt').read_text(), '0\n')
        (repo / 'repro109app/build_python_helpers.py').write_text(
            "import sys\nprint('OWN_DRIVER_FAILURE',file=sys.stderr)\nsys.exit(7)\n")
        second = self.root / 'second'; second.mkdir()
        env['RUNNER_TEMP'] = str(second)
        failed_out = second / 'out'
        failed = subprocess.run(['/bin/bash', str(script), str(failed_out)], env=env,
                                capture_output=True, timeout=15)
        self.assertEqual(failed.returncode, 7)
        self.assertEqual((failed_out / 'helper-build-rc.txt').read_text(), '7\n')
        self.assertEqual((failed_out / 'helper-wrapper-rc.txt').read_text(), '7\n')
        self.assertEqual((failed_out / 'helper-driver.log').read_text(), 'OWN_DRIVER_FAILURE\n')

    def test_actual_toolchain_preflight_accepts_pins_refuses_sdk_drift(self):
        runner = native.framework.load_runner()
        outputs = {
            ('xcodebuild', '-version'): 'Xcode 16.4\nBuild version 16F6\n',
            ('xcrun', '--show-sdk-version'): '15.5\n',
            ('xcrun', '--show-sdk-path'): '/OWN-SDK\n',
            ('xcrun', '--find', 'clang'): '/OWN-CLANG\n',
            ('xcrun', '--find', 'clang++'): '/OWN-CLANGXX\n',
            ('/OWN-CLANG', '--version'): 'Apple clang version 17.0.0 (OWN)\n',
        }
        def own_run(argv, **kwargs):
            return types.SimpleNamespace(returncode=0, stdout=outputs[tuple(argv)])
        out = self.root / 'preflight'; out.mkdir()
        with mock.patch.object(runner.subprocess, 'run', side_effect=own_run):
            sdk, cc, cxx = runner.toolchain_preflight(native.github_toolchain(), out)
            self.assertEqual((str(sdk), cc, cxx), ('/OWN-SDK', '/OWN-CLANG', '/OWN-CLANGXX'))
            outputs[('xcrun', '--show-sdk-version')] = '26.5\n'
            with self.assertRaises(AssertionError):
                runner.toolchain_preflight(native.github_toolchain(), out)
        self.assertEqual(json.loads((out / 'toolchain-preflight.json').read_text())['status'], 'FAILED')


if __name__ == '__main__':
    unittest.main()

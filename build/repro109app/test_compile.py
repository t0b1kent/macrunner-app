#!/usr/bin/env python3
"""Real preparation/command runner, inert own compiler and framework fixtures."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


b = load('app_compile_controls', HERE / 'build_source.py')
source_tests = load('app_source_controls_reuse', HERE / 'test_source.py')


class CompileControls(unittest.TestCase):
    def setUp(self):
        self.fixture = source_tests.SourceControls('test_exact_published_source_inventory_and_fixture')
        # Reuse the existing inert framework constructor, not downloaded binaries.
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root
        self.framework = self.fixture.module
        self.runner = self.framework.load_runner()
        self.args = SimpleNamespace(work=self.root / 'build', publish_dir=self.root / 'results',
                                    jobs=4, minutes=95)
        self.repo = self.root / 'checkout'
        self.repo.mkdir()
        self.swift = self.root / 'own-swift'
        self.swift.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
a=sys.argv[1:]
if a == ['--version']:
 print('Apple Swift version 6.2.0 (own inert fixture)'); sys.exit(0)
if not pathlib.Path('Package.swift').is_file(): sys.exit(12)
if a[0] not in ['build','test'] or a[a.index('--arch')+1]!='arm64': sys.exit(13)
if a[a.index('-c')+1]!='release' or '--disable-automatic-resolution' not in a: sys.exit(14)
if os.environ.get('MACOSX_DEPLOYMENT_TARGET')!='14.0': sys.exit(15)
if any(k.startswith(('MACRUNNER_','WINE','DYLD_')) for k in os.environ): sys.exit(16)
scratch=pathlib.Path(a[a.index('--scratch-path')+1]); out=scratch/'arm64-apple-macosx'/'release'
if '--show-bin-path' in a: print(out); sys.exit(0)
if a[0]=='test':
 print('Test run with 1 tests passed'); sys.exit(int(os.environ.get('OWN_TEST_RC','0')))
if os.environ.get('OWN_BUILD_RC'): sys.exit(int(os.environ['OWN_BUILD_RC']))
out.mkdir(parents=True)
for name in ['MacRunnerControlCenter','macr-hud']:
 p=out/name; p.write_bytes(bytes.fromhex('cffaedfe0c000001')+bytes(24)); p.chmod(0o755)
resource=out/'MacRunnerControlCenter_MacRunnerControlCenter.bundle'; resource.mkdir()
(resource/'resource.txt').write_text('own resource bytes')
if os.environ.get('OWN_DROP_RESOURCE'): shutil=None; (resource/'resource.txt').unlink(); resource.rmdir()
print('install skipped')
''')
        self.swift.chmod(0o755)
        self.published = []

    def exercise(self, *, framework_rc=0, architecture='arm64', publisher_fail=False, env=None):
        original_command = self.runner.command
        original_module = b.module
        selected_rpaths = {}
        def command(argv, cwd, child_env, log, out, component, deadline, timeout=1800):
            if argv == ['/usr/bin/xcrun', '--find', 'swift']:
                argv = [sys.executable, '-c', 'import sys; print(sys.argv[1])', str(self.swift)]
            elif argv[:2] == ['/usr/bin/lipo', '-archs']:
                argv = [sys.executable, '-c', 'import sys; print(sys.argv[1])', architecture]
            elif argv[:2] == ['/usr/bin/otool', '-L']:
                value = argv[-1] + ':\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
                argv = [sys.executable, '-c', 'import sys; print(sys.argv[1],end="")', value]
            elif argv[:2] == ['/usr/bin/otool', '-l']:
                paths = selected_rpaths.setdefault(argv[-1], ['/own/inert-build/Frameworks'])
                value = 'Load command 0\n cmd LC_SEGMENT_64\n' + ''.join(
                    'Load command 1\n cmd LC_RPATH\n cmdsize 80\n path '+p+' (offset 12)\n' for p in paths)
                argv = [sys.executable, '-c', 'import sys; print(sys.argv[1],end="")', value]
            elif argv[0] == '/usr/bin/install_name_tool':
                paths = selected_rpaths.setdefault(argv[-1], ['/own/inert-build/Frameworks'])
                if argv[1] == '-delete_rpath':
                    paths.remove(argv[2])
                elif argv[1] == '-add_rpath':
                    paths.append(argv[2])
                else:
                    raise AssertionError('Unexpected inert relocation operation')
                argv = [sys.executable, '-c', 'print("OWN_INERT_RELOCATION")']
            return original_command(argv, cwd, child_env, log, out, component, deadline, timeout)
        def framework_build(args, lock):
            self.assertEqual(args.minutes, 70)
            self.assertEqual(json.loads((self.args.publish_dir / 'APP-RESULT.json').read_text())['status'], 'STARTED')
            source = self.fixture.framework_fixture()
            shutil.copytree(source, args.work, symlinks=True)
            licenses = args.work / 'prefix/licenses/own'
            licenses.mkdir(parents=True)
            (licenses / 'LICENSE').write_text('own inert fixture license')
            (args.work / 'reports/own.log').write_text('install skipped\ninstall skipped\n')
            receipt = args.work / 'reports/RESULT.json'
            x=json.loads(receipt.read_text())
            x.update(prefix_inventory=source_tests.p.prefix_inventory(args.work / 'prefix'), install_skipped=2)
            if framework_rc:
                x.update(status='FAILED', first_failure={'component':'own-framework'})
            receipt.write_text(json.dumps(x))
            return framework_rc
        original_live = self.framework.LiveResults
        def publish(path):
            self.published.append(json.loads((self.args.publish_dir / 'APP-RESULT.json').read_text()))
            if publisher_fail:
                raise RuntimeError('own publisher refused')
        def live(*args, **kwargs):
            return original_live(*args, publisher=publish, **kwargs)
        runtime_env = dict(CI_XCODE_CLOUD='TRUE', WINEPREFIX='own-no-runtime', MACRUNNER_ROOT='own-no-runtime')
        runtime_env.update(env or {})
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, runtime_env))
            stack.enter_context(patch.object(b.platform, 'system', return_value='Darwin'))
            stack.enter_context(patch.object(b.platform, 'machine', return_value='arm64'))
            stack.enter_context(patch.object(b, 'REPO', self.repo))
            stack.enter_context(patch.object(b, 'module', side_effect=lambda name,path:
                                             source_tests.p if name=='compile_prepare' else original_module(name,path)))
            stack.enter_context(patch.object(source_tests.p, 'framework_module', return_value=self.framework))
            stack.enter_context(patch.object(self.framework, 'build', side_effect=framework_build))
            stack.enter_context(patch.object(self.framework, 'load_runner', return_value=self.runner))
            stack.enter_context(patch.object(self.framework, 'LiveResults', side_effect=live))
            stack.enter_context(patch.object(self.runner, 'command', side_effect=command))
            rc = b.build(self.args)
        return rc, json.loads((self.args.work / 'reports/APP-RESULT.json').read_text())

    def test_plan_has_locked_source_and_explicit_gaps(self):
        result = b.plan()
        self.assertEqual(result['source']['files'], 375)
        self.assertEqual(result['products'], ['MacRunnerControlCenter','macr-hud'])
        self.assertEqual(len(result['runtime_inputs']), 5)

    def test_success_actual_prepare_and_owned_command_runner(self):
        rc, result = self.exercise()
        self.assertEqual(rc, 0)
        self.assertEqual(result['status'], 'APP_SOURCE_COMPILED_TESTED_NOT_WHOLE_BUNDLE')
        self.assertEqual(result['install_skipped'], 3)
        self.assertEqual(len(result['products']), 2)
        self.assertEqual([x['status'] for x in result['phases']], ['PASSED','PASSED'])
        self.assertGreater(len(result['prefix_inventory']), 6)
        self.assertEqual(self.published[-1]['install_skipped'], 3)
        self.assertEqual(len(result['runtime_inputs']), 5)
        self.assertEqual(result['whole_bundle'], 'NOT_ENABLED')
        self.assertEqual(result['swift_tests_passed'], 1)
        bundle = self.args.work / 'prefix/MacRunner.app/Contents'
        self.assertTrue((bundle / 'Resources/macr-hud').is_file())
        self.assertTrue((bundle / 'Resources/MacRunnerControlCenter_MacRunnerControlCenter.bundle').is_dir())
        self.assertEqual(result['app_bundle']['status'], 'PARTIAL_APP_BUNDLE_RUNTIME_INPUTS_NOT_ENABLED')
        self.assertEqual(result['app_bundle']['release_signing'], 'NOT_ENABLED')
        self.assertEqual(result['app_bundle']['whole_product'], 'NOT_ENABLED')

    def test_framework_failure_stops_before_swift(self):
        rc, result = self.exercise(framework_rc=1)
        self.assertEqual(rc, 1)
        self.assertEqual(result['first_failure']['phase'], 'FRAMEWORKS')
        self.assertEqual(result['framework_first_failure']['component'], 'own-framework')
        self.assertFalse((self.args.work / 'source-app').exists())
        self.assertEqual(result['install_skipped'], 2)

    def test_build_failure_preserves_first_phase_and_raw_log(self):
        rc, result = self.exercise(env={'OWN_BUILD_RC':'7'})
        self.assertEqual(rc, 1)
        self.assertEqual(result['first_failure']['phase'], 'SWIFT_BUILD')
        self.assertEqual(result['phases'][0]['status'], 'FAILED')
        self.assertFalse((self.args.work / 'reports/swift_test.log').exists())
        self.assertTrue(any(x['path']=='reports/swift_build.log' for x in result['logs']))

    def test_test_failure_is_not_successful_compile_receipt(self):
        rc, result = self.exercise(env={'OWN_TEST_RC':'4'})
        self.assertEqual(rc, 1)
        self.assertEqual(result['first_failure']['phase'], 'SWIFT_TEST')
        self.assertEqual([x['status'] for x in result['phases']], ['PASSED','FAILED'])
        self.assertFalse((self.args.work / 'prefix').exists())

    def test_wrong_product_architecture_refused(self):
        rc, result = self.exercise(architecture='x86_64')
        self.assertEqual(rc, 1)
        self.assertEqual(result['first_failure']['phase'], 'PRODUCTS')
        self.assertIn('architecture differs', result['first_failure']['error'])

    def test_missing_resource_refused(self):
        rc, result = self.exercise(env={'OWN_DROP_RESOURCE':'1'})
        self.assertEqual(rc, 1)
        self.assertIn('resource bundle NOT_PRESENT', result['first_failure']['error'])

    def test_early_publication_failure_stops_before_frameworks(self):
        rc, result = self.exercise(publisher_fail=True)
        self.assertEqual(rc, 1)
        self.assertEqual(result['first_failure']['phase'], 'PRECHECK')
        self.assertFalse((self.args.work / 'frameworks').exists())
        self.assertIn('own publisher refused', result['publication_failure'])

    def test_foreign_or_multiple_bin_path_refused(self):
        self.args.work.mkdir()
        for text in [str(self.root), '/one\n/two', 'relative-path']:
            with self.assertRaises(ValueError): b.selected_bin_path(text, self.args.work)

    def test_host_cli_refusal_has_no_work(self):
        result = subprocess.run([sys.executable, '-B', '-I', str(HERE/'build_source.py'), '--build',
                                 '--work', str(self.args.work), '--publish-dir', str(self.args.publish_dir)],
                                env={k:v for k,v in os.environ.items() if k not in ('CI_XCODE_CLOUD', 'GITHUB_ACTIONS')},
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2)
        self.assertIn('Cloud source work requires', result.stderr)
        self.assertFalse(self.args.work.exists())

    def test_zero_ambiguous_or_missing_test_count_refused(self):
        for text in ['Test run with 0 tests passed', 'compiler exited zero',
                     'Test run with 2 tests passed\nTest run with 3 tests passed']:
            with self.assertRaises(ValueError): b.test_count(text)
        self.assertEqual(b.test_count('Test run with 284 tests in 45 suites passed after 2 seconds.'), 284)

    def test_actual_shell_wrapper_argv_results_and_failure_transport(self):
        script = (HERE.parent / 'jobs/repro109-app-source.sh').read_text()
        original = '/usr/bin/python3 -B -I'
        self.assertEqual(script.count(original), 1)
        fake = self.root / 'own-python'
        fake.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
a=sys.argv[1:]; work=pathlib.Path(a[a.index('--work')+1]); out=pathlib.Path(a[a.index('--publish-dir')+1])
if a[-4:]!=['--jobs','4','--minutes','95']: sys.exit(17)
(work/'reports').mkdir(parents=True); (work/'frameworks/reports').mkdir(parents=True)
out.mkdir(parents=True); (out/'STARTED.json').write_text('{}')
(work/'reports/APP-RESULT.json').write_text(json.dumps({'argv':a,'rc':int(os.environ.get('OWN_WRAPPER_RC','0'))}))
(work/'frameworks/reports/RESULT.json').write_text('{}')
(work/'prefix').mkdir(); (work/'prefix/own.txt').write_text('inert own partial product')
sys.exit(int(os.environ.get('OWN_WRAPPER_RC','0')))
''')
        fake.chmod(0o755)
        for name, rc in [('success',0), ('failure',7)]:
            with self.subTest(name=name):
                root = self.root / ('wrapper-' + name)
                jobs = root / 'checkout/jobs'; jobs.mkdir(parents=True)
                wrapper = jobs / 'repro109-app-source.sh'
                wrapper.write_text(script.replace(original, '"' + str(fake) + '" -B -I'))
                out = root / 'results'; workspace = root / 'workspace'
                workspace.mkdir()
                env = dict(os.environ, CI_XCODE_CLOUD='TRUE', CI_WORKSPACE_PATH=str(workspace), OWN_WRAPPER_RC=str(rc))
                proc = subprocess.run(['/bin/bash',str(wrapper),str(out),'xcode-cloud'],env=env,
                                      stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=30)
                self.assertEqual(proc.returncode, rc, proc.stderr)
                self.assertEqual((out/'app-source-rc.txt').read_text(), str(rc)+'\n')
                self.assertTrue((out/'frameworks-reports/RESULT.json').is_file())
                self.assertTrue((out/'checkpoints/STARTED.json').is_file())
                self.assertTrue((out/'app-source-products.tar.gz').is_file())
                self.assertTrue((out/'app-source-products.sha256').is_file())
                result = json.loads((out/'APP-RESULT.json').read_text())
                self.assertEqual(result['rc'], rc)
                argv = result['argv']
                self.assertEqual(argv[argv.index('--work')+1], str(workspace/'repro109-app-source-work'))
                self.assertEqual(argv[argv.index('--publish-dir')+1], str(out/'checkpoints'))
                self.assertEqual(argv[2], str(root/'checkout/repro109app/build_source.py'))


if __name__ == '__main__':
    unittest.main()

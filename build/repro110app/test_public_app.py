import copy
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import build_app_frameworks as frameworks
import prepare_source as source
import build_source as native
import live_results

HERE = Path(__file__).resolve().parent


class PublicAppTests(unittest.TestCase):
    def test_xcode27_workflow_matches_passed_wine_recipe(self):
        # Wine workflow repro109-wine-c9-xcode27-arm64, inputs run 37615658798.
        workflow = (HERE.parent.parent / '.github/workflows/'
                    'repro109-app-source-matrix-xcode27-arm64.yml').read_text()
        self.assertEqual(workflow.count('runs-on: xcode-27\n'), 1)
        self.assertEqual(workflow.count('DEVELOPER_DIR: /Applications/Xcode_27.app/Contents/Developer\n'), 1)
        self.assertNotIn('Xcode_27.0.app', workflow)
        self.assertIn('if: always()', workflow)
        self.assertIn('repro109-app-results', workflow)

    def test_github_components_reach_toolchain_before_source_download(self):
        for component in ('sparkle', 'plcrashreporter'):
            with self.subTest(component=component), tempfile.TemporaryDirectory(
                    dir=os.environ['REPRO109_TEST_TMP']) as temp:
                root = Path(temp)
                args = SimpleNamespace(work=root / 'work', publish_dir=root / 'published',
                                       minutes=1, jobs=1, only=component)
                def stop(*words):
                    self.assertEqual(words[0]['profile'], 'github-xcode27-arm64')
                    self.assertEqual(words[0]['ld'], '27037.1')
                    raise RuntimeError('OWN_TOOLCHAIN_STOP_AFTER_CHECKPOINT')
                runner = SimpleNamespace(toolchain_preflight=stop)
                with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}, clear=True), \
                        patch.object(frameworks.platform, 'system', return_value='Darwin'), \
                        patch.object(frameworks.platform, 'machine', return_value='arm64'), \
                        patch.object(frameworks, 'load_runner', return_value=runner), \
                        patch.object(live_results.subprocess, 'Popen') as process:
                    self.assertEqual(frameworks.build(args, frameworks.read_lock()), 1)
                process.assert_not_called()
                result = json.loads((args.work / 'reports/RESULT.json').read_text())
                self.assertEqual(result['first_failure']['error'], 'OWN_TOOLCHAIN_STOP_AFTER_CHECKPOINT')
                progress = json.loads((args.publish_dir / 'PROGRESS.json').read_text())
                self.assertEqual(progress['publish'], 'STAGED_FOR_ARTIFACT')
                self.assertEqual(progress['sequence'], 1)
                self.assertEqual(result['components'], [])

    def test_github_full_reaches_framework_phase_before_source_download(self):
        with tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP']) as temp:
            root = Path(temp)
            args = SimpleNamespace(work=root / 'work', publish_dir=root / 'published', minutes=95, jobs=1)
            original_module = native.module
            def module(name, path):
                value = original_module(name, path)
                if name == 'compile_prepare':
                    value.framework_module = lambda lock: frameworks
                return value
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}, clear=True), \
                    patch.object(frameworks.platform, 'system', return_value='Darwin'), \
                    patch.object(frameworks.platform, 'machine', return_value='arm64'), \
                    patch.object(native, 'module', side_effect=module), \
                    patch.object(frameworks, 'build', side_effect=RuntimeError('OWN_FRAMEWORK_STOP_AFTER_CHECKPOINT')) as build:
                self.assertEqual(native.build(args), 1)
            build.assert_called_once()
            result = json.loads((args.publish_dir / 'APP-RESULT.json').read_text())
            self.assertEqual(result['first_failure'], dict(phase='FRAMEWORKS', error='OWN_FRAMEWORK_STOP_AFTER_CHECKPOINT'))
            progress = json.loads((args.publish_dir / 'PROGRESS.json').read_text())
            self.assertEqual(progress['publish'], 'STAGED_FOR_ARTIFACT')
            self.assertEqual(progress['state'], 'FAILED')

    def test_artifact_mode_preserves_success_and_failure_receipts(self):
        with tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP']) as temp:
            root = Path(temp)
            with patch.dict(os.environ, {'RESULTS_REMOTE': 'OWN_UNUSED_INERT'}, clear=True), \
                    patch('live_results.subprocess.Popen') as process:
                live = frameworks.LiveResults(root / 'reports', root, 'github',
                                              publish_dir=root / 'published', publication_mode='github-artifact')
                for phase, state, status in [('PRECHECK', 'JOB_STARTED', 'STARTED'),
                                              ('BUILD', 'BUILT', 'BUILT'), ('FINAL', 'FAILED', 'FAILED')]:
                    row = live.record(phase, state, status=status)
                    self.assertEqual(row['publish'], 'STAGED_FOR_ARTIFACT')
                    self.assertEqual(json.loads((root / 'published/PROGRESS.json').read_text()), row)
                    self.assertEqual(json.loads((root / 'reports/PROGRESS.json').read_text()), row)
            process.assert_not_called()
            self.assertEqual(len(list((root / 'published').glob('0*.json'))), 3)
            self.assertEqual(len((root / 'reports/PROGRESS.jsonl').read_text().splitlines()), 3)

    def test_artifact_mode_requires_github_destination(self):
        with tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP']) as temp:
            root = Path(temp)
            for profile, destination in [('xcode-cloud', root / 'published'), ('github', None)]:
                with self.subTest(profile=profile), self.assertRaises(ValueError):
                    frameworks.LiveResults(root / 'reports', root, profile,
                                          publish_dir=destination, publication_mode='github-artifact')

    def test_full_and_component_selection_use_same_pins(self):
        lock = frameworks.read_lock()
        full = frameworks.selected_components(lock)
        self.assertEqual([row['name'] for row in full], ['sparkle', 'plcrashreporter'])
        for row in full:
            self.assertEqual(frameworks.selected_components(lock, row['name']), [row])

    def test_unknown_component_refused(self):
        with self.assertRaises(ValueError):
            frameworks.selected_components(frameworks.read_lock(), 'foreign')

    def test_github_cloud_profile(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}, clear=True), \
                patch.object(frameworks.platform, 'system', return_value='Darwin'), \
                patch.object(frameworks.platform, 'machine', return_value='arm64'):
            self.assertEqual(frameworks.cloud_profile(), 'github')

    def test_xcode_cloud_profile(self):
        with patch.dict(os.environ, {'CI_XCODE_CLOUD': 'TRUE'}, clear=True), \
                patch.object(frameworks.platform, 'system', return_value='Darwin'), \
                patch.object(frameworks.platform, 'machine', return_value='arm64'):
            self.assertEqual(frameworks.cloud_profile(), 'xcode-cloud')

    def test_local_source_work_refused(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(frameworks.platform, 'system', return_value='Darwin'), \
                patch.object(frameworks.platform, 'machine', return_value='arm64'):
            with self.assertRaises(ValueError):
                frameworks.cloud_profile()

    def test_other_architecture_refused(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}, clear=True), \
                patch.object(frameworks.platform, 'system', return_value='Darwin'), \
                patch.object(frameworks.platform, 'machine', return_value='x86_64'):
            with self.assertRaises(ValueError):
                frameworks.cloud_profile()

    def test_missing_tools_refused_before_download(self):
        runner = frameworks.load_runner()
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {'PATH': ''}, clear=True):
            root = Path(temp)
            with self.assertRaises(FileNotFoundError):
                runner.toolchain_preflight(copy.deepcopy(frameworks.read_lock()['toolchain']), root)
            receipt = json.loads((root / 'toolchain-preflight.json').read_text())
            self.assertEqual(receipt['status'], 'FAILED')

    def test_foreign_source_inventory_refused(self):
        lock = json.loads((HERE / 'source.lock.json').read_text())
        lock['source_inventory_sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            source.verify_source(HERE / 'source', lock)

    def test_framework_recipe_pin(self):
        lock = json.loads((HERE / 'source.lock.json').read_text())
        source.framework_module(lock)
        lock['frameworks_recipe']['driver_sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            source.framework_module(lock)


class ToolchainProfileTests(unittest.TestCase):
    def setUp(self):
        self.lock = frameworks.read_lock()
        self.runner = frameworks.load_runner()
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        self.fixture = {
            ('xcodebuild', '-version'): 'Xcode 27.0\nBuild version 27A266a\n',
            ('xcrun', '--show-sdk-version'): '27.0\n',
            ('xcrun', '--show-sdk-path'): '/OWN/SDK\n',
            ('xcrun', '--find', 'clang'): '/OWN/clang\n',
            ('xcrun', '--find', 'clang++'): '/OWN/clang++\n',
            ('/OWN/clang', '--version'): 'Apple clang version 21.0.0 (clang-2100.3.34.2)\nOWN_FIXTURE\n',
            ('/OWN/clang++', '--version'): 'Apple clang version 21.0.0 (clang-2100.3.34.2)\nOWN_FIXTURE\n',
            ('xcrun', 'ld', '-v'): '@(#)PROGRAM:ld PROJECT:ld-27037.1\nOWN_FIXTURE\n',
            ('xcrun', '--find', 'ar'): '/OWN/ar\n',
            ('xcrun', '--find', 'libtool'): '/OWN/libtool\n',
            ('xcrun', '--find', 'swift'): '/OWN/swift\n',
            ('xcrun', 'ar', '--version'): 'OWN_UNPINNED_AR_VERSION\n',
            ('xcrun', 'libtool', '-V'): 'OWN_UNPINNED_LIBTOOL_VERSION\n',
            ('xcrun', 'swift', '--version'): 'Apple Swift version 6.OWN_FIXTURE\n',
            ('sw_vers', '-buildVersion'): '26A428\n',
        }
        self.returncodes = {}
        self.calls = []

    def fake_command(self, argv, **kwargs):
        words = tuple(argv)
        self.calls.append(words)
        return SimpleNamespace(returncode=self.returncodes.get(words, 0), stdout=self.fixture[words])

    def run_preflight(self, profile='github'):
        tool = frameworks.selected_toolchain(self.lock, profile)
        with patch.object(self.runner.subprocess, 'run', side_effect=self.fake_command):
            self.runner.toolchain_preflight(tool, self.out)
        return tool

    def receipt(self):
        return json.loads((self.out / 'toolchain-preflight.json').read_text())

    def assert_family_captured(self):
        report = self.receipt()
        for name in ['xcode', 'sdk', 'apple_clang', 'apple_clangxx', 'apple_ld', 'ar', 'libtool', 'swift']:
            self.assertIn(name, report['actual'])
        self.assertEqual(len(report['commands']), len(self.fixture))

    def test_profile_selection_preserves_cloud_pins(self):
        original = copy.deepcopy(self.lock)
        github = frameworks.selected_toolchain(self.lock, 'github')
        cloud = frameworks.selected_toolchain(self.lock, 'xcode-cloud')
        self.assertEqual(github['ld'], '27037.1')
        self.assertEqual(cloud, original['toolchain'])
        self.assertEqual(cloud['ld'], '27037.1.0')
        github['ld'] = cloud['ld'] = 'OWN_MUTATED'
        self.assertEqual(self.lock, original)
        with self.assertRaises(ValueError):
            frameworks.selected_toolchain(self.lock, 'foreign')

    def test_github_observed_core_and_unpinned_tool_family(self):
        tool = self.run_preflight()
        self.assert_family_captured()
        self.assertEqual(self.receipt()['status'], 'PRESENT')
        self.assertEqual(tool['version_capture_only'], ['ar', 'libtool', 'swift'])
        self.assertEqual(set(tool['extra_tool_query_status'].values()), {'PRESENT'})
        self.assertEqual(tool['exact_pins_state'], 'CORE_EXACT_PINS_VERIFIED_EXTRA_VERSIONS_NOT_PINNED')

    def test_all_pinned_siblings_refused_after_family_capture(self):
        changes = [
            (('xcodebuild', '-version'), 'Xcode 27.0\nBuild version OWN_DIFFERENT\n'),
            (('xcrun', '--show-sdk-version'), '27.1\n'),
            (('/OWN/clang', '--version'), 'Apple clang version 21.0.0 (clang-OTHER)\n'),
            (('/OWN/clang++', '--version'), 'Apple clang version 21.0.0 (clang-OTHER)\n'),
            (('xcrun', 'swift', '--version'), 'Apple Swift version 7.OWN_FIXTURE\n'),
            (('xcrun', 'ld', '-v'), '@(#)PROGRAM:ld PROJECT:ld-27037.1.0\n'),
            (('xcrun', 'ld', '-v'), '@(#)PROGRAM:ld PROJECT:ld-27037.10\n'),
            (('xcrun', 'ld', '-v'), '@(#)PROGRAM:ld PROJECT:ld-27037.1extra\n'),
        ]
        for words, value in changes:
            with self.subTest(words=words, value=value):
                original = self.fixture[words]
                self.fixture[words] = value
                with self.assertRaises((ValueError, AssertionError)):
                    self.run_preflight()
                self.assertEqual(self.receipt()['status'], 'FAILED')
                self.assert_family_captured()
                self.fixture[words] = original

    def test_capture_only_failure_preserves_raw_and_continues_family(self):
        self.returncodes[('xcrun', 'libtool', '-V')] = 1
        tool = self.run_preflight()
        self.assert_family_captured()
        self.assertEqual(tool['extra_tool_query_status']['libtool'], 'FAILED')
        report = self.receipt()
        row = next(row for row in report['commands'] if row['argv'] == ['xcrun', 'libtool', '-V'])
        self.assertEqual(row['rc'], 1)
        self.assertEqual(row['stdout'], self.fixture[('xcrun', 'libtool', '-V')])
        self.assertEqual(report['version_query_status']['swift'], 'PRESENT')
        self.assertEqual(report['status'], 'PRESENT')

    def test_empty_unpinned_version_is_explicit(self):
        self.fixture[('xcrun', 'ar', '--version')] = ''
        tool = self.run_preflight()
        self.assertEqual(tool['extra_tool_query_status']['ar'], 'EMPTY')
        self.assert_family_captured()

    def test_cloud_still_requires_cloud_ld_version(self):
        with self.assertRaises(ValueError):
            self.run_preflight('xcode-cloud')
        self.assertNotIn(('xcrun', 'ar', '--version'), self.calls)
        self.fixture[('xcrun', 'ld', '-v')] = '@(#)PROGRAM:ld PROJECT:ld-27037.1.0\n'
        tool = self.run_preflight('xcode-cloud')
        self.assertEqual(tool['exact_pins_state'], 'MEASURED_BEFORE_SOURCES')
        self.assertEqual(self.receipt()['status'], 'PRESENT')


if __name__ == '__main__':
    unittest.main()

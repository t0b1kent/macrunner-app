"""Offline source/product boundary controls; no third-party source execution."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_app_frameworks as b


class FrameworkBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = HERE / '.offline-fixtures' / uuid.uuid4().hex
        cls.root.mkdir(parents=True)
        cls.lock = b.read_lock()

    def row(self):
        return copy.deepcopy(self.lock['components'][0])

    def settings(self):
        row = self.row()
        source, products = self.root / 'source', self.root / 'products'
        data = [dict(target=row['target'], buildSettings=dict(
            SRCROOT=str(source), PROJECT_DIR=str(source), BUILT_PRODUCTS_DIR=str(products),
            CODE_SIGNING_ALLOWED='NO', ARCHS='arm64', FULL_PRODUCT_NAME=row['product'], MACH_O_TYPE='mh_dylib'))]
        return row, source, products, data

    def framework(self, row=None):
        row = row or self.row()
        root = self.root / uuid.uuid4().hex / row['product']
        root.mkdir(parents=True)
        for name in row['required_binaries']:
            p = root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture-owned-test-data')
        p = root / 'Versions/B/Resources/Info.plist'
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(plistlib.dumps(dict(CFBundleShortVersionString=row['version'])))
        return root

    def test_pinned_components_and_six_production_binaries(self):
        self.assertEqual([r['version'] for r in self.lock['components']], ['2.6.4', '1.11.2'])
        self.assertEqual(sum(len(r['required_binaries']) for r in self.lock['components']), 6)

    def test_source_positive_exact(self):
        row = self.row()
        b.validate_git(row, row['revision'], 'commit', row['url'], '', '100644 blob\tfile\n')

    def test_source_revision_drift(self):
        row = self.row()
        with self.assertRaises(ValueError): b.validate_git(row, 'f'*40, 'commit', row['url'], '', '')

    def test_source_tag_object_is_not_commit(self):
        row = self.row()
        with self.assertRaises(ValueError): b.validate_git(row, row['revision'], 'tag', row['url'], '', '')

    def test_source_foreign_origin(self):
        row = self.row()
        with self.assertRaises(ValueError): b.validate_git(row, row['revision'], 'commit', 'https://invalid.example/repo', '', '')

    def test_source_dirty(self):
        row = self.row()
        with self.assertRaises(ValueError): b.validate_git(row, row['revision'], 'commit', row['url'], ' M source.m', '')

    def test_source_submodule_not_silently_skipped(self):
        row = self.row()
        with self.assertRaisesRegex(ValueError, '1 gitlinks'):
            b.validate_git(row, row['revision'], 'commit', row['url'], '', '160000 commit\tvendor\n')

    def test_xcode_own(self):
        row, source, products, data = self.settings()
        self.assertEqual(b.source_settings(json.dumps(data), source, products, row)['status'], 'PRESENT')

    def test_xcode_each_foreign_root_and_output(self):
        for key in ['SRCROOT', 'PROJECT_DIR', 'BUILT_PRODUCTS_DIR']:
            row, source, products, data = self.settings()
            data[0]['buildSettings'][key] = str(self.root / 'foreign')
            with self.subTest(key=key), self.assertRaises(ValueError):
                b.source_settings(json.dumps(data), source, products, row)

    def test_xcode_wrong_product_signing_arch_and_type(self):
        for key, value in [('FULL_PRODUCT_NAME', 'Other.framework'), ('CODE_SIGNING_ALLOWED', 'YES'),
                           ('ARCHS', 'arm64 x86_64'), ('MACH_O_TYPE', 'staticlib')]:
            row, source, products, data = self.settings()
            data[0]['buildSettings'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                b.source_settings(json.dumps(data), source, products, row)

    def test_xcode_empty_and_wrong_json_types(self):
        row, source, products, data = self.settings()
        for bad in [[], {}, 'text', [1], [dict(target=row['target'], buildSettings='text')]]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                b.source_settings(json.dumps(bad), source, products, row)

    def test_xcode_target_missing_or_duplicated(self):
        row, source, products, data = self.settings()
        for bad in [data*2, [dict(data[0], target='Other')]]:
            with self.assertRaises(ValueError): b.source_settings(json.dumps(bad), source, products, row)

    def product_settings(self):
        row, source, products, data = self.settings()
        row = copy.deepcopy(self.lock['components'][1])
        aggregate = copy.deepcopy(data[0])
        aggregate['target'] = 'CrashReporter'
        for key in ['FULL_PRODUCT_NAME', 'MACH_O_TYPE']:
            aggregate['buildSettings'].pop(key)
        native = copy.deepcopy(data[0])
        native['target'] = 'OWN PLC macOS Framework'
        native['buildSettings'].update(FULL_PRODUCT_NAME=row['product'], MACH_O_TYPE='mh_dylib',
                                       PRODUCT_TYPE='com.apple.product-type.framework', SUPPORTED_PLATFORMS='macosx')
        static = copy.deepcopy(native)
        static['target'] = 'OWN PLC Static'
        static['buildSettings']['MACH_O_TYPE'] = 'staticlib'
        ios = copy.deepcopy(native)
        ios['target'] = 'OWN PLC iOS Framework'
        ios['buildSettings']['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
        return row, source, products, [aggregate, native, static, ios]

    def test_product_selects_unique_macos_dynamic_framework(self):
        row, source, products, data = self.product_settings()
        result = b.source_settings(json.dumps(data), source, products, row)
        self.assertEqual(result['selected'], ['OWN PLC macOS Framework'])
        self.assertEqual(result['targets'], 4)
        self.assertEqual(result['selection'], 'unique-macos-dynamic-framework')
        self.assertEqual(len(result['observed']), 4)

    def test_product_aggregate_static_ios_and_wrong_product_refused(self):
        row, source, products, data = self.product_settings()
        wrong = copy.deepcopy(data[1])
        wrong['buildSettings']['FULL_PRODUCT_NAME'] = 'OTHER.framework'
        for bad in [[data[0]], [data[2]], [data[3]], [wrong]]:
            with self.subTest(target=bad[0]['target']), self.assertRaisesRegex(ValueError, 'missing/ambiguous'):
                b.source_settings(json.dumps(bad), source, products, row)

    def test_product_multiple_matching_targets_refused(self):
        row, source, products, data = self.product_settings()
        duplicate = copy.deepcopy(data[1])
        duplicate['target'] = 'OWN Second macOS Framework'
        with self.assertRaisesRegex(ValueError, 'missing/ambiguous'):
            b.source_settings(json.dumps(data + [duplicate]), source, products, row)

    def test_product_wrong_type_platform_and_resolved_target_refused(self):
        row, source, products, data = self.product_settings()
        for key, value in [('PRODUCT_TYPE', 'com.apple.product-type.library.static'),
                           ('SUPPORTED_PLATFORMS', ''), ('FULL_PRODUCT_NAME', 'CrashReporter.a')]:
            changed = copy.deepcopy(data)
            changed[1]['buildSettings'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                b.source_settings(json.dumps(changed), source, products, row)
        for target in ['-OTHER_OPTION', 'OWN\nOTHER', 'OWN/FOREIGN']:
            changed = copy.deepcopy(data)
            changed[1]['target'] = target
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, 'Unsafe resolved'):
                b.source_settings(json.dumps(changed), source, products, row)

    def test_product_keeps_source_signing_arch_and_selected_output_guards(self):
        row, source, products, data = self.product_settings()
        for index, key, value in [(0, 'SRCROOT', str(self.root / 'foreign')),
                                  (1, 'PROJECT_DIR', str(self.root / 'foreign')),
                                  (1, 'BUILT_PRODUCTS_DIR', str(self.root / 'foreign')),
                                  (1, 'CODE_SIGNING_ALLOWED', 'YES'), (1, 'ARCHS', 'arm64 x86_64')]:
            changed = copy.deepcopy(data)
            changed[index]['buildSettings'][key] = value
            with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                b.source_settings(json.dumps(changed), source, products, row)
        data[3]['buildSettings']['BUILT_PRODUCTS_DIR'] = str(self.root / 'OWN_UNSELECTED_IOS_DIR')
        self.assertEqual(b.source_settings(json.dumps(data), source, products, row)['selected'], ['OWN PLC macOS Framework'])

    def test_product_alltargets_is_settings_only_and_build_uses_resolved_target(self):
        row, source, products, data = self.product_settings()
        settings = b.xcode_args(source, products, row, 4, settings=True)
        self.assertIn('-alltargets', settings)
        self.assertNotIn('-target', settings)
        selected = b.source_settings(json.dumps(data), source, products, row)['selected'][0]
        argv = b.xcode_args(source, products, dict(row, target=selected), 4)
        self.assertNotIn('-alltargets', argv)
        self.assertEqual(argv[argv.index('-target') + 1], selected)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', argv)
        sparkle = self.row()
        self.assertNotIn('-alltargets', b.xcode_args(source, products, sparkle, 4, settings=True))

    def test_product_full_sparkle_helper_family(self):
        self.assertEqual(len(b.product_paths(self.framework(), self.row())), 5)

    def test_product_each_missing_helper(self):
        for name in self.row()['required_binaries']:
            root = self.framework()
            # A renamed fixture preserves the original bytes; no source/runtime removal.
            p = root / name
            p.rename(p.with_name(p.name + '.missing-fixture'))
            with self.subTest(name=name), self.assertRaises(ValueError): b.product_paths(root, self.row())

    def test_product_wrong_bytes(self):
        root = self.framework()
        p = root / self.row()['required_binaries'][0]
        p.write_bytes(b'fixture text')
        with self.assertRaises(ValueError): b.product_paths(root, self.row())

    def test_product_unexpected_compiled_input(self):
        root = self.framework()
        (root / 'extra-binary').write_bytes(b'\xcf\xfa\xed\xfefixture')
        with self.assertRaisesRegex(ValueError, 'census'): b.product_paths(root, self.row())

    def test_product_wrong_version(self):
        root = self.framework()
        p = root / 'Versions/B/Resources/Info.plist'
        p.write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='9.9')))
        with self.assertRaisesRegex(ValueError, 'version'): b.product_paths(root, self.row())

    def test_product_symlinks_internal_and_escape(self):
        root = self.framework()
        (root / 'Current').symlink_to('Versions/B')
        self.assertEqual(len(b.product_paths(root, self.row())), 5)
        (root / 'escape').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'escapes'): b.product_paths(root, self.row())

    def test_product_dangling_link(self):
        root = self.framework()
        (root / 'dangling').symlink_to('absent')
        with self.assertRaisesRegex(ValueError, 'dangles'): b.product_paths(root, self.row())

    def test_architecture_no_universal_or_rosetta(self):
        b.validate_architectures('arm64\n')
        for wrong in ['', 'x86_64', 'arm64 x86_64', 'arm64 arm64']:
            with self.subTest(wrong=wrong), self.assertRaises(ValueError): b.validate_architectures(wrong)

    def test_source_env_excludes_private_credentials_and_git_injection(self):
        with patch.dict(os.environ, dict(RESULTS_TOKEN='fixture-only', GH_TOKEN='fixture-only',
                                        GIT_TRACE='1', GIT_CONFIG_COUNT='1', GIT_CONFIG_VALUE_0='fixture-only')):
            env = b.build_env()
        for key in ['RESULTS_TOKEN', 'GH_TOKEN', 'GIT_TRACE', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_VALUE_0']:
            self.assertNotIn(key, env)
        self.assertEqual(env['GIT_TERMINAL_PROMPT'], '0')

    def test_cloud_guard_before_work_or_source_access(self):
        class Args: work = self.root / 'must-not-exist'
        with patch.dict(os.environ, {'CI_XCODE_CLOUD': '', 'GITHUB_ACTIONS': ''}), self.assertRaisesRegex(ValueError, 'Cloud'):
            b.build(Args(), self.lock)
        self.assertFalse(Args.work.exists())

    def test_failed_early_publication_stops_before_sources_once(self):
        work = self.root / uuid.uuid4().hex
        args = SimpleNamespace(work=work, publish_dir=self.root / uuid.uuid4().hex, minutes=1, jobs=1)
        calls = []
        def publisher(path):
            calls.append(path)
            raise RuntimeError('fixture publication denial')
        original = b.LiveResults
        def live(*words, **fields):
            return original(*words, **fields, publisher=publisher)
        runner = SimpleNamespace(toolchain_preflight=lambda *x: self.fail('toolchain/source work after publication denial'))
        with patch.dict(os.environ, {'CI_XCODE_CLOUD': 'TRUE'}), patch.object(b.platform, 'system', return_value='Darwin'), \
             patch.object(b.platform, 'machine', return_value='arm64'), patch.object(b, 'load_runner', return_value=runner), \
             patch.object(b, 'LiveResults', side_effect=live):
            self.assertEqual(b.build(args, self.lock), 1)
        self.assertEqual(len(calls), 1)
        result = json.loads((work / 'reports/RESULT.json').read_text())
        self.assertEqual(result['status'], 'FAILED')
        self.assertEqual(result['components'], [])
        self.assertIn('publication_failure', result)
        self.assertTrue((args.publish_dir / 'PROGRESS.json').is_file())

    def test_xcode_argv_unsigned_own_and_no_distribution_script(self):
        argv = b.xcode_args(self.root / 'source', self.root / 'build', self.row(), 4)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', argv)
        self.assertIn('ARCHS=arm64', argv)
        self.assertIn('DEVELOPMENT_TEAM=', argv)
        self.assertNotIn('Distribution', argv)
        self.assertFalse(any(x in argv for x in ['codesign', 'notarytool', '-allowProvisioningUpdates']))

    def test_existing_runner_import_on_integrated_private_main(self):
        runner = b.load_runner()
        for name in ['command', 'inventory', 'toolchain_preflight']:
            self.assertTrue(callable(getattr(runner, name)))

    def test_exact_shell_wrapper_preserves_failure_and_partial_outputs(self):
        fixture = self.root / uuid.uuid4().hex
        jobs = fixture / 'jobs'
        jobs.mkdir(parents=True)
        stub = fixture / 'own-fixture-python'
        stub.write_text('#!' + sys.executable + '\n'
                        'from pathlib import Path\nimport sys\n'
                        'p=Path(sys.argv[sys.argv.index("--work")+1])\n'
                        '(p/"reports").mkdir(parents=True)\n'
                        '(p/"prefix").mkdir()\n'
                        '(p/"reports/RESULT.json").write_text("{\\"status\\":\\"FAILED_FIXTURE\\"}\\n")\n'
                        '(p/"prefix/partial-own-fixture.txt").write_text("fixture\\n")\n'
                        'sys.exit(7)\n')
        stub.chmod(0o755)
        original = (b.REPO / 'jobs/repro109-app-frameworks.sh').read_text()
        # Replace only the interpreter path in an owned fixture, preserve the authored suffix verbatim.
        self.assertEqual(original.count('/usr/bin/python3'), 1)
        script = jobs / 'repro109-app-frameworks.sh'
        script.write_text(original.replace('/usr/bin/python3', '"' + str(stub) + '"'))
        out = fixture / 'results'
        env = dict(os.environ, CI_XCODE_CLOUD='TRUE', CI_WORKSPACE_PATH=str(fixture))
        child = subprocess.run(['/bin/bash', str(script), str(out), 'xcode-cloud'],
                               env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        (fixture / 'stdout.log').write_bytes(child.stdout)
        (fixture / 'stderr.log').write_bytes(child.stderr)
        self.assertEqual(child.returncode, 7)
        self.assertEqual((out / 'frameworks-rc.txt').read_text().strip(), '7')
        self.assertEqual(json.loads((out / 'RESULT.json').read_text())['status'], 'FAILED_FIXTURE')
        self.assertTrue((out / 'app-frameworks-prefix.tar.gz').is_file())
        self.assertIn(b.sha(out / 'app-frameworks-prefix.tar.gz'), (out / 'app-frameworks-prefix.sha256').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)

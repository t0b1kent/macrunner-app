"""Authored inert fixtures exercise shared full/tail code, never vendor code."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_python_helpers as builder
import helper_tail as tail


class HelperTailTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        product = self.work / 'product'; product.mkdir()
        prefix = self.work / 'prefix'; (prefix / 'share/licenses/inert').mkdir(parents=True)
        (prefix / 'share/licenses/inert/LICENSE').write_text('AUTHORED INERT LICENSE FIXTURE\n')
        for name in ('legendary', 'gogdl'): (product / name).write_text('AUTHORED INERT PRODUCT\n')
        rows = {name: dict(name=name, revision='a' * 40, version='1.0',
                    requirements_sha256='fixture', pyproject_sha256='fixture') for name in ('legendary', 'gogdl', 'xdelta3')}
        self.mark = Mock()
        def command(argv, cwd, label, timeout):
            if label == 'gogdl-xdelta-gitlink':
                return ('160000 commit ' + rows['xdelta3']['revision'] + '\txdelta3\n').encode()
            return b'INERT MOCKED COMMAND\n'
        def checkout(row, path):
            path.mkdir(exist_ok=True)
            return {'name': row['name']}
        package = Mock(side_effect=lambda source, row, **kwargs: {'console_scripts': {row['name']: row['name'] + '.cli:main'}})
        self.c = SimpleNamespace(work=self.work, prefix=prefix, product=product,
            publish_dir=self.work / 'published', python=self.work / 'inert-python', here=HERE,
            rows=rows, command=Mock(side_effect=command), checkout=Mock(side_effect=checkout),
            package=package, runner=SimpleNamespace(licenses=Mock(return_value=['inert-license'])),
            sha=lambda path: 'fixture' if path.name in ('requirements.txt', 'pyproject.toml') else hashlib.sha256(path.read_bytes()).hexdigest(),
            portable_cli=Mock(), result={'helpers': []}, save=Mock(), mark=self.mark)

    def test_all_thirteen_axes_are_in_independent_workflow_jobs(self):
        workflow = (HERE.parents[1] / '.github/workflows/repro109-python-helpers-matrix-macos15-arm64.yml').read_text()
        arrays = re.findall(r'axis: \[([^\]]+)\]', workflow)
        axes = [item.strip() for array in arrays for item in array.split(',')]
        self.assertEqual(len(axes), 13)
        self.assertEqual(set(axes), set(tail.AXES))
        self.assertEqual(len(set(axes)), 13)
        for job in ('tail-source:', 'tail-build:'):
            text = workflow.split('  ' + job, 1)[1]
            text = re.split(r'\n  [A-Za-z][\w-]*:\n', text, maxsplit=1)[0]
            self.assertIn('fail-fast: false', text)

    def test_each_license_axis_uses_the_full_producers_collector(self):
        for axis in tail.SOURCE_AXES[:3]:
            with self.subTest(axis=axis):
                record = tail.source_axis(axis, self.c.rows, self.work, self.c.prefix,
                    self.c.checkout, self.c.runner, self.c.command, self.mark)
                name = axis.split('-', 1)[1]
                self.c.runner.licenses.assert_called_with(self.work / (name + '-source'), self.c.prefix, name)
                self.assertEqual(record['licenses'], ['inert-license'])

    def test_gitlink_exact_revision_and_drift(self):
        source = self.work / 'source'
        self.assertEqual(tail.gitlink(source, self.c.rows, self.c.command, self.work)['revision'], 'a' * 40)
        bad = Mock(return_value=b'160000 commit wrong\txdelta3\n')
        with self.assertRaises(ValueError): tail.gitlink(source, self.c.rows, bad, self.work)

    def test_full_helper_keeps_xdelta_licenses_and_package_collection(self):
        record = tail.helper('gogdl', self.c)
        self.c.runner.licenses.assert_called_once_with(self.work / 'gogdl-source/xdelta3', self.c.prefix, 'xdelta3')
        self.assertTrue(self.c.package.call_args.kwargs['collect_licenses'])
        self.assertEqual(record['status'], 'SOURCE_BUILT_CLI_HELP_PASS')
        labels = [call.args[2] for call in self.c.command.call_args_list]
        self.assertIn('gogdl-native-extension-smoke', labels)
        self.assertIn('gogdl-freeze', labels)
        self.assertIn('gogdl-cli-help', labels)

    def test_independent_helper_build_is_explicitly_not_license_acceptance(self):
        tail.helper('gogdl', self.c, collect_licenses=False)
        self.c.runner.licenses.assert_not_called()
        self.assertFalse(self.c.package.call_args.kwargs['collect_licenses'])
        self.assertEqual(self.c.result['helpers'][0]['license_review'], 'NOT_ENABLED_IN_INDEPENDENT_BUILD_AXIS')

    def test_source_controls_refused_before_wheel_or_freeze(self):
        self.c.sha = lambda path: 'wrong'
        with self.assertRaises(ValueError): tail.helper('legendary', self.c)
        self.c.package.assert_not_called()
        self.c.command.assert_not_called()

    def test_unsafe_entry_refused_before_freeze(self):
        self.c.package = Mock(return_value={'console_scripts': {'legendary': '../unsafe'}})
        with self.assertRaises(ValueError): tail.helper('legendary', self.c)
        self.assertFalse(any(call.args[2] == 'legendary-freeze' for call in self.c.command.call_args_list))

    def test_runtime_and_both_architecture_operations_have_exact_targets(self):
        for axis, target in [('runtime-dependency-closure', None),
                ('compiled-python-extensions-architectures', self.c.prefix), ('helpers-architectures', self.c.product)]:
            tail.final_axis(axis, self.c)
            argv = self.c.command.call_args.args[0]
            self.assertEqual(argv[-1], str(target) if target else 'check')

    def test_prefix_hidden_operation_calls_the_existing_portable_smoke(self):
        tail.final_axis('prefix-hidden-cli', self.c)
        self.c.portable_cli.assert_called_once_with(self.c.prefix, self.c.product, self.c.command)

    def test_archive_and_published_copy_are_same_owned_bytes(self):
        tail.final_axis('publish-copy', self.c)
        original, published = self.work / 'helpers.tar.gz', self.c.publish_dir / 'helpers.tar.gz'
        self.assertEqual(original.read_bytes(), published.read_bytes())
        with tarfile.open(original) as stream:
            self.assertEqual(stream.extractfile('licenses/inert/LICENSE').read(), b'AUTHORED INERT LICENSE FIXTURE\n')
            self.assertEqual(stream.extractfile('gogdl').read(), b'AUTHORED INERT PRODUCT\n')
        self.assertEqual(self.c.result['archive']['sha256'], hashlib.sha256(original.read_bytes()).hexdigest())

    def test_full_run_uses_all_final_operations_and_complete_license_mode(self):
        with patch.object(tail, 'helper') as helper:
            tail.run(self.c)
        self.assertEqual([call.args[0] for call in helper.call_args_list], ['legendary', 'gogdl'])
        self.assertTrue(all(call.kwargs['collect_licenses'] for call in helper.call_args_list))
        stages = [call.args[0] for call in self.mark.call_args_list]
        self.assertTrue(set(tail.BUILD_AXES[2:]).issubset(stages))

    def test_each_compiled_axis_dispatches_without_becoming_full_acceptance(self):
        with patch.object(tail, 'helper') as helper, patch.object(tail, 'final_axis') as final:
            for axis in tail.BUILD_AXES:
                helper.reset_mock(); final.reset_mock(); tail.run(self.c, axis)
                self.assertTrue(all(call.kwargs['collect_licenses'] is False for call in helper.call_args_list))
                if axis.startswith('helper-'): final.assert_not_called()
                else: final.assert_called_once_with(axis, self.c)

    def test_source_license_failure_retains_first_failure_without_native_build(self):
        args = SimpleNamespace(work=self.work / 'source-tail', tail_axis='licenses-xdelta3', minutes=8)
        lock = {'helpers': list(self.c.rows.values())}
        runner = SimpleNamespace(licenses=Mock(side_effect=ValueError('INERT MISSING LICENSE EVIDENCE')))
        with patch.object(builder.native, 'require_cloud'), \
                patch.object(builder.native.framework, 'load_runner', return_value=runner), \
                patch.object(builder.native.framework, 'build_env', return_value={}), \
                patch.object(builder, 'checkout_source', return_value={'files': 1}), \
                patch.object(builder.native, 'build') as native_build:
            with self.assertRaisesRegex(ValueError, 'MISSING LICENSE'): builder.verify_tail_source(args, lock)
        native_build.assert_not_called()
        record = json.loads((args.work / 'reports/RESULT.json').read_text())
        self.assertEqual(record['first_failure']['phase'], 'licenses-xdelta3')
        self.assertEqual(record['compile'], 'NOT_ENABLED')

    def test_tail_cli_plan_has_zero_work_and_conflicting_selectors_refuse(self):
        driver = HERE / 'build_python_helpers.py'
        process = subprocess.run([sys.executable, '-I', '-B', str(driver), '--tail-axis', 'helper-gogdl'],
                                 capture_output=True, timeout=15)
        self.assertEqual(process.returncode, 0, process.stderr)
        record = json.loads(process.stdout)
        self.assertEqual(record['tail_axis'], 'helper-gogdl')
        self.assertEqual((record['network'], record['builds']), (0, 0))
        for flag in ('--native-only', '--only-step'):
            argv = [sys.executable, '-I', '-B', str(driver), '--tail-axis', 'helper-gogdl', flag]
            if flag == '--only-step': argv.append('23')
            process = subprocess.run(argv, capture_output=True, timeout=15)
            self.assertEqual(process.returncode, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)

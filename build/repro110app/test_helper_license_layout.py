"""Inert notices exercise the actual collector and both helper producer paths."""
import hashlib
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'repro109deps'))
import build_deps as collector
import helper_tail as tail


class HelperLicenseLayoutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.source = self.work / 'source'
        self.source.mkdir()
        self.prefix = self.work / 'prefix'
        self.notice = b'AUTHORED INERT NOTICE; NOT A THIRD PARTY LICENSE\n'

    def put(self, root, relative):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.notice)

    def check_notice(self, rows, prefix, relative, name):
        self.assertEqual(len(rows), 1)
        record = rows[0]
        self.assertEqual(record['source_path'], relative)
        self.assertEqual(record['path'], 'share/licenses/' + name + '/' + relative.replace('/', '__'))
        self.assertEqual(record['sha256'], hashlib.sha256(self.notice).hexdigest())
        self.assertEqual((prefix / record['path']).read_bytes(), self.notice)

    def test_root_notice_names(self):
        for index, relative in enumerate(('LICENSE', 'LICENSE.md', 'COPYING', 'COPYING.LESSER', 'Copyright.txt', 'Copyright.md')):
            with self.subTest(relative=relative):
                source = self.source / str(index)
                self.put(source, relative)
                prefix = self.prefix / str(index)
                self.check_notice(collector.licenses(source, prefix, 'root'), prefix, relative, 'root')

    def test_existing_documentation_and_subproject_layouts(self):
        for index, relative in enumerate(('docs/LICENSE.TXT', 'docs/FTL.TXT', 'docs/GPLv2.TXT',
                'LICENSES/LGPL-2.1-or-later.txt', 'LICENSES/MIT.txt', 'gettext-runtime/intl/COPYING.LIB')):
            with self.subTest(relative=relative):
                source = self.source / str(index)
                self.put(source, relative)
                prefix = self.prefix / str(index)
                self.check_notice(collector.licenses(source, prefix, 'nested'), prefix, relative, 'nested')

    def test_xdelta_git_checkout_layout(self):
        self.put(self.source, 'xdelta3/LICENSE')
        self.check_notice(collector.licenses(self.source, self.prefix, 'xdelta3'), self.prefix, 'xdelta3/LICENSE', 'xdelta3')

    def test_top_level_and_nested_notices_are_both_preserved(self):
        for relative in ('LICENSE', 'xdelta3/LICENSE'):
            self.put(self.source, relative)
        rows = collector.licenses(self.source, self.prefix, 'combined')
        self.assertEqual([row['source_path'] for row in rows], ['LICENSE', 'xdelta3/LICENSE'])
        self.assertEqual(len(list((self.prefix / 'share/licenses/combined').iterdir())), 2)
        for row in rows:
            self.assertEqual((self.prefix / row['path']).read_bytes(), self.notice)

    def test_absent_notice_refuses_before_creating_output(self):
        with self.assertRaisesRegex(AssertionError, 'missing license evidence'):
            collector.licenses(self.source, self.prefix, 'absent')
        self.assertFalse(self.prefix.exists())

    def test_directories_are_not_license_evidence(self):
        (self.source / 'LICENSE').mkdir()
        (self.source / 'xdelta3/LICENSE').mkdir(parents=True)
        with self.assertRaisesRegex(AssertionError, 'missing license evidence'):
            collector.licenses(self.source, self.prefix, 'directories')
        self.assertFalse(self.prefix.exists())

    def test_all_three_source_license_axes_use_real_collector(self):
        rows = {name: {'name': name} for name in ('legendary', 'gogdl', 'xdelta3')}
        def checkout(row, source):
            relative = 'xdelta3/LICENSE' if row['name'] == 'xdelta3' else 'LICENSE'
            self.put(source, relative)
            return {'name': row['name']}
        command = Mock(side_effect=AssertionError('No vendor command may run in this fixture'))
        for name in rows:
            with self.subTest(name=name):
                prefix = self.prefix / name
                record = tail.source_axis('licenses-' + name, rows, self.work, prefix, checkout, collector, command, Mock())
                relative = 'xdelta3/LICENSE' if name == 'xdelta3' else 'LICENSE'
                self.check_notice(record['licenses'], prefix, relative, name)
        command.assert_not_called()

    def test_full_gogdl_nested_git_checkout_uses_real_collector(self):
        rows = {name: dict(name=name, revision='a' * 40, version='fixture', pyproject_sha256='fixture')
                for name in ('gogdl', 'xdelta3')}
        def checkout(row, source):
            self.put(source, 'xdelta3/LICENSE' if row['name'] == 'xdelta3' else 'LICENSE')
            return {'name': row['name']}
        def command(argv, cwd, label, timeout):
            if label == 'gogdl-xdelta-gitlink':
                return ('160000 commit ' + rows['xdelta3']['revision'] + '\txdelta3\n').encode()
            return b'INERT MOCK; NO VENDOR EXECUTION\n'
        product = self.work / 'product'
        product.mkdir()
        (product / 'gogdl').write_bytes(b'INERT PRODUCT FIXTURE\n')
        c = SimpleNamespace(work=self.work, prefix=self.prefix, product=product, python=self.work / 'inert-python',
            rows=rows, checkout=checkout, command=Mock(side_effect=command), runner=collector,
            package=Mock(return_value={'console_scripts': {'gogdl': 'gogdl.cli:main'}}),
            sha=lambda path: 'fixture', mark=Mock(), save=Mock(), result={'helpers': []})
        result = tail.helper('gogdl', c)
        self.check_notice(result['xdelta3']['licenses'], self.prefix, 'xdelta3/LICENSE', 'xdelta3')
        self.assertTrue(c.package.call_args.kwargs['collect_licenses'])
        self.assertEqual(result['status'], 'SOURCE_BUILT_CLI_HELP_PASS')
        self.assertEqual(result['xdelta3']['name'], 'xdelta3')


if __name__ == '__main__':
    unittest.main()

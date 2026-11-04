"""Own inert installer source/absent-tool fixtures; no downloads or compilation."""
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('inno_source', Path(__file__).with_name('build_innoextract.py'))
producer = importlib.util.module_from_spec(spec); spec.loader.exec_module(producer)


class InstallerSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_isolated_entrypoint_from_foreign_cwd(self):
        child = subprocess.run([sys.executable, '-I', '-B', producer.__file__, '--help'],
                               cwd=self.root, capture_output=True, text=True, timeout=10)
        self.assertEqual(child.returncode, 0, child.stderr)

    def test_each_missing_platform_tool_refuses_before_source_work(self):
        for name in ['git', 'make', 'xcrun', 'xcodebuild', 'install_name_tool']:
            with self.subTest(name=name), patch.object(producer.shutil, 'which',
                    side_effect=lambda value: None if value == name else '/own/tool'):
                with self.assertRaisesRegex(ValueError, 'tool missing'):
                    producer.require_tools('build')

    def test_source_bytes_are_bounded_and_hash_checked(self):
        row = dict(name='own', url='https://example.invalid/own', maximum_size=4,
                   sha256=hashlib.sha256(b'own').hexdigest())
        with patch.object(producer.urllib.request, 'urlopen', return_value=io.BytesIO(b'own')):
            producer.fetch(row, self.root / 'valid')
        for name, data in [('cap', b'over cap'), ('sha', b'bad')]:
            with self.subTest(name=name), patch.object(producer.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                with self.assertRaises(ValueError):
                    producer.fetch(row, self.root / name)

    def test_icu_uses_the_extracted_source_and_boost_is_bounded_native_arm64(self):
        icu = producer.steps(dict(kind='icu'), self.root / 'source', self.root / 'prefix', self.root / 'sdk', ('cc', 'c++'))
        self.assertEqual(icu[0][0], str(self.root / 'source/source/configure'))
        self.assertEqual(icu[1], ['make', '-j2'])
        boost = producer.steps(dict(kind='boost'), self.root / 'source', self.root / 'prefix', self.root / 'sdk', ('cc', 'c++'))
        self.assertIn('-j2', boost[1])
        self.assertIn('architecture=arm', boost[1])
        self.assertIn('address-model=64', boost[1])


if __name__ == '__main__':
    unittest.main()

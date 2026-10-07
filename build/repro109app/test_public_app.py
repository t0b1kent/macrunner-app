import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_app_frameworks as frameworks
import prepare_source as source

HERE = Path(__file__).resolve().parent


class PublicAppTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()

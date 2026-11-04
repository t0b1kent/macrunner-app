"""Verify the release source delta against the preserved public 1.0.9 base."""
import hashlib
import json
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent
LOCK = json.loads((HERE / 'source.lock.json').read_bytes())
DELTA = LOCK['release110_delta']
BASE = HERE.parent / 'repro109app/source'
PERSONAL = re.compile('(' + '/Us' + r'ers/[A-Za-z0-9_.-]+|' + '/bui' + r'ld/[A-Za-z]+/|' + '/Vol' + r'umes/[A-Za-z]|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[a-z]+)')

class ReleaseSourceDelta(unittest.TestCase):
    def test_every_delta_file_has_exact_bytes_and_mode(self):
        self.assertEqual(len(DELTA['files']), DELTA['modified'] + DELTA['new'])
        self.assertGreater(DELTA['modified'], 0)
        self.assertGreater(DELTA['new'], 0)
        for row in DELTA['files']:
            path = HERE / 'source' / row['path']
            data = path.read_bytes()
            self.assertEqual((len(data), hashlib.sha256(data).hexdigest()), (row['bytes'], row['sha256']), row['path'])
            self.assertEqual(bool(path.stat().st_mode & 0o111), row['executable'], row['path'])

    def test_delta_preimages_match_the_unchanged_public_base(self):
        for row in DELTA['files']:
            old = BASE / row['path']
            expected = hashlib.sha256(old.read_bytes()).hexdigest() if old.exists() else None
            self.assertEqual(row['base_sha256'], expected, row['path'])
            self.assertNotEqual(row['base_sha256'], row['sha256'], row['path'])

    def test_no_personal_roots_or_mailboxes_in_changed_text(self):
        for row in DELTA['files']:
            text = (HERE / 'source' / row['path']).read_text(encoding='utf-8')
            self.assertEqual(sorted(set(m.group(0) for m in PERSONAL.finditer(text))), [], row['path'])

    def test_snapshot_counts_reconcile_with_the_base(self):
        self.assertEqual(LOCK['source_files'], 375 + DELTA['new'])
        self.assertEqual(LOCK['source_origin']['source_files'], 375)
        old = json.loads((BASE.parent / 'source.lock.json').read_bytes())
        self.assertEqual((old['source_files'], 'release110_delta' in old), (375, False))

    def test_workflow_selects_this_recipe_and_existing_test_modules(self):
        raw = (HERE.parents[1] / '.github/workflows/repro110-app-c12-source-xcode27-arm64.yml').read_text()
        text = '\n'.join(line for line in raw.splitlines() if not line.lstrip().startswith('#'))
        self.assertIn('build/repro110app', text)
        modules = re.search(r'for module in ([^;]+); do', text).group(1).split()
        self.assertGreaterEqual(len(modules), 7)
        for module in modules:
            self.assertTrue((HERE / (module + '.py')).is_file(), module)
        self.assertIn('retention-days: 30', text)
        self.assertIn('fail-fast: false', text)

if __name__ == '__main__':
    unittest.main(verbosity=2)

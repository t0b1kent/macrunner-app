"""Offline controls for the 1.1.0 candidate (c12) text sources layered on the pinned 1.0.8 snapshot."""
import hashlib
import json
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent
LOCK = json.loads((HERE / 'source.lock.json').read_bytes())
DELTA = LOCK['c12_delta']
# Personal machine roots, fixture roots that a public file must not carry, and mailboxes.
# Written in pieces so that this file itself carries no machine root.
PERSONAL = re.compile('(' + '/Us' + r'ers/[A-Za-z0-9_.-]+|' + '/bui' + r'ld/[A-Za-z]+/|' + '/Vol' + r'umes/[A-Za-z]|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+\.[a-z]+)')


class C12SourceDelta(unittest.TestCase):
    def test_every_row_matches_the_stored_file(self):
        self.assertEqual((DELTA['modified'], DELTA['new'], len(DELTA['files'])), (13, 12, 25))
        for row in DELTA['files']:
            data = (HERE / 'source' / row['path']).read_bytes()
            self.assertEqual((len(data), hashlib.sha256(data).hexdigest()), (row['bytes'], row['sha256']), row['path'])
            self.assertFalse(row['executable'], row['path'])

    def test_modified_rows_name_a_base_and_new_rows_do_not(self):
        for row in DELTA['files']:
            self.assertEqual(row['base_sha256'] is None, row['path'].startswith(
                ('engine-tools/', 'Sources/MacRunnerControlCenter/Services/CLI/')) or Path(row['path']).name in {
                'BottleTemplate.swift', 'BottleUpdateCatalogue.swift', 'LaunchDataRoot.swift', 'WarmBottleSessions.swift',
                'WarmSessionState.swift', 'BottleTemplateTests.swift', 'BottleUpdateCatalogueTests.swift',
                'SetupIdlePolicyTests.swift', 'WarmProfileIntegrationTests.swift'}, row['path'])
            self.assertNotEqual(row['base_sha256'], row['sha256'], row['path'])

    def test_no_personal_root_or_mailbox_in_the_added_sources(self):
        for row in DELTA['files']:
            text = (HERE / 'source' / row['path']).read_text(encoding='utf-8')
            self.assertEqual(sorted(set(m.group(0) for m in PERSONAL.finditer(text))), [], row['path'])

    def test_snapshot_totals_follow_the_delta(self):
        self.assertEqual(LOCK['source_files'], 375 + DELTA['new'])
        self.assertEqual(LOCK['source_origin']['source_files'], 375)


    def test_workflow_runs_this_recipe_only_and_names_existing_modules(self):
        raw = (HERE.parents[1] / '.github/workflows/repro110-app-c12-source-xcode27-arm64.yml').read_text()
        text = '\n'.join(line for line in raw.splitlines() if not line.lstrip().startswith('#'))
        self.assertIn('build/repro110app', text)
        self.assertNotIn('build/repro109app', text)
        modules = re.search(r'for module in ([^;]+); do', text).group(1).split()
        self.assertGreaterEqual(len(modules), 7)
        for module in modules:
            self.assertTrue((HERE / (module + '.py')).is_file(), module)
        self.assertIn('retention-days: 30', text)

    def test_the_1_0_9_recipe_stays_where_it_was_and_is_not_edited_by_this_directory(self):
        # build/repro109app keeps its 375-file snapshot; this copy differs only by the c12 delta and its tests.
        sibling = HERE.parent / 'repro109app'
        if sibling.is_dir():
            old = json.loads((sibling / 'source.lock.json').read_bytes())
            self.assertEqual((old['source_files'], 'c12_delta' in old), (375, False))

if __name__ == '__main__':
    unittest.main(verbosity=2)

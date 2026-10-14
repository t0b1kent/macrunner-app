import importlib.util
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('catalog', HERE/'gen-tested-games.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)

class TestedGamesGenerationTests(unittest.TestCase):
    def setUp(self):
        self.text = (HERE.parent/'TESTED_GAMES.md').read_text()
        self.routes = json.loads((HERE.parent/'graphics-profile-routes.json').read_text())

    def test_source_and_output_match_and_routing_survives(self):
        generated = catalog.generate(self.text, self.routes)
        self.assertEqual(generated, json.loads(catalog.RESOURCE.read_text()))
        by_id = {x['id']: x for x in generated['profiles']}
        for original in self.routes['profiles']:
            for key, value in original.items(): self.assertEqual(by_id[original['id']][key], value)
        for p in generated['profiles']:
            for row in p.get('known', []): self.assertTrue(row['evidence'].startswith('TESTED_GAMES.md#'))

    def test_deleted_release_row_is_rejected(self):
        text = '\n'.join(l for l in self.text.splitlines() if not l.startswith('| Factorio | Not rechecked'))
        with self.assertRaisesRegex(ValueError, 'Missing or changed'): catalog.generate(text, self.routes)

    def test_changed_unclassified_status_is_rejected(self):
        text = self.text.replace('Not rechecked for this release.', 'Unexpected new observation.')
        with self.assertRaisesRegex(ValueError, 'Unclassified'): catalog.generate(text, self.routes)

    def test_fixture_and_old_elden_claim_are_gone(self):
        out = catalog.generate(self.text, self.routes)
        factorio = next(x for x in out['profiles'] if x['id']=='factorio')
        self.assertEqual(factorio['known'][-1]['reached'], 'notRechecked')
        self.assertEqual(factorio['known'][0]['date'], '2026-09-11')
        self.assertNotIn('character missing', json.dumps(out))

if __name__ == '__main__': unittest.main()

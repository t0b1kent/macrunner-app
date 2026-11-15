#!/usr/bin/env python3
"""The bundled game catalogue must equal the generator's output for the routing data and TESTED_GAMES.md."""
import subprocess
import sys
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().with_name('source')


class TestedGamesCatalogTests(unittest.TestCase):
    def test_bundled_catalogue_has_not_drifted_from_its_sources(self):
        done = subprocess.run([sys.executable, '-I', '-B', str(SOURCE / 'scripts/gen-tested-games.py'), '--check'],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)


if __name__ == '__main__':
    unittest.main()

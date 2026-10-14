"""Shared full-build/source-matrix checkout controls; authored inert files only."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_python_helpers as builder


class HelperSourceMatrixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def exercise(self, name='legendary', refusal=None):
        source = self.root / name / (name + '-source')
        contents = {'owned.c': b'OWN_SOURCE\n', 'owned.sh': b'OWN_EXECUTABLE\n'}
        rows = [dict(path=p, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                     mode='0o755' if p.endswith('.sh') else '0o644') for p, data in contents.items()]
        digest = hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        row = dict(name=name, revision='a' * 40, url='https://github.com/own-fixture/source.git',
                   source_inventory_sha256=digest)
        args = types.SimpleNamespace(work=source.parent, minutes=1, verify_source=name)
        seen = []
        def command(argv, cwd, env, log, reports, label, deadline, timeout):
            seen.append(label)
            self.assertEqual(argv[0], '/usr/bin/git')
            self.assertNotIn('GH_TOKEN', env)
            if refusal == 'missing-tool':
                raise FileNotFoundError('OWN_MISSING_GIT')
            data = b''
            if label.endswith('-git-checkout'):
                for p, body in contents.items():
                    path = source / p; path.write_bytes(body)
                    path.chmod(0o775 if p.endswith('.sh') else 0o664)
            if label.endswith('-git-head'):
                data = (('b' * 40 if refusal == 'revision' else row['revision']) + '\n').encode()
            if label.endswith('-git-inventory'):
                if refusal == 'bytes':
                    (source / 'owned.c').write_bytes(b'OWN_CHANGED')
                if refusal == 'executable':
                    (source / 'owned.sh').chmod(0o644)
                if refusal == 'missing-file':
                    (source / 'owned.c').unlink()
                data = b'100644 ' + b'0' * 40 + b' 0\towned.c\0'
                data += b'100755 ' + b'1' * 40 + b' 0\towned.sh\0'
            log.write_bytes(data)
        runner = types.SimpleNamespace(command=command)
        with mock.patch.object(builder.native, 'require_cloud'), \
             mock.patch.object(builder.native.framework, 'load_runner', return_value=runner), \
             mock.patch.object(builder.native, 'build', side_effect=AssertionError('UNEXPECTED_COMPILER')), \
             mock.patch.dict(os.environ, {'GH_TOKEN': 'OWN_INERT_TOKEN'}, clear=True):
            try:
                result = builder.verify_source(args, dict(helpers=[row]))
            except Exception:
                result = json.loads((args.work / 'reports/RESULT.json').read_text())
                self.assertEqual(result['status'], 'FAILED')
                raise
        self.assertEqual(result['status'], 'PASS_EXACT_HELPER_SOURCE')
        self.assertEqual(result['source']['files'], 2)
        self.assertEqual(result['source']['source_inventory_sha256'], digest)
        self.assertEqual(seen[-1], name + '-git-inventory')
        self.assertEqual(result['compile'], 'NOT_ENABLED')

    def test_all_three_source_slots_execute_shared_checkout(self):
        for name in ['legendary', 'gogdl', 'xdelta3']:
            with self.subTest(name=name):
                self.exercise(name)

    def test_changed_bytes_refused(self):
        with self.assertRaisesRegex(ValueError, 'byte inventory differs'):
            self.exercise(refusal='bytes')

    def test_changed_revision_refused(self):
        with self.assertRaisesRegex(ValueError, 'revision drift'):
            self.exercise(refusal='revision')

    def test_changed_executable_mode_refused(self):
        with self.assertRaisesRegex(ValueError, 'executable mode differs'):
            self.exercise(refusal='executable')

    def test_missing_source_file_refused(self):
        with self.assertRaisesRegex(ValueError, 'Tracked regular helper source missing'):
            self.exercise(refusal='missing-file')

    def test_empty_environment_missing_git_retains_failed_receipt(self):
        with self.assertRaisesRegex(FileNotFoundError, 'OWN_MISSING_GIT'):
            self.exercise(refusal='missing-tool')
        result = json.loads((self.root / 'legendary/reports/RESULT.json').read_text())
        self.assertEqual(result['first_failure']['phase'], 'legendary-git-init')


if __name__ == '__main__':
    unittest.main()

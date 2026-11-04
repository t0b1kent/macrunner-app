import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import swift_test_report as reporter

class ReportDataRoot(unittest.TestCase):
    def test_fixture_data_is_kept_outside_the_archived_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            tree = root / 'app'; tree.mkdir()
            reports = root / 'reports'
            captured = []
            def run(command, tree, environment, log, label):
                captured.append(Path(environment['MACRUNNER_APP_DATA_ROOT']))
                return 0, 'Test run with 1 tests passed\n', 0.01
            with mock.patch.object(reporter, 'read_policy', return_value={'allow': []}), \
                 mock.patch.object(reporter, 'ensure_layout', return_value=[]), \
                 mock.patch.object(reporter, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                rc = reporter.main(['--tree', str(tree), '--reports', str(reports), '--', 'swift', 'test'])
            self.assertEqual(rc, 0)
            self.assertEqual(captured, [root / 'app-test-data'])
            self.assertTrue(captured[0].is_dir())
            self.assertNotIn(reports, captured[0].parents)

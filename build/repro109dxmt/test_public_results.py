"""Explicit publication destination controls; no network or product execution."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'repro109'))
import live_results
import private_curl


class PublicResultsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.live = live_results.LiveResults(self.root / 'reports', self.root, 'github')

    def test_missing_destination_refuses_before_process(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.object(live_results.subprocess, 'Popen') as process:
            with self.assertRaisesRegex(ValueError, 'RESULTS_REMOTE is required'):
                self.live._publish_once(self.root)
        process.assert_not_called()
        self.assertFalse((self.root / 'reports/checkpoint-publish.log').exists())

    def test_credentials_or_other_hosts_refuse_before_process(self):
        bad = ['https://example.invalid/owner/repo',
               'https://token@github.com/owner/repo',
               'https://github.com/owner/repo?token=inert',
               'https://github.com/owner/repo#inert',
               'https://github.com/owner/repo extra']
        for index, remote in enumerate(bad):
            with self.subTest(case=index), \
                 mock.patch.dict(os.environ, {'RESULTS_REMOTE': remote}, clear=True), \
                 mock.patch.object(live_results.subprocess, 'Popen') as process:
                with self.assertRaises(ValueError):
                    self.live._publish_once(self.root)
                process.assert_not_called()

    def test_explicit_repository_keeps_owned_process_and_deadline(self):
        child = mock.Mock()
        child.wait.return_value = 0
        with mock.patch.dict(os.environ, {'RESULTS_REMOTE': 'https://github.com/owner/repo.git'}, clear=True), \
             mock.patch.object(live_results.subprocess, 'Popen', return_value=child) as process:
            self.live._publish_once(self.root)
        args, kwargs = process.call_args
        self.assertEqual(args[0][0], 'bash')
        self.assertTrue(kwargs['start_new_session'])
        self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
        child.wait.assert_called_once_with(timeout=live_results.PUBLISH_SECONDS)

    def test_github_local_receipt_needs_no_publication_destination(self):
        with mock.patch.dict(os.environ, {}, clear=True), \
             mock.patch.object(live_results.subprocess, 'Popen') as process:
            self.live.record('PRECHECK', 'OWN_INERT_FIXTURE')
        process.assert_not_called()
        self.assertTrue((self.root / 'reports/PROGRESS.json').exists())

    def test_private_api_requires_explicit_safe_repository(self):
        cases = ['', 'https://example.invalid/owner/repo',
                 'https://token@github.com/owner/repo',
                 'https://github.com/owner/repo?inert']
        for index, remote in enumerate(cases):
            with self.subTest(case=index), \
                 mock.patch.dict(os.environ, {'RESULTS_REMOTE': remote,
                                              'GITHUB_TOKEN': 'OWN_INERT_TOKEN'}, clear=True), \
                 mock.patch.object(private_curl.subprocess, 'run') as process:
                with self.assertRaises(ValueError):
                    private_curl.transfer(1, self.root / 'asset', 1024)
                with self.assertRaises(ValueError):
                    private_curl.metadata_transfer('/releases', self.root / 'metadata', 1024)
                process.assert_not_called()

    def test_private_api_derives_destination_without_default(self):
        with mock.patch.dict(os.environ, {'RESULTS_REMOTE': 'https://github.com/owner/repo.git'}, clear=True):
            self.assertEqual(private_curl.private_api(), 'https://api.github.com/repos/owner/repo')

    def test_public_source_transport_never_uses_token_or_private_destination(self):
        with mock.patch.dict(os.environ, {'GITHUB_TOKEN': 'OWN_INERT_TOKEN'}, clear=True), \
             mock.patch.object(private_curl, '_transfer', return_value={'status': 'OWN_INERT'}) as transfer:
            private_curl.source_transfer('https://github.com/owner/repo/archive/pin.tar.gz',
                                         self.root / 'source', 1024)
        self.assertIsNone(transfer.call_args.args[4])


if __name__ == '__main__':
    unittest.main()

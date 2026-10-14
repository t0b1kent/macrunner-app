"""Offline controls for the unit test policy of the application recipe (a fake `swift` replaces the real one)."""
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import textwrap
import unittest

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import swift_test_report as report

FAKE = textwrap.dedent('''\
    #!/usr/bin/env python3
    import sys
    args = sys.argv[1:]
    recheck = '--filter' in args
    first = {"flaky": "fail", "env": "fail", "red": "fail", "fine": "pass"}
    second = {"flaky": "pass", "env": "fail", "red": "fail"}
    scenario = open(args[args.index('--scenario') + 1]).read().strip() if '--scenario' in args else 'mixed'
    names = ["flaky", "env", "red", "fine"] if not recheck else ["flaky", "env", "red"]
    table = second if recheck else first
    if scenario == 'no-red':
        names = [n for n in names if n != "red"]
    bad = 0
    for n in names:
        if table[n] == "fail":
            bad += 1
            print("\\x1b[31m✘ Test %s() recorded an issue at %sTests.swift:7:9: Expectation failed: x\\x1b[0m" % (n, n))
            print("✘ Test %s() failed after 0.1 seconds with 1 issue." % n)
        else:
            print("✔ Test %s() passed after 0.1 seconds." % n)
    print("%s Test run with %d tests in 3 suites %s after 0.5 seconds%s." % ("✘" if bad else "✔", len(names), "failed" if bad else "passed", " with %d issues" % bad if bad else ""))
    sys.exit(1 if bad else 0)
''')


class Parse(unittest.TestCase):
    def test_names_issues_summary_and_passed_are_read_ignoring_colour_and_arguments(self):
        text = ("\x1b[31m✘ Test decodeDoctor() recorded an issue at JSONDecodeTests.swift:36:6: Caught error: x\x1b[0m\n"
                "✘ Test decodeDoctor() failed after 0.1 seconds with 1 issue.\n"
                "✘ Test clone(profile:) recorded an issue with 1 argument profile → \"a\" at T.swift:3:6: Caught error: .invalid\n"
                "✘ Test clone(profile:) with 2 test cases failed after 0.1 seconds with 2 issues.\n"
                "✔ Test fine() passed after 0.1 seconds.\n"
                "✘ Test runAppViewModelOnCompleteCalled() failed after 0.3 seconds with 2 issues.\n"
                "✘ Test run with 456 tests in 68 suites failed after 8.9 seconds with 20 issues.\n")
        failed, issues, summary, passed = report.parse(text)
        self.assertEqual(failed, ['decodeDoctor', 'clone', 'runAppViewModelOnCompleteCalled'])
        self.assertEqual(passed, ['fine'])
        self.assertEqual(summary, dict(tests=456, suites=68, result='failed', issues=20))
        self.assertEqual(issues['decodeDoctor'][0]['at'], 'JSONDecodeTests.swift:36')


class Policy(unittest.TestCase):
    def test_the_lock_names_each_allowance_with_a_reason_and_never_the_localization_tests(self):
        policy = report.read_policy()
        self.assertEqual(sorted(r['test'] for r in policy['allow']),
                         sorted(['pe32ImportDynamicAndProfileUsePackagedRoute', 'checkRealRoot', 'toolIsFound',
                                 'rootRequiresAbsoluteExplicitPathAndRejectsOwnerLibrary']))
        self.assertNotIn('everyLanguageHasExactlyTheEnglishKeys', [r['test'] for r in policy['allow']])
        self.assertIn('LocalizationTests', policy['never_allowed'])
        self.assertEqual([l['path'] for l in policy['layout_links']],
                         ['app/macr-control-center/Fixtures', 'app/macr-control-center/scripts'])

    def test_a_lock_with_an_allowance_without_a_reason_or_a_link_leaving_the_tree_is_refused(self):
        lock = json.loads(report.POLICY.read_bytes())
        with tempfile.TemporaryDirectory() as tmp:
            for change in (lambda d: d['allow'][0].update(reason=''), lambda d: d['allow'].append(dict(d['allow'][0])),
                           lambda d: d['layout_links'][0].update(path='../escape')):
                data = json.loads(json.dumps(lock))
                change(data)
                path = Path(tmp) / 'p.json'
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    report.read_policy(path)

    def test_the_layout_links_resolve_to_the_snapshot_directories_and_are_not_made_twice(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp)
            (tree / 'Fixtures').mkdir()
            (tree / 'scripts').mkdir()
            (tree / 'Fixtures/x.json').write_text('{}')
            made = report.ensure_layout(tree, report.read_policy())
            self.assertEqual(len(made), 2)
            self.assertEqual((tree / 'app/macr-control-center/Fixtures/x.json').read_text(), '{}')
            with self.assertRaises(ValueError):
                report.ensure_layout(tree, report.read_policy())


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tree = self.root / 'tree'
        (self.tree / 'Fixtures').mkdir(parents=True)
        (self.tree / 'scripts').mkdir()
        self.fake = self.root / 'swift'
        self.fake.write_text(FAKE)
        self.fake.chmod(self.fake.stat().st_mode | stat.S_IEXEC)
        self.reports = self.root / 'reports'

    def run_policy(self, scenario, allow_names):
        scenario_file = self.root / 'scenario'
        scenario_file.write_text(scenario)
        policy = json.loads(report.POLICY.read_bytes())
        policy['allow'] = [dict(policy['allow'][0], test=n) for n in allow_names]
        for i, row in enumerate(policy['allow']):
            row['test'] = allow_names[i]
        path = self.root / 'policy.json'
        path.write_text(json.dumps(policy))
        original = report.POLICY
        report.POLICY = path
        real_read = report.read_policy
        try:
            report.read_policy = lambda p=path: real_read(p)
            code = report.main(['--tree', str(self.tree), '--reports', str(self.reports), '--',
                                str(self.fake), 'test', '--scenario', str(scenario_file)])
        finally:
            report.POLICY, report.read_policy = original, real_read
        return code, json.loads((self.reports / 'swift_test_failures.json').read_bytes())

    def test_flaky_passes_on_recheck_allowed_is_named_and_an_unnamed_failure_turns_the_run_red(self):
        code, data = self.run_policy('mixed', ['env'])
        self.assertEqual(code, 1)
        self.assertEqual({k: v['outcome'] for k, v in data['verdict'].items()},
                         {'flaky': 'PASSED_ON_RECHECK', 'env': 'ALLOWANCE', 'red': 'FAILED'})
        self.assertEqual(data['status'], 'SWIFT_TESTS_FAILED')
        self.assertEqual(data['unexplained_failures'], ['red'])
        self.assertEqual(data['verdict']['red']['issues'][0]['at'], 'redTests.swift:7')
        self.assertTrue((self.reports / 'swift_test_full.log').is_file())
        self.assertTrue((self.reports / 'swift_test_recheck.log').is_file())
        self.assertEqual(data['recheck']['filter'], '(^|[./])(flaky|env|red)\\(')

    def test_without_an_unexplained_failure_the_run_is_green_with_its_reasons_recorded(self):
        code, data = self.run_policy('no-red', ['env'])
        self.assertEqual(code, 0)
        self.assertEqual(data['status'], 'SWIFT_TESTS_PASSED_WITH_RECHECK_OR_ALLOWANCE')
        self.assertEqual(data['unexplained_failures'], [])
        self.assertEqual(data['layout_links'], ['app/macr-control-center/Fixtures', 'app/macr-control-center/scripts'])

    def test_a_command_that_is_not_swift_test_is_refused(self):
        with self.assertRaises(ValueError):
            report.main(['--tree', str(self.tree), '--reports', str(self.reports), '--', str(self.fake), 'build'])


if __name__ == '__main__':
    unittest.main(verbosity=2)

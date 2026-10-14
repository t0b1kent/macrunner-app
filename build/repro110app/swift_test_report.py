#!/usr/bin/env python3
"""Run the unit tests of the prepared application tree and judge them by an explicit rule (REPRO-110).

Rule: (1) the layout of the full checkout that some tests assume is provided by symlinks listed in swift-test-policy.lock.json;
(2) the whole output is kept (bounded) and the failed tests are listed by name with their first issues in
swift_test_failures.json, whatever the result; (3) failed tests are run once more alone; (4) a test that still fails must be
named in the lock's allow list with a reason, otherwise the run fails. The exit code is 0 only when every test passed,
possibly on the recheck or by a named allowance.

Usage: swift_test_report.py --tree APP_TREE --reports DIR -- <swift test argv>
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
POLICY = HERE / 'swift-test-policy.lock.json'
ANSI = re.compile(r'\x1b\[[0-9;]*m')
MAX_LOG = 16 * 1024 * 1024
FAILED_TEST = re.compile(r'^✘ Test (.+?) failed after ')
PASSED_TEST = re.compile(r'^✔ Test (.+?) passed after ')
ISSUE = re.compile(r'^✘ Test (\S+?)\(.*?\) recorded an issue(?: with \d+ arguments?.*?)? at ([A-Za-z0-9_.+-]+):(\d+):\d+: (.*)$')
SUMMARY = re.compile(r'^[✔✘] Test run with (\d+) tests? in (\d+) suites? (passed|failed)(?: after [\d.]+ seconds)?(?: with (\d+) issues?)?')


def read_policy(path=POLICY):
    data = json.loads(Path(path).read_bytes())
    if data.get('schema') != 1:
        raise ValueError('Swift test policy differs')
    names = set()
    for row in data['allow']:
        for key in ('test', 'suite', 'reason', 'evidence'):
            if not isinstance(row.get(key), str) or not row[key].strip():
                raise ValueError('Allowance needs a test, a suite, a reason and evidence')
        if row['test'] in names:
            raise ValueError('Duplicate allowance')
        names.add(row['test'])
    for link in data['layout_links']:
        if link['path'].startswith('/') or '..' in Path(link['path']).parts:
            raise ValueError('Unsafe layout link')
    return data


def ensure_layout(tree, policy):
    made = []
    for link in policy['layout_links']:
        path = Path(tree) / link['path']
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink() or path.exists():
            raise ValueError('Layout link path already present: ' + link['path'])
        os.symlink(link['target'], path)
        if not path.resolve().exists():
            raise ValueError('Layout link target missing: ' + link['path'])
        made.append(link['path'])
    return made


def parse(text):
    """Failed and passed test names (function name without arguments), the first issues of the failed, the run summary."""
    lines = [ANSI.sub('', l) for l in text.splitlines()]
    failed, issues, summary, passed = [], {}, None, []
    for line in lines:
        m = PASSED_TEST.match(line)
        if m:
            name = re.split(r'[( ]', m.group(1), 1)[0]
            if name not in passed:
                passed.append(name)
        m = FAILED_TEST.match(line)
        if m and not line.startswith('✘ Test run with '):
            name = re.split(r'[( ]', m.group(1), 1)[0]
            if name not in failed:
                failed.append(name)
        m = ISSUE.match(line)
        if m:
            row = issues.setdefault(m.group(1), [])
            if len(row) < 3:
                row.append(dict(at='%s:%s' % (m.group(2), m.group(3)), message=m.group(4)[:240]))
        m = SUMMARY.match(line)
        if m:
            summary = dict(tests=int(m.group(1)), suites=int(m.group(2)), result=m.group(3), issues=int(m.group(4) or 0))
    return failed, issues, summary, passed


def run(argv, tree, env, log, label):
    started = time.monotonic()
    chunks, size = [], 0
    with open(log, 'wb') as stream:
        child = subprocess.Popen(argv, cwd=tree, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for raw in iter(child.stdout.readline, b''):
            size += len(raw)
            if size <= MAX_LOG:
                stream.write(raw)
                chunks.append(raw)
            sys.stdout.buffer.write(raw)
        child.wait()
    return child.returncode, b''.join(chunks).decode('utf-8', 'replace'), time.monotonic() - started


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tree', type=Path, required=True)
    parser.add_argument('--reports', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or command[1:2] != ['test']:
        raise ValueError('A swift test command is required')
    policy = read_policy()
    args.reports.mkdir(parents=True, exist_ok=True)
    result = dict(schema=1, policy='LAYOUT_LINKS_RECHECK_ONCE_NAMED_ALLOWANCES', layout_links=ensure_layout(args.tree, policy))
    env = dict(os.environ)
    rc, text, seconds = run(command, args.tree, env, args.reports / 'swift_test_full.log', 'first')
    failed, issues, summary, _ = parse(text)
    result.update(first_run=dict(rc=rc, seconds=round(seconds, 1), summary=summary), failed_first=failed)
    verdict = {}
    if rc and failed:
        regex = '(^|[./])(' + '|'.join(re.escape(n) for n in failed) + r')\('
        rc2, text2, seconds2 = run(command + ['--filter', regex], args.tree, env, args.reports / 'swift_test_recheck.log', 'recheck')
        failed2, issues2, summary2, passed2 = parse(text2)
        result.update(recheck=dict(rc=rc2, seconds=round(seconds2, 1), summary=summary2, filter=regex), failed_after_recheck=failed2)
        issues = dict(issues, **issues2)
        allowed = {row['test']: row for row in policy['allow']}
        for name in failed:
            if name in passed2 and name not in failed2:
                verdict[name] = dict(outcome='PASSED_ON_RECHECK')
            elif name in allowed:
                verdict[name] = dict(outcome='ALLOWANCE', suite=allowed[name]['suite'], reason=allowed[name]['reason'])
            else:
                verdict[name] = dict(outcome='FAILED')
    elif rc:
        verdict['(no failed test identified)'] = dict(outcome='FAILED')
    for name, row in verdict.items():
        row['issues'] = issues.get(name, [])
    result.update(verdict=verdict)
    bad = [n for n, v in verdict.items() if v['outcome'] == 'FAILED']
    result['status'] = ('SWIFT_TESTS_PASSED' if not rc else 'SWIFT_TESTS_PASSED_WITH_RECHECK_OR_ALLOWANCE' if not bad else 'SWIFT_TESTS_FAILED')
    result['unexplained_failures'] = bad
    (args.reports / 'swift_test_failures.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps({k: result[k] for k in ('status', 'unexplained_failures')}))
    return 1 if bad else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError) as exc:
        print('REFUSED: ' + str(exc), file=sys.stderr)
        sys.exit(2)

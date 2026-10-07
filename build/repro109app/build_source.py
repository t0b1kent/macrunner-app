#!/usr/bin/env python3
"""Same Xcode Cloud task: pinned frameworks -> prepared app -> Swift products/tests.

Stage a partial .app from captured products; no engine, helpers, release signing or launch.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import time
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
PRODUCTS = ('MacRunnerControlCenter', 'macr-hud')
RESOURCE = 'MacRunnerControlCenter_MacRunnerControlCenter.bundle'
MAX_PRODUCT_BYTES = 2 * 1024**3


def package_module():
    return module('app_source_packaging', HERE / 'package_source.py')


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def plan():
    prepare = module('compile_prepare', HERE / 'prepare_source.py')
    lock = json.loads((HERE / 'source.lock.json').read_text())
    prepare.framework_module(lock)
    return dict(status='PLANNED_NOT_BUILT', source=prepare.verify_source(HERE / 'source', lock),
                products=list(PRODUCTS), resource=RESOURCE, minutes=95, framework_minutes=70,
                profiles=['github', 'xcode-cloud'], signing='NOT_ENABLED', whole_bundle='NOT_ENABLED',
                runtime_inputs=lock['incomplete_runtime_inputs'])


def swift_argv(swift, action, work, jobs):
    return [swift, action, '-c', 'release', '--arch', 'arm64', '--jobs', str(jobs),
            '--scratch-path', str(work / 'swift-build'), '--disable-automatic-resolution']


def selected_bin_path(text, work):
    lines = text.strip().splitlines()
    if len(lines) != 1 or not Path(lines[0]).is_absolute():
        raise ValueError('Swift bin path is not one absolute path')
    path = Path(lines[0])
    if path.is_symlink() or not path.resolve().is_relative_to((work / 'swift-build').resolve()):
        raise ValueError('Swift bin path leaves owned scratch')
    if not path.is_dir():
        raise ValueError('Swift product directory NOT_PRESENT')
    return path


def test_count(text):
    counts = re.findall(r'Test run with (\d+) tests(?: in \d+ suites)? passed', text)
    if len(counts) != 1 or int(counts[0]) < 1:
        raise ValueError('Swift Testing nonzero passed-test count NOT_PRESENT')
    return int(counts[0])


def capture_products(bin_path, framework_work, prefix, runner, output):
    binaries = []
    prefix.mkdir()
    products = prefix / 'products'
    products.mkdir()
    for name in PRODUCTS:
        source = bin_path / name
        if source.is_symlink() or not source.is_file() or not os.access(source, os.X_OK):
            raise ValueError('Swift executable NOT_PRESENT: ' + name)
        with source.open('rb') as stream:
            magic = stream.read(4)
        if magic not in {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf'}:
            raise ValueError('Swift product is not a thin Mach-O: ' + name)
        if output(['/usr/bin/lipo', '-archs', str(source)], 'arch-' + name).strip() != 'arm64':
            raise ValueError('Swift product architecture differs: ' + name)
        shutil.copy2(source, products / name)
        binaries.append(dict(name=name, sha256=runner.file_sha(source), bytes=source.stat().st_size,
                             architecture='arm64'))
    resource = bin_path / RESOURCE
    if resource.is_symlink() or not resource.is_dir():
        raise ValueError('Swift resource bundle NOT_PRESENT')
    # Validate every resource link before copying it or accepting its byte inventory.
    runner.inventory(resource)
    shutil.copytree(resource, products / RESOURCE, symlinks=True)
    framework_lock = json.loads((HERE / 'frameworks.lock.json').read_text())
    frameworks = prefix / 'Frameworks'
    frameworks.mkdir()
    for row in framework_lock['components']:
        source = framework_work / 'prefix' / row['product']
        shutil.copytree(source, frameworks / row['product'], symlinks=True)
    shutil.copytree(framework_work / 'prefix/licenses', prefix / 'licenses', symlinks=True)
    inventory = runner.inventory(prefix)
    if sum(row['bytes'] for row in inventory) > MAX_PRODUCT_BYTES:
        raise ValueError('App product output exceeds 2 GiB')
    return binaries, inventory


def build(args):
    profile = module('app_cloud_profile', HERE / 'build_app_frameworks.py').cloud_profile()
    if args.work.exists() or args.work.is_symlink():
        raise ValueError('Fresh compile workspace required')
    work, published = args.work.resolve(), args.publish_dir.resolve()
    for source in [REPO.resolve(), published]:
        if work.is_relative_to(source) or source.is_relative_to(work):
            raise ValueError('Compile workspace overlaps source or results')
    prepared = module('compile_prepare', HERE / 'prepare_source.py')
    lock = json.loads((HERE / 'source.lock.json').read_text())
    framework = prepared.framework_module(lock)
    source = prepared.verify_source(HERE / 'source', lock)
    runner = framework.load_runner()
    env = framework.build_env()
    env['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
    # Prevent test fixtures from selecting an inherited live runtime.
    for name in list(env):
        if name.startswith(('MACRUNNER_', 'WINE', 'DYLD_')):
            env.pop(name)
    work.mkdir(parents=True)
    reports = work / 'reports'
    reports.mkdir()
    published.mkdir(parents=True, exist_ok=True)
    live = framework.LiveResults(reports, REPO, profile, publish_dir=published,
                                 job='repro109-app-source',
                                 publication_mode='github-artifact' if profile == 'github' else 'remote')
    result = dict(schema=1, status='STARTED', classification='DIAGNOSTIC_ONLY_NOT_GOLDEN', profile=profile,
                  source=source, driver_sha256=prepared.sha(__file__),
                  source_lock_sha256=prepared.sha(HERE / 'source.lock.json'),
                  framework_recipe=lock['frameworks_recipe'], first_failure=None,
                  phases=[], products=[], install_skipped=0, signing='NOT_ENABLED',
                  runtime_inputs={name: 'NOT_ENABLED' for name in lock['incomplete_runtime_inputs']},
                  whole_bundle='NOT_ENABLED', comparison='NOT_ENABLED', stands='NOT_ENABLED',
                  ARM64EC='NOT_APPLICABLE_NATIVE_APP_PRODUCTS')
    deadline = time.monotonic() + args.minutes * 60
    phase = 'PRECHECK'
    def persist():
        logs = list(reports.glob('*.log')) + list((work / 'frameworks/reports').glob('*.log'))
        result['install_skipped'] = sum(p.read_bytes().lower().count(b'install skipped') for p in logs)
        result['logs'] = [dict(path=p.relative_to(work).as_posix(), bytes=p.stat().st_size,
                               sha256=runner.file_sha(p)) for p in logs]
        framework.write_json(reports / 'APP-RESULT.json', result)
        framework.write_json(published / 'APP-RESULT.json', result)
    def checkpoint(state):
        persist()
        live.record(phase, state, status=result['status'], failure=result['first_failure'])
    def command(argv, label, timeout=1200, cwd=None):
        if time.monotonic() >= deadline:
            raise ValueError('App total time budget exhausted before ' + label)
        log = reports / (label + '.log')
        runner.command(argv, cwd or work, env, log, reports, label, deadline, timeout=timeout)
        return log
    def output(argv, label, cwd=None):
        return command(argv, label, timeout=120, cwd=cwd).read_text()
    try:
        checkpoint('JOB_STARTED')
        phase = 'FRAMEWORKS'
        checkpoint('START')
        framework_args = SimpleNamespace(work=work / 'frameworks', publish_dir=published / 'frameworks',
                                         jobs=args.jobs, minutes=min(70, args.minutes - 25))
        rc = framework.build(framework_args, framework.read_lock())
        result['framework_rc'] = rc
        if rc:
            receipt = json.loads((framework_args.work / 'reports/RESULT.json').read_text())
            result['framework_first_failure'] = receipt.get('first_failure')
            raise ValueError('Source framework build FAILED')
        phase = 'PREPARE'
        checkpoint('START')
        app_work = work / 'source-app'
        preparation = prepared.prepare(HERE / 'source', app_work, framework_args.work, lock)
        result['prepared_sha256'] = prepared.sha(app_work / 'PREPARED.json')
        result['frameworks'] = preparation['frameworks']
        swift = output(['/usr/bin/xcrun', '--find', 'swift'], 'swift-path').strip()
        if not Path(swift).is_absolute() or not Path(swift).is_file():
            raise ValueError('Selected Swift compiler NOT_PRESENT')
        version = output([swift, '--version'], 'swift-version')
        if not re.search(r'Apple Swift version 6\.', version):
            raise ValueError('Expected Xcode Apple Swift 6.x')
        result['swift'] = dict(path=swift, sha256=runner.file_sha(Path(swift)), version=version.strip())
        for phase, action in [('SWIFT_BUILD', 'build'), ('SWIFT_TEST', 'test')]:
            result['phases'].append(dict(name=phase, status='STARTED'))
            checkpoint('START')
            log = command(swift_argv(swift, action, app_work, args.jobs), phase.lower(), cwd=app_work / 'app')
            if action == 'test':
                result['swift_tests_passed'] = test_count(log.read_text())
            result['phases'][-1]['status'] = 'PASSED'
            checkpoint('PASSED')
        phase = 'PRODUCTS'
        checkpoint('START')
        selected = output(swift_argv(swift, 'build', app_work, args.jobs) + ['--show-bin-path'],
                          'bin-path', cwd=app_work / 'app')
        bin_path = selected_bin_path(selected, app_work)
        result['products'], result['prefix_inventory'] = capture_products(
            bin_path, framework_args.work, work / 'prefix', runner, output)
        phase = 'PACKAGE_APP'
        checkpoint('START')
        packager = package_module()
        result['app_bundle'] = packager.package(
            work / 'prefix', app_work / 'app/scripts/assets/AppIcon.icns', framework.read_lock(),
            runner.inventory, command, output)
        result['prefix_inventory'] = runner.inventory(work / 'prefix')
        if sum(row['bytes'] for row in result['prefix_inventory']) > MAX_PRODUCT_BYTES:
            raise ValueError('Packaged app output exceeds 2 GiB')
        checkpoint('PASSED')
        # Preparation transformations must not mutate the locked source snapshot.
        if prepared.verify_source(HERE / 'source', lock) != source:
            raise ValueError('Source snapshot changed during compilation')
        result['status'] = 'APP_SOURCE_COMPILED_TESTED_NOT_WHOLE_BUNDLE'
        phase = 'FINAL'
        checkpoint('PASSED')
    except Exception as exc:
        result['status'] = 'FAILED'
        result['first_failure'] = dict(phase=phase, error=str(exc))
        if result['phases'] and result['phases'][-1]['status'] == 'STARTED':
            result['phases'][-1]['status'] = 'FAILED'
        try:
            checkpoint('FAILED')
        except Exception as publication:
            result['publication_failure'] = str(publication)
    finally:
        persist()
    return 0 if result['status'] == 'APP_SOURCE_COMPILED_TESTED_NOT_WHOLE_BUNDLE' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--plan', action='store_true')
    actions.add_argument('--build', action='store_true')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--publish-dir', type=Path)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--minutes', type=int, default=95)
    args = parser.parse_args()
    if args.plan:
        print(json.dumps(plan(), ensure_ascii=False, sort_keys=True))
        return 0
    if not args.work or not args.publish_dir or not 1 <= args.jobs <= 8 or not 30 <= args.minutes <= 100:
        parser.error('Fresh work/results and jobs1..8/minutes30..100 required')
    return build(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print('REFUSED: ' + str(exc), file=sys.stderr)
        sys.exit(2)

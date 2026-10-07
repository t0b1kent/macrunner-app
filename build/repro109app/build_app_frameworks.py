#!/usr/bin/env python3
"""Pinned Git sources -> unsigned native frameworks and SwiftPM xcframeworks.

--plan and offline tests do not download or execute third-party sources.
Only --build on the curator's existing Xcode Cloud surface does so.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(REPO / 'repro109dxmt'))
from live_results import LiveResults

OFFICIAL = {
    'sparkle': 'https://github.com/sparkle-project/Sparkle.git',
    'plcrashreporter': 'https://github.com/microsoft/plcrashreporter.git',
}
MAGIC = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}


class CheckpointFailure(RuntimeError):
    pass


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def read_lock(path=HERE / 'frameworks.lock.json'):
    lock = json.loads(Path(path).read_bytes())
    if lock['schema'] != 1 or lock['architecture'] != 'arm64' or lock['deployment_target'] != '14.0':
        raise ValueError('Framework profile differs')
    rows = lock['components']
    if not isinstance(rows, list) or [r['name'] for r in rows] != list(OFFICIAL):
        raise ValueError('Framework component list differs')
    for row in rows:
        if row['url'] != OFFICIAL[row['name']] or not re.fullmatch('[0-9a-f]{40}', row['revision']):
            raise ValueError('Official Git source fingerprint missing/differs')
        for key in ['project', 'product', 'target']:
            if not re.fullmatch('[A-Za-z0-9_.-]+', row[key]):
                raise ValueError('Unsafe Xcode input')
        for name in row['required_binaries'] + row['license_candidates']:
            if Path(name).is_absolute() or '..' in Path(name).parts:
                raise ValueError('Unsafe framework path')
    return lock


def load_runner():
    path = REPO / 'repro109deps/build_deps.py'
    spec = importlib.util.spec_from_file_location('framework_deps_runner', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_env():
    env = os.environ.copy()
    for name in list(env):
        if name.startswith(('GIT_TRACE', 'GIT_CONFIG_')) or name in ['GIT_CURL_VERBOSE', 'GH_DEBUG']:
            env.pop(name)
    env.update(GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/usr/bin/false',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
    # Public source transport never receives private result credentials.
    for name in ['GH_TOKEN', 'GITHUB_TOKEN', 'RESULTS_TOKEN']:
        env.pop(name, None)
    return env


def validate_git(row, head, object_type, origin, status, staged):
    if head.strip() != row['revision'] or object_type.strip() != 'commit' or origin.strip() != row['url']:
        raise ValueError('Selected Git commit/type/origin differs')
    if status.strip():
        raise ValueError('Source checkout is dirty')
    gitlinks = [line for line in staged.splitlines() if line.startswith('160000 ')]
    if gitlinks:
        raise ValueError('Submodule source closure NOT_ENABLED: ' + str(len(gitlinks)) + ' gitlinks')


def source_settings(raw, source, products, row):
    data = json.loads(raw)
    if not isinstance(data, list) or not data:
        raise ValueError('Xcode build settings EMPTY')
    selected = []
    for entry in data:
        if not isinstance(entry, dict):
            raise ValueError('Xcode build settings entry type differs')
        settings = entry.get('buildSettings')
        if not isinstance(settings, dict):
            raise ValueError('Xcode build settings type differs')
        for key in ['SRCROOT', 'PROJECT_DIR']:
            if Path(settings.get(key, '')).resolve() != source.resolve():
                raise ValueError('Foreign Xcode ' + key)
        if Path(settings.get('BUILT_PRODUCTS_DIR', '')).resolve() != products.resolve():
            raise ValueError('Foreign Xcode product directory')
        if settings.get('CODE_SIGNING_ALLOWED') != 'NO':
            raise ValueError('Xcode signing is enabled')
        if settings.get('ARCHS', '').split() != ['arm64']:
            raise ValueError('Xcode architecture differs')
        if entry.get('target') == row['target']:
            if settings.get('FULL_PRODUCT_NAME') != row['product'] or settings.get('MACH_O_TYPE') != 'mh_dylib':
                raise ValueError('Framework product/type differs')
            selected.append(entry['target'])
    if selected != [row['target']]:
        raise ValueError('Xcode target missing/ambiguous')
    return dict(status='PRESENT', targets=len(data), selected=selected,
                srcroot=str(source), products=str(products))


def product_paths(framework, row):
    if not framework.is_dir() or framework.is_symlink():
        raise ValueError('Framework output missing/symlink')
    root = framework.resolve()
    for p in framework.rglob('*'):
        if p.is_symlink() and (not p.exists() or root not in p.resolve().parents):
            raise ValueError('Framework symlink escapes/dangles')
    binaries = []
    for name in row['required_binaries']:
        p = framework / name
        if not p.is_file() or root not in p.resolve().parents:
            raise ValueError('Required framework binary missing/foreign: ' + name)
        with p.open('rb') as stream:
            if stream.read(4) not in MAGIC:
                raise ValueError('Framework binary is not Mach-O: ' + name)
        binaries.append(p)
    actual = []
    for p in framework.rglob('*'):
        if p.is_file() and not p.is_symlink():
            with p.open('rb') as stream:
                if stream.read(4) in MAGIC:
                    actual.append(p.relative_to(framework).as_posix())
    if sorted(actual) != sorted(row['required_binaries']):
        raise ValueError('Framework compiled input census differs')
    info = next((p for p in framework.glob('Versions/*/Resources/Info.plist') if p.is_file()), None)
    if info is None or plistlib.loads(info.read_bytes()).get('CFBundleShortVersionString') != row['version']:
        raise ValueError('Framework product version differs')
    return binaries


def validate_architectures(value):
    if value.strip().split() != ['arm64']:
        raise ValueError('Framework Mach-O architecture differs')


def xcode_args(source, build, row, jobs):
    return ['xcodebuild', '-project', str(source / row['project']), '-target', row['target'],
            '-configuration', 'Release', '-sdk', 'macosx', '-jobs', str(jobs),
            'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'MACOSX_DEPLOYMENT_TARGET=14.0',
            'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=',
            'SYMROOT=' + str(build / 'products'), 'OBJROOT=' + str(build / 'objects')]


def selected_components(lock, only=''):
    if only and only not in {row['name'] for row in lock['components']}:
        raise ValueError('Unknown framework selection')
    return [row for row in lock['components'] if not only or row['name'] == only]


def cloud_profile():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('Cloud source work requires Darwin ARM64')
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        return 'github'
    if os.environ.get('CI_XCODE_CLOUD') == 'TRUE':
        return 'xcode-cloud'
    raise ValueError('Cloud source work requires GitHub Actions or Xcode Cloud')


def build(args, lock):
    profile = cloud_profile()
    selected = selected_components(lock, getattr(args, 'only', ''))
    if args.work.exists() or args.work.is_symlink():
        raise ValueError('Fresh framework workspace required')
    args.work.mkdir(parents=True)
    reports = args.work / 'reports'
    reports.mkdir()
    runner = load_runner()
    env = build_env()
    live = LiveResults(reports, REPO, profile, publish_dir=args.publish_dir,
                       job='repro109-app-frameworks')
    result = dict(schema=1, status='STARTED', classification=lock['classification'], profile=profile,
                  selection=[row['name'] for row in selected],
                  lock_sha256=sha(HERE / 'frameworks.lock.json'), driver_sha256=sha(__file__),
                  components=[], first_failure=None, install_skipped=0,
                  comparison='NOT_ENABLED', app_build='NOT_ENABLED', ARM64EC='NOT_APPLICABLE_NATIVE_ARM64')
    deadline = time.monotonic() + args.minutes * 60
    def command(argv, cwd, label, timeout=1800):
        log = reports / (label + '.log')
        runner.command(argv, cwd, env, log, reports, label, deadline, timeout=timeout)
        return log
    def output(argv, cwd, label):
        return command(argv, cwd, label, 120).read_text()
    def checkpoint(*words, **fields):
        try:
            return live.record(*words, **fields)
        except Exception as exc:
            raise CheckpointFailure('Durable publication failed: ' + str(exc)) from exc
    try:
        checkpoint('PRECHECK', 'JOB_STARTED')
        tool = copy.deepcopy(lock['toolchain'])
        runner.toolchain_preflight(tool, reports)
        result['toolchain'] = tool
        prefix = args.work / 'prefix'
        prefix.mkdir()
        for row in selected:
            name = row['name']
            item = dict(name=name, status='STARTED', revision=row['revision'], version=row['version'])
            result['components'].append(item)
            if time.monotonic() >= deadline:
                item.update(status='NOT_ENABLED', reason='BUDGET_EXHAUSTED')
                checkpoint(name, 'NOT_ENABLED', status='NOT_ENABLED', failure='BUDGET_EXHAUSTED')
                write_json(reports / 'RESULT.json', result)
                continue
            try:
                checkpoint(name, 'SOURCE_START')
                source = args.work / (name + '-source')
                source.mkdir()
                git = ['/usr/bin/git', '-c', 'credential.helper=', '-c', 'protocol.file.allow=never',
                       '-c', 'http.followRedirects=false', '-C', str(source)]
                for suffix, words in [('init', ['init']), ('remote', ['remote', 'add', 'origin', row['url']]),
                                      ('fetch', ['fetch', '--depth=1', '--no-tags', 'origin', row['revision']]),
                                      ('checkout', ['checkout', '--detach', 'FETCH_HEAD'])]:
                    command(git + words, source, name + '-' + suffix, 600)
                head = output(git + ['rev-parse', 'HEAD'], source, name + '-head')
                kind = output(git + ['cat-file', '-t', 'HEAD'], source, name + '-type')
                origin = output(git + ['remote', 'get-url', 'origin'], source, name + '-origin')
                state = output(git + ['status', '--porcelain'], source, name + '-status')
                staged = output(git + ['ls-files', '--stage'], source, name + '-tree')
                validate_git(row, head, kind, origin, state, staged)
                command(git + ['fsck', '--strict', '--no-reflogs'], source, name + '-fsck', 120)
                item['tree'] = output(git + ['rev-parse', 'HEAD^{tree}'], source, name + '-tree-id').strip()
                archive = args.work / (name + '-source.tar')
                command(git + ['archive', '--format=tar', '--output=' + str(archive), 'HEAD'],
                        source, name + '-archive', 120)
                item['source_archive'] = dict(sha256=sha(archive), bytes=archive.stat().st_size)
                write_json(reports / (name + '-source-manifest.json'), item)
                build_dir = args.work / (name + '-build')
                argv = xcode_args(source, build_dir, row, args.jobs)
                settings = output(argv + ['-showBuildSettings', '-json'], source, name + '-settings')
                own = source_settings(settings, source, build_dir / 'products/Release', row)
                write_json(reports / (name + '-source-ownership.json'), own)
                checkpoint(name, 'BUILD_START')
                command(argv + ['build'], source, name + '-build')
                product = build_dir / 'products/Release' / row['product']
                binaries = product_paths(product, row)
                item['binaries'] = []
                for number, p in enumerate(binaries):
                    arch = output(['/usr/bin/lipo', '-archs', str(p)], source, name + '-arch-' + str(number))
                    validate_architectures(arch)
                    command(['/usr/bin/otool', '-L', str(p)], source, name + '-links-' + str(number), 120)
                    item['binaries'].append(dict(path=p.relative_to(product).as_posix(), sha256=sha(p),
                                                 bytes=p.stat().st_size, architecture='arm64'))
                # Input changes are evidence of an unrecorded generation path, never silently accepted.
                after = output(git + ['status', '--porcelain'], source, name + '-post-status')
                if after.strip():
                    raise ValueError('Framework source changed during build; inspect raw post-status')
                destination = prefix / row['product']
                shutil.copytree(product, destination, symlinks=True)
                xc = prefix / (row['target'] + '.xcframework')
                command(['xcodebuild', '-create-xcframework', '-framework', str(destination),
                         '-output', str(xc)], source, name + '-xcframework', 120)
                xcinfo = plistlib.loads((xc / 'Info.plist').read_bytes())
                slices = xcinfo.get('AvailableLibraries')
                if not isinstance(slices, list) or len(slices) != 1 or slices[0].get('SupportedPlatform') != 'macos':
                    raise ValueError('XCFramework slice census differs')
                validate_architectures(' '.join(slices[0].get('SupportedArchitectures', [])))
                restored = xc / slices[0]['LibraryIdentifier'] / slices[0]['LibraryPath']
                copied = product_paths(restored, row)
                if [sha(p) for p in copied] != [sha(p) for p in binaries]:
                    raise ValueError('XCFramework binary transport differs')
                license_paths = [source / p for p in row['license_candidates'] if (source / p).is_file()]
                if not license_paths:
                    raise ValueError('Framework root license NOT_PRESENT')
                license_dir = prefix / 'licenses' / name
                license_dir.mkdir(parents=True)
                for p in license_paths:
                    shutil.copy2(p, license_dir / p.name)
                # Preserve nested dependency licenses, not only the top-level framework license.
                command(git + ['archive', '--format=tar', '--output=' + str(prefix / (name + '-source.tar')),
                               'HEAD'], source, name + '-retained-source', 120)
                item.update(status='BUILT', compiled_paths=len(binaries),
                            license_files=[p.name for p in license_paths], xcframework=str(xc.name))
                checkpoint(name, 'BUILT')
            except CheckpointFailure:
                raise
            except Exception as exc:
                item.update(status='FAILED', failure=str(exc))
                if result['first_failure'] is None:
                    result['first_failure'] = dict(component=name, error=str(exc))
                checkpoint(name, 'FAILED', status='FAILED', failure=str(exc))
            write_json(reports / 'RESULT.json', result)
        result['status'] = 'FRAMEWORKS_SOURCE_BUILT_NOT_R2_COMPARED' if all(
            item['status'] == 'BUILT' for item in result['components']) else 'FAILED'
        result['prefix_inventory'] = runner.inventory(prefix)
        checkpoint('FINAL', result['status'], status=result['status'], failure=result['first_failure'])
    except Exception as exc:
        result['status'] = 'FAILED'
        if isinstance(exc, CheckpointFailure):
            result['publication_failure'] = str(exc)
        if result['first_failure'] is None:
            result['first_failure'] = dict(component='preflight-or-publication', error=str(exc))
    finally:
        result['install_skipped'] = sum(p.read_bytes().lower().count(b'install skipped')
                                        for p in reports.glob('*.log'))
        write_json(reports / 'RESULT.json', result)
    return 0 if result['status'] == 'FRAMEWORKS_SOURCE_BUILT_NOT_R2_COMPARED' else 1


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--plan', action='store_true')
    mode.add_argument('--build', action='store_true')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--publish-dir', type=Path)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--minutes', type=int, default=90)
    parser.add_argument('--only', choices=['sparkle', 'plcrashreporter'], default='')
    args = parser.parse_args()
    lock = read_lock()
    if args.plan:
        print(json.dumps(dict(status='PLANNED_NOT_BUILT', lock=lock,
                              source_download='NOT_ENABLED', install='skipped'), indent=2))
        return 0
    if not args.work or not args.publish_dir or not (1 <= args.jobs <= 8 and 1 <= args.minutes <= 95):
        parser.error('Fresh work and durable publish-dir required; jobs1..8/minutes1..95')
    args.work = args.work.resolve()
    args.publish_dir = args.publish_dir.resolve()
    return build(args, lock)


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Native source-build stage for the forthcoming unified Python-helper job.

No acquisition or vendor execution on the owner's Mac. This module does not
resolve PEP517 requirements and does not claim that either helper is built.
"""
import copy
import functools
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import build_frameworks as framework
sys.path.insert(0, str(REPO / 'repro109'))
import private_curl
import public_archive

PYTHON_SHA = '9c22bfe9939a6c5418fc74b289a5f1cc41859ae82ac6b163016b5844bd0a86bc'
OPENSSL_SHA = '9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef'


def profile():
    selected = os.environ.get('REPRO109_HELPER_PROFILE', 'xcode-cloud')
    if selected not in ('xcode-cloud', 'github-macos15-arm64'):
        raise ValueError('Unknown helper build profile')
    return selected


def github_toolchain():
    tool = json.loads((HERE / 'python-helpers.github.lock.json').read_text())
    if (tool['schema'], tool['profile'], tool['runner_label'], tool['xcode'],
            tool['xcode_build'], tool['sdk'], tool['deployment_target'],
            tool['bootstrap_python'], tool['apple_clang']) != (
            1, 'github-macos15-arm64', 'macos-15', '16.4', '16F6', '15.5', '14.0',
            '3.14.7', 'Apple clang version 17.0.0'):
        raise ValueError('GitHub ARM64 toolchain pin drift')
    return tool


def inputs():
    candidate = json.loads((HERE / 'python-helpers.candidate.lock.json').read_text())
    deps = json.loads((REPO / 'repro109deps/deps.lock.json').read_text())
    python = copy.deepcopy(candidate['target_python'])
    openssl_rows = [row for row in deps['components'] if row['name'] == 'openssl']
    if len(openssl_rows) != 1:
        raise ValueError('Exactly one pinned OpenSSL source required')
    openssl = copy.deepcopy(openssl_rows[0])
    if (python['version'], python['sha256'], python['url']) != (
            '3.14.5', PYTHON_SHA, 'https://www.python.org/ftp/python/3.14.5/Python-3.14.5.tgz'):
        raise ValueError('CPython source pin drift')
    if (openssl['version'], openssl['sha256'], openssl['url']) != (
            '3.6.4', OPENSSL_SHA,
            'https://github.com/openssl/openssl/releases/download/openssl-3.6.4/openssl-3.6.4.tar.gz'):
        raise ValueError('OpenSSL source pin drift')
    python.update(name='cpython', maximum_size=128 * 1024**2)
    openssl.update(maximum_size=128 * 1024**2, deployment_target='26.5')
    tool = copy.deepcopy(json.loads((HERE / 'innoextract.lock.json').read_text())['toolchain'])
    tool['deployment_target'] = '26.5'
    if profile() == 'github-macos15-arm64':
        tool = github_toolchain()
        openssl['deployment_target'] = tool['deployment_target']
    return python, openssl, tool


def python_steps(source, prefix, jobs):
    if type(jobs) is not int or not 1 <= jobs <= 16:
        raise ValueError('Native job count must be between 1 and 16')
    return [[str(source / 'configure'), '--prefix=' + str(prefix),
             '--enable-shared', '--without-static-libpython', '--without-ensurepip',
             '--with-openssl=' + str(prefix), '--with-openssl-rpath=auto',
             '--with-readline=no'],
            ['/usr/bin/make', '-j' + str(jobs)], ['/usr/bin/make', 'install']]


def source_ownership(build, source):
    text = (build / 'Makefile').read_text()
    matches = re.findall(r'^srcdir\s*=\s*(.+?)\s*$', text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError('CPython Makefile must identify exactly one srcdir')
    path = Path(matches[0])
    actual = path if path.is_absolute() else build / path
    if actual.resolve() != source.resolve():
        raise ValueError('CPython build uses a foreign source tree')
    return dict(status='OWN_SOURCE', makefile_sha256=framework.sha(build / 'Makefile'))


def require_cloud():
    if profile() == 'github-macos15-arm64':
        tool = github_toolchain()
        if (os.environ.get('GITHUB_ACTIONS') != 'true' or
                os.environ.get('RUNNER_OS') != 'macOS' or
                os.environ.get('RUNNER_ARCH') != 'ARM64' or
                os.environ.get('CI_XCODE_CLOUD') == 'TRUE' or
                platform.system() != 'Darwin' or platform.machine() != 'arm64'):
            raise ValueError('Vendor acquisition/execution requires GitHub macOS ARM64')
        return
    if (os.environ.get('CI_XCODE_CLOUD') != 'TRUE' or
            platform.system() != 'Darwin' or platform.machine() != 'arm64'):
        raise ValueError('Vendor acquisition/execution is Xcode Cloud ARM64 only')


def build(work, reports, deadline, jobs=8):
    """Called by the final helper job; result is a private build-time interpreter.

    The caller owns publication and the overall deadline. Native prefixes and
    source archives stay outside reports; only receipts/logs/licenses go there.
    """
    require_cloud()
    if (profile() == 'github-macos15-arm64' and
            platform.python_version() != github_toolchain()['bootstrap_python']):
        raise ValueError('GitHub bootstrap Python pin differs')
    python, openssl, tool = inputs()
    if work.exists() or work.is_symlink():
        raise ValueError('Fresh native workspace required')
    if deadline <= time.monotonic():
        raise TimeoutError('Native runtime budget exhausted')
    python_steps(work / 'unused', work / 'unused-prefix', jobs)
    work.mkdir(parents=True)
    reports.mkdir(parents=True, exist_ok=True)
    prefix = work / 'prefix'
    prefix.mkdir()
    runner = framework.load_runner()
    result = dict(schema=1, status='STARTED', phase='toolchain', components=[],
                  source_execution='CLOUD_ONLY', helpers='NOT_BUILT',
                  pep517_closure='NOT_ACCEPTED', package_relocation='NOT_ENABLED',
                  driver_sha256=framework.sha(__file__), first_failure=None)
    report = reports / 'native-runtime.json'
    env = None

    def save():
        framework.write_json(report, result)

    def command(argv, cwd, label, timeout=1800):
        result['phase'] = label
        save()
        log = reports / (label + '.log')
        runner.command(argv, cwd, env, log, reports, label, deadline, timeout=timeout)
        return log

    try:
        save()
        sdk, cc, cxx = runner.toolchain_preflight(tool, reports)
        if profile() == 'github-macos15-arm64':
            tool.update(python=sys.version.split()[0], python_path=sys.executable,
                        exact_pins_state='VERIFIED_BEFORE_SOURCES')
            env = runner.environment(prefix, tool, cc, cxx, sdk)
            command(['/usr/bin/xcrun', 'ld', '-v'], work, 'github-selected-ld', 30)
            command(['/usr/bin/sw_vers', '-productVersion'], work, 'github-host-macos', 30)
        result['toolchain'] = tool
        env = runner.environment(prefix, tool, cc, cxx, sdk)
        env.update(PKG_CONFIG='/usr/bin/false', PYTHONNOUSERSITE='1',
                   PYTHONDONTWRITEBYTECODE='1')
        env['LDFLAGS'] += ' -arch arm64 -isysroot ' + str(sdk)
        env['CFLAGS'] += ' -isysroot ' + str(sdk)
        for row in [openssl, python]:
            name = row['name']
            result['phase'] = name + '-source'
            save()
            if time.monotonic() >= deadline:
                raise TimeoutError('Native runtime source budget exhausted')
            hosts = ['www.python.org'] if name == 'cpython' else [
                'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com']
            transfer = functools.partial(private_curl.source_transfer, allowed_hosts=hosts)
            archive = work / (name + '.source')
            public_archive.download(row, archive, reports, transfer=transfer)
            source = runner.unpack(archive, work / (name + '-source'))
            link_receipt = work / 'reports' / (name + '-source-links.json')
            if not link_receipt.is_file():
                raise ValueError('Source extraction graph receipt missing')
            retained_links = reports / (name + '-source-links.json')
            if link_receipt.resolve() != retained_links.resolve():
                if retained_links.exists():
                    raise ValueError('Source extraction receipt collision')
                shutil.copy2(link_receipt, retained_links)
            item = dict(name=name, version=row['version'], archive_sha256=framework.sha(archive),
                        source_root=source.relative_to(work).as_posix(), status='STARTED',
                        extraction_receipt_sha256=framework.sha(retained_links))
            result['components'].append(item)
            if name == 'openssl':
                cwd, commands = source, runner.build_steps(row, source, prefix, sdk, jobs, (cc, cxx))
            else:
                cwd = work / 'python-build'
                cwd.mkdir()
                commands = python_steps(source, prefix, jobs)
            for index, argv in enumerate(commands):
                command(argv, cwd, name + '-' + str(index))
                if name == 'cpython' and index == 0:
                    item['ownership'] = source_ownership(cwd, source)
            item.update(status='BUILT', licenses=runner.licenses(source, prefix, name))
            save()
        interpreter = prefix / 'bin/python3.14'
        smoke = ('import ctypes,json,platform,sqlite3,ssl,sys,zlib; '
                 'assert sys.version_info[:3]==(3,14,5); '
                 'assert platform.machine()=="arm64"; '
                 'assert ssl.OPENSSL_VERSION_INFO[:3]==(3,6,4); '
                 'print(json.dumps({"python":list(sys.version_info[:3]),'
                 '"architecture":platform.machine(),"openssl":ssl.OPENSSL_VERSION,'
                 '"sqlite":sqlite3.sqlite_version,"zlib":zlib.ZLIB_RUNTIME_VERSION}))')
        command([str(interpreter), '-B', '-I', '-c', smoke], work, 'native-python-smoke', 120)
        command(['/usr/bin/python3', '-B', '-I', str(HERE / 'check-macho-arch.py'),
                 str(prefix)], work, 'native-runtime-architectures', 120)
        result.update(status='NATIVE_RUNTIME_BUILT_NOT_HELPERS', phase='complete',
                      interpreter_sha256=framework.sha(interpreter),
                      shared_python_sha256=framework.sha(prefix / 'lib/libpython3.14.dylib'))
        return interpreter, prefix
    except Exception as error:
        result.update(status='FAILED', first_failure=dict(phase=result['phase'],
                      exception=type(error).__name__, message=str(error)))
        raise
    finally:
        save()

#!/usr/bin/env python3
"""One cloud job: pinned CPython/OpenSSL, source wheels, bootloader, helpers."""
import argparse
import functools
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tarfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import helper_native_runtime as native
import helper_package_worker as worker


def read_lock():
    lock = json.loads((HERE / 'python-helpers.build.lock.json').read_text())
    candidate_path = HERE / 'python-helpers.candidate.lock.json'
    if native.framework.sha(candidate_path) != lock['candidate_lock_sha256']:
        raise ValueError('Original candidate source lock drift')
    candidate = json.loads(candidate_path.read_text())
    packages = {row['name']: dict(row) for row in candidate['packages']}
    for row in lock['source_changes']:
        packages[row['name']] = dict(row)
    order = lock['build_order']
    if len(set(order)) != len(order) or set(order) != set(packages):
        raise ValueError('Every source package must have exactly one build slot')
    for row in packages.values():
        if not re.fullmatch(r'[a-f0-9]{64}', row['sha256']) or not row['url'].startswith('https://files.pythonhosted.org/packages/'):
            raise ValueError('Official exact package source pin required')
    lock.update(packages=packages, helpers=candidate['helpers'])
    return lock


def source_inventory(source, stage_log):
    rows = []
    # Git preserves executable permission, not archive/checkout write permissions.
    for record in stage_log.split(b'\0'):
        if not record:
            continue
        header, raw_path = record.split(b'\t', 1)
        mode = header.split()[0]
        if mode not in [b'100644', b'100755']:
            continue
        relative = raw_path.decode()
        path = source / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(source.resolve()):
            raise ValueError('Tracked regular helper source missing or escapes source')
        data = path.read_bytes()
        executable = mode == b'100755'
        if bool(path.stat().st_mode & stat.S_IXUSR) != executable:
            raise ValueError('Helper executable mode differs from Git index')
        rows.append(dict(path=relative, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                          mode='0o755' if executable else '0o644'))
    raw = json.dumps(sorted(rows, key=lambda x: x['path']), sort_keys=True, separators=(',', ':')).encode()
    return hashlib.sha256(raw).hexdigest(), len(rows)


def checkout_source(row, destination, command, work):
    if destination.is_symlink() or (destination.exists() and any(destination.iterdir())):
        raise ValueError('Helper checkout requires fresh or empty gitlink directory')
    destination.mkdir(exist_ok=True)
    command(['/usr/bin/git', 'init', '-q', str(destination)], work, row['name'] + '-git-init', 30)
    command(['/usr/bin/git', '-C', str(destination), 'fetch', '--depth=1', '--no-tags',
             row['url'], row['revision']], work, row['name'] + '-git-fetch', 300)
    command(['/usr/bin/git', '-C', str(destination), 'checkout', '--detach', '-q', row['revision']],
            work, row['name'] + '-git-checkout', 60)
    actual = command(['/usr/bin/git', '-C', str(destination), 'rev-parse', 'HEAD'], work,
                     row['name'] + '-git-head', 30).decode().strip()
    if actual != row['revision']:
        raise ValueError('Helper source revision drift')
    inventory = command(['/usr/bin/git', '-C', str(destination), 'ls-files', '--stage', '-z'], work,
                        row['name'] + '-git-inventory', 30)
    digest, count = source_inventory(destination, inventory)
    if digest != row['source_inventory_sha256']:
        raise ValueError('Helper source byte inventory differs: ' + row['name'] +
                         '; expected=' + row['source_inventory_sha256'] +
                         '; actual=' + digest + '; files=' + str(count))
    for filename, field in [('requirements.txt', 'requirements_sha256'),
                            ('pyproject.toml', 'pyproject_sha256')]:
        if field in row and native.framework.sha(destination / filename) != row[field]:
            raise ValueError('Helper source controls drift: ' + row['name'])
    return dict(name=row['name'], revision=actual, source_inventory_sha256=digest, files=count)


def verify_source(args, lock):
    """Exercise the full build's exact checkout/census without building native tools."""
    native.require_cloud()
    if args.work.exists() or args.work.is_symlink():
        raise ValueError('Fresh source-check workspace required')
    args.work.mkdir(parents=True)
    reports = args.work / 'reports'; reports.mkdir()
    runner = native.framework.load_runner()
    env = native.framework.build_env()
    deadline = time.monotonic() + args.minutes * 60
    result = dict(schema=1, status='STARTED', phase='source-check', first_failure=None,
                  selection=args.verify_source, compile='NOT_ENABLED', install='skipped')
    def command(argv, cwd, label, timeout):
        result['phase'] = label
        native.framework.write_json(reports / 'RESULT.json', result)
        log = reports / (label + '.log')
        runner.command(argv, cwd, env, log, reports, label, deadline, timeout=timeout)
        return log.read_bytes()
    try:
        row = next(r for r in lock['helpers'] if r['name'] == args.verify_source)
        result['source'] = checkout_source(row, args.work / (row['name'] + '-source'), command, args.work)
        result['status'] = 'PASS_EXACT_HELPER_SOURCE'
    except Exception as error:
        result.update(status='FAILED', first_failure=dict(phase=result['phase'],
                      exception=type(error).__name__, message=str(error)))
        raise
    finally:
        native.framework.write_json(reports / 'RESULT.json', result)
    return result


def portable_cli(prefix, product, command):
    hidden = prefix.with_name('prefix-inactive-for-helper-smoke')
    if hidden.exists() or hidden.is_symlink():
        raise ValueError('Portable smoke prefix collision')
    prefix.rename(hidden)
    try:
        for name in ['legendary', 'gogdl']:
            command([str(product / name), '--help'], product.parent, name + '-portable-help', 120)
    finally:
        hidden.rename(prefix)


def install_argv(python, wheel, name):
    """Bootstrap pip from its source-built wheel in the selected pip-free interpreter."""
    argv = [str(python), '-B', '-I']
    if name == 'pip':
        argv += ['-c', 'import runpy,sys; sys.path.insert(0,sys.argv.pop(1)); '
                 'runpy.run_module("pip",run_name="__main__")', str(wheel)]
    else:
        argv += ['-m', 'pip']
    return argv + ['install', '--no-index', '--no-deps',
                   '--disable-pip-version-check', str(wheel)]


def selection(lock, only_package=None, only_step=None):
    order = lock['build_order']
    if only_package is not None and only_step is not None:
        raise ValueError('Choose only one package or step selector')
    if only_step is not None:
        if type(only_step) is not int or not 1 <= only_step <= len(order):
            raise ValueError('Package step must be between 1 and ' + str(len(order)))
        only_package = order[only_step - 1]
    if only_package is None:
        return None
    if only_package not in order:
        raise ValueError('Selected package is absent from pinned build order')
    index = order.index(only_package)
    return dict(package=only_package, step=index + 1, build_order=order[:index + 1],
                prerequisite_policy='REBUILD_PRECEDING_PINNED_SLOTS',
                native_runtime='NOT_BUILT_CLOUD_BOOTSTRAP_VENV',
                classification='DIAGNOSTIC_ONLY_NOT_HELPER_ACCEPTANCE')


def build(args, lock):
    native.require_cloud()
    selected = selection(lock, getattr(args, 'only_package', None), getattr(args, 'only_step', None))
    if selected and native.profile() != 'github-macos15-arm64':
        raise ValueError('Scoped package diagnosis requires the GitHub ARM64 profile')
    if args.work.exists() or args.work.is_symlink():
        raise ValueError('Fresh complete helper workspace required')
    args.work.mkdir(parents=True)
    reports = args.work / 'reports'; reports.mkdir()
    wheels = args.work / 'wheels'; wheels.mkdir()
    product = args.work / 'product'; product.mkdir()
    deadline = time.monotonic() + args.minutes * 60
    runner = native.framework.load_runner()
    result = dict(schema=1, status='STARTED', phase='native-runtime', packages=[], helpers=[],
                  lock_sha256=native.framework.sha(HERE / 'python-helpers.build.lock.json'),
                  driver_sha256=native.framework.sha(__file__), first_failure=None,
                  ARM64EC='NOT_APPLICABLE_NATIVE_HELPERS', whole_app='NOT_ENABLED',
                  r2_comparison='NOT_ENABLED', license_review='NOT_ACCEPTED', install_skipped=0)
    result['selection'] = selected or dict(classification='COMPLETE_SOURCE_HELPERS')
    env = None

    def save():
        native.framework.write_json(reports / 'RESULT.json', result)

    def command(argv, cwd, label, timeout=1800):
        result['phase'] = label; save()
        log = reports / (label + '.log')
        runner.command(argv, cwd, env, log, reports, label, deadline, timeout=timeout)
        return log.read_bytes()

    def package(source, row, bootstrap=False):
        name = row['name']; receipt = reports / (name + '-wheel.json')
        argv = [str(python), '-B', '-I', str(HERE / 'helper_package_worker.py'),
                '--source', str(source), '--name', name, '--version', row['version'],
                '--wheels', str(wheels), '--prefix', str(prefix), '--receipt', str(receipt),
                '--diagnostics', str(reports / (name + '-worker-diagnostics.json'))]
        if bootstrap:
            argv.append('--bootstrap')
        if name == 'legendary':
            argv.extend(['--distribution', 'legendary-gl'])
        package_env = dict(env, SETUPTOOLS_SCM_PRETEND_VERSION=row['version'])
        native.framework.write_json(reports / (name + '-build-environment.json'), package_env)
        log = reports / (name + '-wheel.stdout.log')
        result['phase'] = name + '-wheel'; save()
        runner.command(argv, source, package_env, log, reports, name + '-wheel', deadline, timeout=1200,
                       stderr_log=reports / (name + '-wheel.stderr.log'))
        built = json.loads(receipt.read_text())
        if not bootstrap:
            command(install_argv(python, wheels / built['wheel'], name), source, name + '-install', 300)
            if name == 'pip':
                command([str(python), '-B', '-I', '-m', 'pip', '--version'], source, 'pip-bootstrap-smoke', 60)
        built['licenses'] = runner.licenses(source, prefix, name)
        result['packages'].append(built); save()
        return built

    def checkout(row, destination):
        return checkout_source(row, destination, command, args.work)

    try:
        save()
        if selected:
            tool = native.github_toolchain()
            if '.'.join(map(str, sys.version_info[:3])) != tool['bootstrap_python']:
                raise ValueError('Scoped GitHub bootstrap Python pin differs')
            native_reports = reports / 'native'; native_reports.mkdir()
            sdk, cc, cxx = runner.toolchain_preflight(tool, native_reports)
            prefix = args.work / 'native/prefix'; prefix.parent.mkdir()
            env = runner.environment(prefix, tool, cc, cxx, sdk)
            command([sys.executable, '-B', '-I', '-m', 'venv', '--without-pip', str(prefix)],
                    args.work, 'scoped-bootstrap-venv', 60)
            python = prefix / 'bin/python3'
            native.framework.write_json(native_reports / 'native-runtime.json',
                dict(status='NOT_BUILT_DIAGNOSTIC_BOOTSTRAP_VENV', toolchain=tool,
                     bootstrap_python=sys.version.split()[0], source_python='NOT_BUILT',
                     source_openssl='NOT_BUILT', interpreter_sha256=native.framework.sha(python)))
        else:
            python, prefix = native.build(args.work / 'native', reports / 'native', deadline, args.jobs)
        native_report = json.loads((reports / 'native/toolchain-preflight.json').read_text())
        tool = json.loads((reports / 'native/native-runtime.json').read_text())['toolchain']
        actual = native_report['actual']
        env = runner.environment(prefix, tool, actual['clang_path'], actual['clangxx_path'], actual['sdk_path'])
        env.update(lock['build_environment'])
        env.update(PYTHONDONTWRITEBYTECODE='1', PYTHONNOUSERSITE='1',
                   PYTHON=str(python),
                   GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null',
                    GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/usr/bin/false')
        if native.profile() == 'xcode-cloud':
            env['CI_XCODE_CLOUD'] = 'TRUE'
        else:
            env.update(REPRO109_HELPER_PROFILE='github-macos15-arm64',
                       GITHUB_ACTIONS='true', RUNNER_OS='macOS', RUNNER_ARCH='ARM64')
        native.framework.write_json(reports / 'build-environment.json', env)
        sources = {}
        for name in selected['build_order'] if selected else lock['build_order']:
            row = lock['packages'][name]
            result['phase'] = name + '-source'; save()
            archive = args.work / (name + '.source')
            download_row = dict(row, size=row['bytes'])
            transfer = functools.partial(native.private_curl.source_transfer, allowed_hosts=['files.pythonhosted.org'])
            native.public_archive.download(download_row, archive, reports, transfer=transfer)
            source = runner.unpack(archive, args.work / (name + '-source'))
            sources[name] = source
            if name == 'pyinstaller':
                old = []
                for path in (source / 'PyInstaller/bootloader').rglob('*'):
                    if path.is_file() and path.name in ['run', 'run_d', 'runw', 'runw_d', 'run.exe', 'run_d.exe', 'runw.exe', 'runw_d.exe']:
                        old.append(dict(path=path.relative_to(source).as_posix(), sha256=native.framework.sha(path)))
                        path.unlink()
                native.framework.write_json(reports / 'bootloader-replaced.json', dict(prebuilt_inputs='EXCLUDED', files=old))
                command([str(python), str(source / 'bootloader/waf'), '--no-universal2', 'all'],
                        source / 'bootloader', 'pyinstaller-bootloader', 1800)
                if not (source / 'PyInstaller/bootloader/Darwin-64bit/run').is_file():
                    raise ValueError('Source-built Darwin bootloader missing')
                command(['/usr/bin/python3', '-B', '-I', str(HERE / 'check-macho-arch.py'),
                         str(source / 'PyInstaller/bootloader')], args.work, 'bootloader-architectures', 120)
            package(source, row, name in lock['bootstrap_wheels'])
        if selected:
            result.update(status='SCOPED_SOURCE_PACKAGE_BUILT_DIAGNOSTIC_ONLY', phase='complete',
                          helpers='NOT_ENABLED', native_runtime='NOT_BUILT_CLOUD_BOOTSTRAP_VENV',
                          source_python_acceptance='NOT_ENABLED', source_openssl_acceptance='NOT_ENABLED',
                          install_skipped='NATIVE_RUNTIME_AND_HELPER_PRODUCTS')
            return
        by_name = {row['name']: row for row in lock['helpers']}
        for name in ['legendary', 'gogdl']:
            row = by_name[name]; source = args.work / (name + '-source')
            proof = checkout(row, source)
            if name == 'legendary':
                if native.framework.sha(source / 'requirements.txt') != row['requirements_sha256']:
                    raise ValueError('Legendary runtime requirements drift')
            else:
                if native.framework.sha(source / 'pyproject.toml') != row['pyproject_sha256']:
                    raise ValueError('Gogdl source controls drift')
                link = command(['/usr/bin/git', '-C', str(source), 'ls-tree', 'HEAD', 'xdelta3'],
                               args.work, 'gogdl-xdelta-gitlink', 30).decode().split()
                if len(link) != 4 or link[:3] != ['160000', 'commit', by_name['xdelta3']['revision']]:
                    raise ValueError('Gogdl xdelta3 submodule revision drift')
                proof['xdelta3'] = checkout(by_name['xdelta3'], source / 'xdelta3')
                proof['xdelta3']['licenses'] = runner.licenses(source / 'xdelta3', prefix, 'xdelta3')
            built = package(source, row)
            if name == 'gogdl':
                command([str(python), '-B', '-I', '-c',
                         'import gogdl.xdelta3; print("GOGDL_XDELTA3_IMPORT=PASS")'],
                        args.work, 'gogdl-native-extension-smoke', 120)
            entry = built['console_scripts'].get(name)
            if not isinstance(entry, str) or not re.fullmatch(r'[A-Za-z_][\w.]*:[A-Za-z_]\w*', entry):
                raise ValueError('Helper console entry point missing or unsafe')
            module, function = entry.split(':')
            script = args.work / (name + '-entry.py')
            script.write_text('from ' + module + ' import ' + function + '\nif __name__ == "__main__":\n    ' + function + '()\n')
            command([str(python), '-B', '-I', '-m', 'PyInstaller', '--clean', '--noconfirm', '--onefile',
                     '--target-architecture', 'arm64', '--name', name, '--distpath', str(product),
                     '--workpath', str(args.work / (name + '-pyinstaller')), '--specpath', str(args.work),
                     '--collect-submodules', name, '--collect-data', 'certifi', str(script)],
                    args.work, name + '-freeze', 1200)
            command([str(product / name), '--help'], args.work, name + '-cli-help', 120)
            proof.update(status='SOURCE_BUILT_CLI_HELP_PASS', version=row['version'],
                         bytes=(product / name).stat().st_size, sha256=native.framework.sha(product / name))
            result['helpers'].append(proof); save()
        command([str(python), '-B', '-I', '-m', 'pip', 'check'], args.work, 'runtime-dependency-closure', 120)
        command(['/usr/bin/python3', '-B', '-I', str(HERE / 'check-macho-arch.py'), str(prefix)],
                args.work, 'compiled-python-extensions-architectures', 120)
        command(['/usr/bin/python3', '-B', '-I', str(HERE / 'check-macho-arch.py'), str(product)],
                args.work, 'helpers-architectures', 120)
        portable_cli(prefix, product, command)
        shutil.copytree(prefix / 'share/licenses', product / 'licenses')
        archive = args.work / 'helpers.tar.gz'
        with tarfile.open(archive, 'w:gz') as stream:
            for path in sorted(product.iterdir()): stream.add(path, arcname=path.name)
        result.update(status='SOURCE_HELPERS_BUILT_NOT_FINAL_APP', phase='complete',
                      archive=dict(name=archive.name, bytes=archive.stat().st_size, sha256=native.framework.sha(archive)),
                      embedded_dylib_relocation='PREFIX_HIDDEN_CLI_SMOKE_PASS_ONLY',
                      r2_function_section_comparison='NOT_ENABLED')
        args.publish_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(archive, args.publish_dir / archive.name)
    except Exception as error:
        result.update(status='FAILED', first_failure=dict(phase=result['phase'],
                      exception=type(error).__name__, message=str(error)))
        raise
    finally:
        save()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', action='store_true')
    parser.add_argument('--verify-source', choices=['legendary', 'gogdl', 'xdelta3'])
    parser.add_argument('--work', type=Path)
    parser.add_argument('--publish-dir', type=Path)
    parser.add_argument('--minutes', type=int, default=120)
    parser.add_argument('--jobs', type=int, default=8)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument('--only-package')
    scope.add_argument('--only-step', type=int)
    args = parser.parse_args(); lock = read_lock()
    if args.verify_source:
        if args.build or args.only_package or args.only_step is not None or args.work is None or not 1 <= args.minutes <= 15:
            raise ValueError('Source-only mode requires a fresh bounded workspace without package selectors')
        print(json.dumps(verify_source(args, lock)))
        return
    selected = selection(lock, args.only_package, args.only_step)
    if not args.build:
        print(json.dumps(dict(status='PLAN_ONLY', source_packages=len(lock['packages']),
                              helpers=['legendary', 'gogdl'], selection=selected,
                              network=0, builds=0, install='skipped')))
        return
    if args.work is None or args.publish_dir is None or not 1 <= args.minutes <= 120:
        raise ValueError('Bounded cloud workspace/publication paths required')
    build(args, lock)


if __name__ == '__main__':
    main()

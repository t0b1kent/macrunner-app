#!/usr/bin/env python3
"""Build the missing installer tool from its existing source lock and cloud-built dependencies."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'repro109deps'))
import build_deps as deps
sys.path.insert(0, str(HERE))
import assemble_engine as assembly

BUILD_NAMES = ['xz', 'icu', 'boost', 'innoextract']


def require_tools(stage):
    names = ['git'] + (['make', 'xcrun', 'xcodebuild', 'install_name_tool'] if stage == 'build' else [])
    for name in names:
        if shutil.which(name) is None:
            raise ValueError('Required installer build tool missing: ' + name)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch(row, target):
    """Only callers' SHA-pinned lock rows reach this source transport."""
    limit = row['maximum_size']
    count = 0
    with urllib.request.urlopen(row['url'], timeout=90) as response, target.open('xb') as stream:
        while data := response.read(1024 * 1024):
            count += len(data)
            if count > limit:
                raise ValueError('Source archive exceeds lock cap: ' + row['name'])
            stream.write(data)
    if sha(target) != row['sha256']:
        raise ValueError('Source archive SHA differs: ' + row['name'])


def steps(row, source, prefix, sdk, compilers):
    if row['kind'] == 'icu':
        return [[str(source / 'source/configure'), '--prefix=' + str(prefix),
                 '--disable-samples', '--disable-tests', '--enable-shared', '--disable-static'],
                ['make', '-j2'], ['make', 'install']]
    if row['kind'] == 'boost':
        names = ['atomic', 'container', 'date_time', 'filesystem', 'iostreams',
                 'program_options', 'random', 'regex']
        return [[str(source / 'bootstrap.sh'), '--prefix=' + str(prefix),
                 '--with-toolset=clang', '--with-libraries=' + ','.join(names)],
                [str(source / 'b2'), '-j2', 'toolset=clang', 'variant=release', 'link=shared',
                 'threading=multi', 'architecture=arm', 'address-model=64',
                 'cxxflags=-O2 -arch arm64 -mmacosx-version-min=14.0 -I' + str(prefix / 'include'),
                 'linkflags=-arch arm64 -mmacosx-version-min=14.0 -L' + str(prefix / 'lib'),
                 '--prefix=' + str(prefix), '-sICU_PATH=' + str(prefix), 'install']]
    return deps.build_steps(row, source, prefix, sdk, 2, compilers)


def restore_dependencies(wine, work, reports):
    path = wine / 'build/release110/graphics_inputs.py'
    spec = importlib.util.spec_from_file_location('inno_cloud_inputs', path)
    inputs = importlib.util.module_from_spec(spec); spec.loader.exec_module(inputs)
    pin = inputs.INPUTS['deps']
    run = inputs.api('/actions/runs/' + str(pin['run']))
    jobs = inputs.api('/actions/runs/' + str(pin['run']) + '/jobs?per_page=100')['jobs']
    if run['head_sha'] != pin['revision'] or not any(j['name'] == 'deps' and j['conclusion'] == 'success' for j in jobs):
        raise ValueError('Selected dependency source producer did not succeed')
    metadata = inputs.api('/actions/artifacts/' + str(pin['artifact']))
    if metadata['expired'] or metadata['workflow_run']['id'] != pin['run'] or metadata['digest'] != 'sha256:' + pin['sha256']:
        raise ValueError('Dependency source artifact identity differs')
    archive = work / 'deps.zip'
    inputs.download_artifact(pin['artifact'], archive, pin['sha256'], reports)
    inputs.unpack_zip(archive, work / 'dependency-artifact')
    archive = inputs.only(work / 'dependency-artifact', 'dependency-prefix.tar.gz')
    if sha(archive) != Path(str(archive) + '.sha256').read_text().split()[0]:
        raise ValueError('Dependency prefix tar SHA differs')
    prefix = Path(os.environ['RUNNER_TEMP']) / 'repro110-wine-c12-work/deps/prefix'
    prefix.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        if len(members) > 300000 or sum(x.size for x in members) > 3 * 1024**3:
            raise ValueError('Dependency prefix exceeds extraction cap')
        stream.extractall(prefix, members=members, filter='data')
    original = json.loads((wine / 'build/repro109deps/deps.lock.json').read_text())
    lock = json.loads((HERE / 'innoextract.lock.json').read_text())
    reused = []
    for name in ['cmake', 'ninja', 'zstd']:
        before = next(r for r in original['components'] if r['name'] == name)
        after = next(r for r in lock['components'] if r['name'] == name)
        if (before['version'], before['sha256']) != (after['version'], after['sha256']):
            raise ValueError('Reused source dependency pin differs: ' + name)
        if not all((prefix / f).is_file() for f in after['outputs']):
            raise ValueError('Reused source dependency output missing: ' + name)
        reused.append(dict(name=name, version=after['version'], source_sha256=after['sha256']))
    return prefix, dict(producer=pin, reused=reused)


def main(args):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('Installer source work requires the native ARM64 GitHub builder')
    require_tools(args.stage)
    args.work.mkdir(parents=True, exist_ok=False)
    reports = args.work / 'reports'; reports.mkdir()
    result = dict(status='STARTED', first_failure=None, install_skipped=0, stage=args.stage, sources=[], commands=[],
                  signing='NOT_ENABLED', games='NOT_ENABLED', lock_sha256=sha(HERE / 'innoextract.lock.json'))
    env = None
    def run(name, argv, cwd=args.work):
        log = reports / (name + '.log')
        started = time.monotonic()
        with log.open('xb') as stream:
            child = subprocess.run([str(x) for x in argv], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=stream, stderr=subprocess.STDOUT, timeout=1800)
        result['commands'].append(dict(name=name, rc=child.returncode, sha256=sha(log), seconds=round(time.monotonic()-started, 3)))
        if child.returncode or log.stat().st_size > 32 * 1024**2:
            raise ValueError(name + ' failed; complete raw log retained')
    try:
        lock = json.loads((HERE / 'innoextract.lock.json').read_text())
        names = [args.only] if args.stage == 'inputs' else BUILD_NAMES
        sources = {}
        for name in names:
            row = next(r for r in lock['components'] if r['name'] == name)
            archive = args.work / (name + '.source')
            fetch(row, archive)
            source = deps.unpack(archive, args.work / (name + '-source'))
            for i, patch in enumerate(row.get('patches', [])):
                delta = args.work / (name + '-' + str(i) + '.patch')
                fetch(patch, delta)
                run(name + '-patch-' + str(i), ['git', 'apply', '-p' + str(patch['strip']), delta], source / patch['directory'])
            sources[name] = source
            result['sources'].append(dict(name=name, sha256=row['sha256'], bytes=archive.stat().st_size))
        if args.stage == 'inputs':
            result['status'] = 'INNOEXTRACT_SOURCE_INPUTS_PASS_NOT_BUILT'
            return 0
        prefix, result['dependencies'] = restore_dependencies(args.wine, args.work, reports)
        sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
        version = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
        xcode = subprocess.check_output(['xcodebuild', '-version'], text=True)
        if version != '27.0' or not xcode.startswith('Xcode 27'):
            raise ValueError('Selected installer Xcode/SDK differs')
        compilers = tuple(subprocess.check_output(['xcrun', '-f', tool], text=True).strip() for tool in ['clang', 'clang++'])
        result['toolchain'] = dict(xcode=xcode.strip(), sdk=version, compilers=compilers)
        env = deps.environment(prefix, dict(deployment_target='14.0'), *compilers, sdk)
        for name in BUILD_NAMES:
            row = next(r for r in lock['components'] if r['name'] == name)
            for number, argv in enumerate(steps(row, sources[name], prefix, sdk, compilers)):
                run(name + '-' + str(number), argv, sources[name])
            if not all((prefix / f).is_file() for f in row['outputs']):
                raise ValueError('Installer dependency output missing: ' + name)
            deps.licenses(sources[name], prefix, name)
        output = args.work / 'outputs/innoextract'; output.mkdir(parents=True)
        binary = output / 'innoextract'; shutil.copy2(prefix / 'bin/innoextract', binary)
        libdir = output / 'lib'; libdir.mkdir()
        bundled, result['dependency_inputs'] = assembly.dependency_closure([binary], libdir, [prefix])
        for path in [binary, *libdir.iterdir()]:
            info = assembly.macho_info(path)
            arguments = assembly.relocation_args(info, path, libdir, bundled)
            if arguments:
                run('relocate-' + path.name, ['install_name_tool', *arguments, path])
        shutil.copytree(prefix / 'share/licenses', output / 'licenses')
        result['outputs'] = [dict(path=str(p.relative_to(output)), bytes=p.stat().st_size, sha256=sha(p))
                             for p in sorted(output.rglob('*')) if p.is_file()]
        result['status'] = 'INNOEXTRACT_SOURCE_BUILT_SIGNING_DEFERRED'
        return 0
    except Exception as error:
        result.update(status='FAILED', first_failure=str(error))
        return 1
    finally:
        result['install_skipped'] = sum('install skipped' in line.lower() for p in reports.glob('*.log')
                                        for line in p.read_text(errors='replace').splitlines())
        (reports / 'RESULT.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k:result[k] for k in ['status','first_failure','install_skipped']}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', choices=['inputs', 'build'], required=True)
    parser.add_argument('--only', choices=BUILD_NAMES)
    parser.add_argument('--wine', type=Path)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    if (args.stage == 'inputs' and not args.only) or (args.stage == 'build' and not args.wine):
        parser.error('inputs requires --only; build requires --wine')
    raise SystemExit(main(args))

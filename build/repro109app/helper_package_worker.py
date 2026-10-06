#!/usr/bin/env python3
"""Run a pinned source backend using the newly built cloud interpreter."""
import argparse
import configparser
import email.parser
import importlib
import importlib.metadata
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import sysconfig
import zipfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import helper_native_runtime as native


def canonical(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def backend_config(source, legacy_requirements):
    # tomllib comes from our source-built CPython, never the Mac's driver.
    import tomllib
    path = source / 'pyproject.toml'
    data = tomllib.loads(path.read_text()) if path.exists() else {}
    table = data.get('build-system')
    if table is None:
        table = dict(requires=legacy_requirements,
                     **{'build-backend': 'setuptools.build_meta:__legacy__'})
    if not isinstance(table, dict) or not isinstance(table.get('requires'), list):
        raise ValueError('Explicit source build-system requirements required')
    backend = table.get('build-backend', 'setuptools.build_meta:__legacy__')
    if not re.fullmatch(r'[A-Za-z_][\w.]*(?::[A-Za-z_][\w.]*)?', backend):
        raise ValueError('Source backend name refused')
    paths = table.get('backend-path', [])
    if not isinstance(paths, list):
        raise ValueError('Source backend-path must be a list')
    roots = []
    for value in paths:
        if not isinstance(value, str):
            raise ValueError('Source backend-path must be text')
        relative = PurePosixPath(value)
        root = (source / value).resolve()
        if relative.is_absolute() or '..' in relative.parts or not root.is_relative_to(source.resolve()):
            raise ValueError('Backend path escapes selected source')
        roots.append(root)
    return backend, table['requires'], roots


def check_requirements(requirements):
    if not requirements:
        return []
    try:
        from packaging.requirements import Requirement
    except ModuleNotFoundError:
        # Setuptools's pinned source vendors packaging; used only to bootstrap
        # our separate pinned packaging wheel, before that wheel is installed.
        vendor = Path(sysconfig.get_path('purelib')) / 'setuptools/_vendor'
        if not vendor.is_dir():
            raise ValueError('Source-built requirement parser missing')
        sys.path.append(str(vendor))
        from packaging.requirements import Requirement
    checked = []
    for text in requirements:
        requirement = Requirement(text)
        if requirement.url:
            raise ValueError('Unpinned direct build dependency refused')
        if requirement.marker and not requirement.marker.evaluate({'extra': ''}):
            checked.append(dict(requirement=text, state='MARKER_FALSE'))
            continue
        try:
            actual = importlib.metadata.version(requirement.name)
        except importlib.metadata.PackageNotFoundError:
            raise ValueError('Unbuilt dependency: ' + requirement.name) from None
        if not requirement.specifier.contains(actual, prereleases=True):
            raise ValueError('Installed source dependency violates constraint: ' + text)
        checked.append(dict(requirement=text, installed=actual, state='SATISFIED'))
    return checked


def wheel_info(path):
    with zipfile.ZipFile(path) as archive:
        metadata_names = [n for n in archive.namelist() if n.endswith('.dist-info/METADATA')]
        if len(metadata_names) != 1:
            raise ValueError('Exactly one built-wheel metadata required')
        metadata = email.parser.BytesParser().parsebytes(archive.read(metadata_names[0]))
        entries = {}
        entry = metadata_names[0].rsplit('/', 1)[0] + '/entry_points.txt'
        if entry in archive.namelist():
            parser = configparser.ConfigParser()
            parser.read_string(archive.read(entry).decode())
            if parser.has_section('console_scripts'):
                entries = dict(parser.items('console_scripts'))
        return dict(name=metadata['Name'], version=metadata['Version'], console_scripts=entries)


def install_bootstrap(path, prefix):
    destination = Path(sysconfig.get_path('purelib')).resolve()
    if not destination.is_relative_to(prefix.resolve()) or Path(sys.prefix).resolve() != prefix.resolve():
        raise ValueError('Bootstrap installation outside own native prefix')
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            relative = PurePosixPath(member.filename)
            if (relative.is_absolute() or '..' in relative.parts or
                    any(p.endswith('.data') for p in relative.parts) or
                    not (destination / member.filename).resolve().is_relative_to(destination)):
                raise ValueError('Bootstrap wheel needs unsupported or unsafe installation')
        archive.extractall(destination)


def build(source, name, version, wheels, prefix, bootstrap, legacy, distribution=None):
    backend_name, requirements, roots = backend_config(source, legacy)
    checked = check_requirements(requirements)
    for root in reversed(roots):
        sys.path.insert(0, str(root))
    module, _, attribute = backend_name.partition(':')
    backend = importlib.import_module(module)
    if attribute:
        for part in attribute.split('.'):
            backend = getattr(backend, part)
    dynamic = backend.get_requires_for_build_wheel({}) if hasattr(backend, 'get_requires_for_build_wheel') else []
    if not isinstance(dynamic, list):
        raise ValueError('Dynamic source requirements must be a list')
    dynamic_checked = check_requirements(dynamic)
    filename = backend.build_wheel(str(wheels), config_settings={})
    if not isinstance(filename, str) or Path(filename).name != filename:
        raise ValueError('Backend wheel filename refused')
    wheel = wheels / filename
    if not wheel.is_file():
        raise ValueError('Built wheel missing')
    metadata = wheel_info(wheel)
    if canonical(metadata['name']) != canonical(distribution or name) or metadata['version'] != version:
        raise ValueError('Source-built wheel name/version drift')
    if bootstrap:
        install_bootstrap(wheel, prefix)
    return dict(status='SOURCE_WHEEL_BUILT', name=name, version=version,
                wheel=filename, wheel_sha256=native.framework.sha(wheel),
                static_requirements=checked, dynamic_requirements=dynamic_checked,
                backend=backend_name, bootstrap_install=bootstrap,
                console_scripts=metadata['console_scripts'])


def main():
    native.require_cloud()
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--distribution')
    parser.add_argument('--wheels', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--bootstrap', action='store_true')
    args = parser.parse_args()
    os.chdir(args.source)
    result = build(args.source.resolve(), args.name, args.version, args.wheels.resolve(),
                   args.prefix.resolve(), args.bootstrap, ['setuptools>=40.8.0', 'wheel'], args.distribution)
    args.receipt.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    print(json.dumps(dict(status=result['status'], name=args.name, version=args.version)))


if __name__ == '__main__':
    main()

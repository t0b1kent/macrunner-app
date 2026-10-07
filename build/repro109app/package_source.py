#!/usr/bin/env python3
"""Stage existing Swift/framework products; engine and helpers remain separate inputs."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil

RESOURCE = 'MacRunnerControlCenter_MacRunnerControlCenter.bundle'
EXECUTABLE = 'MacRunner Control Center'
FRAMEWORK_RPATH = '@executable_path/../Frameworks'
SYSTEM = ('/usr/lib/', '/System/')


def rpaths(text):
    values = []
    active = False
    seen = False
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('cmd '):
            if active:
                raise ValueError('Incomplete LC_RPATH')
            seen = True
            active = line == 'cmd LC_RPATH'
        elif active and line.startswith('path '):
            match = re.fullmatch(r'path (.+) \(offset [0-9]+\)', line)
            if not match:
                raise ValueError('Malformed LC_RPATH')
            values.append(match.group(1))
            active = False
    if not seen or active or len(values) > 64 or len(values) != len(set(values)):
        raise ValueError('Incomplete, duplicate or excessive LC_RPATH')
    return values


def imports(text):
    values = []
    for line in text.splitlines()[1:]:
        if not line.strip():
            continue
        match = re.fullmatch(r'\s*(.+) \(compatibility version .+, current version .+\)', line)
        if not match:
            raise ValueError('Malformed Mach-O dependency')
        value = match.group(1)
        if not value.startswith(('@rpath/', '@loader_path/', '@executable_path/', *SYSTEM)):
            raise ValueError('App imports a nonportable library')
        values.append(value)
    if not values:
        raise ValueError('App Mach-O imports EMPTY')
    return values


def digest(path):
    with Path(path).open('rb') as stream:
        h = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
        return h.hexdigest()


def linked_files(binary, references, search_paths, app):
    def expand(value):
        for token in ['@executable_path', '@loader_path']:
            if value == token or value.startswith(token + '/'):
                path = (binary.parent / value[len(token):].lstrip('/')).resolve()
                if not path.is_relative_to(app.resolve()):
                    raise ValueError('Staged app relative library path escapes bundle')
                return path
        if value.startswith(SYSTEM):
            return Path(value)
        raise ValueError('Staged app search path is nonportable')
    roots = [expand(path) for path in search_paths]
    for ref in references:
        if ref.startswith(SYSTEM):
            continue  # System libraries can live only in the dyld shared cache.
        if ref.startswith('@rpath/'):
            leaf = ref[len('@rpath/'):]
            if re.fullmatch(r'libswift[A-Za-z0-9_]+\.dylib', leaf) and Path('/usr/lib/swift') in roots:
                continue
            candidates = [(root / leaf).resolve() for root in roots if root.is_relative_to(app.resolve())]
            if not any(path.is_relative_to(app.resolve()) and path.is_file() for path in candidates):
                raise ValueError('Staged app @rpath dependency is missing')
        elif not expand(ref).is_file():
            raise ValueError('Staged app relative dependency is missing')


def relocate(binary, label, command, output, app):
    initial_imports = imports(output(['/usr/bin/otool', '-L', str(binary)], label + '-imports-before'))
    before = rpaths(output(['/usr/bin/otool', '-l', str(binary)], label + '-rpaths-before'))
    removed = [path for path in before if path.startswith('/') and not path.startswith(SYSTEM)]
    for i, path in enumerate(removed):
        command(['/usr/bin/install_name_tool', '-delete_rpath', path, str(binary)], label + '-rpath-delete-' + str(i))
    if FRAMEWORK_RPATH not in before:
        command(['/usr/bin/install_name_tool', '-add_rpath', FRAMEWORK_RPATH, str(binary)], label + '-rpath-add')
    after = rpaths(output(['/usr/bin/otool', '-l', str(binary)], label + '-rpaths-after'))
    expected = [path for path in before if path not in removed]
    if FRAMEWORK_RPATH not in expected:
        expected.append(FRAMEWORK_RPATH)
    if after != expected:
        raise ValueError('Staged app rpath transformation differs')
    if imports(output(['/usr/bin/otool', '-L', str(binary)], label + '-imports-after')) != initial_imports:
        raise ValueError('App imports changed during packaging')
    linked_files(binary, initial_imports, after, app)
    return dict(removed=len(removed), added=FRAMEWORK_RPATH not in before, after=after)


def package(prefix, icon, framework_lock, inventory, command, output):
    """Callbacks are the same bounded command runner/inventory as build_source.py."""
    prefix, icon = Path(prefix), Path(icon)
    app = prefix / 'MacRunner.app'
    if app.exists() or app.is_symlink():
        raise ValueError('Fresh app destination required')
    before = inventory(prefix)  # Validate all internal framework/resource links before copy.
    required = [prefix / 'products/MacRunnerControlCenter', prefix / 'products/macr-hud']
    for path in required:
        if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError('Captured Swift product missing or not executable')
    resource = prefix / 'products' / RESOURCE
    licenses = prefix / 'licenses'
    if resource.is_symlink() or not resource.is_dir() or licenses.is_symlink() or not licenses.is_dir():
        raise ValueError('Captured resources/licenses missing')
    if icon.is_symlink() or not icon.is_file() or not 8 <= icon.stat().st_size <= 8 * 1024**2:
        raise ValueError('Source app icon missing or outside byte cap')
    with icon.open('rb') as stream:
        header = stream.read(8)
    if header[:4] != b'icns' or int.from_bytes(header[4:], 'big') != icon.stat().st_size:
        raise ValueError('Source icon header/size differs')
    for row in framework_lock['components']:
        root = prefix / 'Frameworks' / row['product']
        if root.is_symlink() or not root.is_dir():
            raise ValueError('Captured source framework missing')
        for relative in row['required_binaries']:
            if not (root / relative).is_file():
                raise ValueError('Captured source framework binary missing')
    contents = app / 'Contents'
    macos, resources = contents / 'MacOS', contents / 'Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    binary = macos / EXECUTABLE
    shutil.copy2(required[0], binary)
    shutil.copy2(required[1], resources / 'macr-hud')
    shutil.copy2(icon, resources / 'AppIcon.icns')
    shutil.copytree(resource, resources / RESOURCE, symlinks=True)
    shutil.copytree(prefix / 'Frameworks', contents / 'Frameworks', symlinks=True)
    shutil.copytree(licenses, resources / 'licenses', symlinks=True)
    relocations = {name: relocate(path, 'package-' + name, command, output, app)
                   for name, path in [('app', binary), ('hud', resources / 'macr-hud')]}
    for row in before:
        path = prefix / row['path']
        if digest(path) != row['sha256']:
            raise ValueError('Captured source product changed during packaging')
    info = dict(CFBundleDevelopmentRegion='en', CFBundleExecutable=EXECUTABLE,
                CFBundleIdentifier='com.macrunner.controlcenter', CFBundleInfoDictionaryVersion='6.0',
                CFBundleName='MacRunner', CFBundleDisplayName='MacRunner', CFBundleIconFile='AppIcon',
                CFBundlePackageType='APPL', CFBundleShortVersionString='1.0.9', CFBundleVersion='109',
                LSMinimumSystemVersion='26.5', LSApplicationCategoryType='public.app-category.utilities',
                LSBackgroundOnly=False)
    with (contents / 'Info.plist').open('xb') as stream:
        plistlib.dump(info, stream, sort_keys=True)
    architecture_checker = Path(__file__).with_name('check-macho-arch.py')
    if architecture_checker.is_symlink() or not architecture_checker.is_file():
        raise ValueError('Whole-app Mach-O checker is missing')
    # The bounded command runner requires exit 0 and retains both raw streams.
    # Read headers: Rosetta can make execution of an x86_64 helper look healthy.
    command(['/usr/bin/python3', '-B', '-I', str(architecture_checker), str(app)],
            'package-macho-architecture')
    staged = inventory(app)
    return dict(status='PARTIAL_APP_BUNDLE_RUNTIME_INPUTS_NOT_ENABLED',
                path='MacRunner.app', files=len(staged), bytes=sum(row['bytes'] for row in staged),
                inventory=staged, recipe_sha256=digest(__file__), icon_sha256=digest(icon),
                relocations=relocations,
                macho_architecture=dict(status='PASS', required_slice='arm64',
                                        checker_sha256=digest(architecture_checker)),
                release_signing='NOT_ENABLED', notarization='NOT_ENABLED',
                app_launch='NOT_ENABLED', whole_product='NOT_ENABLED',
                runtime_inputs={name: 'NOT_ENABLED' for name in ['engine', 'loader', 'legendary', 'gogdl', 'innoextract']})

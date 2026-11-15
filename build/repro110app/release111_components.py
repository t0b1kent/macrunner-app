"""Consume the current c33r cloud component layouts without historical binary fallbacks."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def filename(value):
    require(isinstance(value, str) and len(PurePosixPath(value).parts) == 1 and
            value not in ['', '.', '..'] and '/' not in value and '\\' not in value,
            'A plain component filename is required')
    return value


def report(path, status):
    value = json.loads(Path(path).read_text())
    require(value.get('status') == status and value.get('first_failure') is None and value.get('failure') is None,
            'Component source producer did not succeed: ' + str(path))
    return value


def license_roots(parts):
    roots = []
    for variant in ['fex32', 'fex64']:
        manifest = json.loads((parts / variant / 'license-inputs.json').read_text())
        require({'FEX', 'FEXCore'} <= set(manifest), 'Translator upstream license is missing')
        expected = {}
        for category, files in manifest.items():
            category_path = PurePosixPath(category)
            require(not category_path.is_absolute() and '..' not in category_path.parts and
                    category_path.as_posix() == category, 'Unsafe license category')
            for name, digest in files.items():
                expected[(category_path / filename(name)).as_posix()] = digest
        root = parts / variant / 'licenses'
        actual = {}
        for path in root.rglob('*'):
            require(not path.is_symlink(), 'Translator license symlink is forbidden')
            if path.is_file():
                actual[path.relative_to(root).as_posix()] = sha(path)
        require(actual == expected, 'Translator license bytes differ from the source manifest')
        roots.append((variant, root))
    return roots


def fex(root, template, destination, unpack, merge_tree):
    detail = report(root / 'release111-hyperbridge/RESULT.json', 'BUILT_SOURCE_ONLY_NOT_ACCEPTED')
    require(set(detail['variants']) == {'fex32', 'fex64'}, 'Both current translator variants are required')
    for value in detail['variants'].values():
        require(value['status'] == 'BUILT_SOURCE_ONLY' and value['release_bytes'] == 'EXACT_ACCEPTED_BYTES',
                'Translator source bytes are not the selected reference')
    archive = root / 'release111-hyperbridge' / filename(detail['archive']['path'])
    require(sha(archive) == detail['archive']['sha256'], 'Translator product archive differs')
    parts = destination.with_name(destination.name + '-parts')
    unpack(archive, parts)
    for variant in ['fex32', 'fex64']:
        merge_tree(parts / variant / 'engine/fex', destination)
    actual = {p.relative_to(destination).as_posix(): sha(p) for p in destination.rglob('*') if p.is_file()}
    expected = {name.removeprefix('fex/'): value for name, value in template['files'].items() if name.startswith('fex/')}
    require(actual == expected, 'The complete translator overlay differs from the c33r reference')
    # The producer also has a legacy Wine PE alias. The selected engine uses Wine's
    # separately source-built libarm64ecfex.dll; only the fex/ overlay is consumed here.
    licenses = license_roots(parts)
    return dict(archive_sha256=sha(archive), exact_files=len(actual), legacy_wine_pe_alias='NOT_SELECTED',
                license_roots=[dict(namespace=namespace, path=str(path)) for namespace, path in licenses])


GRAPHICS = [('graphics_x64', 'x64', 'x86_64-windows'),
            ('graphics_ec', 'ec', 'aarch64-windows'),
            ('graphics_native', 'native', 'aarch64-unix'),
            ('graphics_i386', 'i386', 'i386-windows'),
            ('graphics_hbdx9_pe', 'hbdx9-pe', 'i386-windows'),
            ('graphics_hbdx9_native', 'hbdx9-native', 'aarch64-unix')]


def graphics(roots, destination, unpack):
    destination.mkdir()
    details = {}
    for name, variant, architecture in GRAPHICS:
        root = roots[name]
        status = 'HBDX9_SOURCE_BUILT_NOT_RELEASE_ACCEPTED' if variant.startswith('hbdx9-') else 'GRAPHICS_SOURCE_BUILT_NOT_RELEASE_ACCEPTED'
        detail = report(root / 'release110-graphics-build/reports/RESULT.json', status)
        require(detail['stage'] == 'compile' and detail['outputs'], 'Compiled renderer outputs are required')
        archive = root / ('graphics-' + variant + '.tar.gz')
        require(sha(archive) == Path(str(archive) + '.sha256').read_text().split()[0], 'Renderer tar sidecar differs')
        parts = destination.with_name(destination.name + '-' + variant)
        unpack(archive, parts)
        output = destination / architecture; output.mkdir(exist_ok=True)
        selected = set()
        for row in detail['outputs']:
            basename = filename(row['path'])
            require(basename not in selected, 'Duplicate renderer product')
            selected.add(basename)
            source = parts / basename
            require(source.is_file() and not source.is_symlink() and sha(source) == row['sha256'] and
                    source.stat().st_size == row['bytes'], 'Renderer product bytes differ')
            target = output / basename
            require(not target.exists() or sha(target) == row['sha256'], 'Renderer products conflict')
            shutil.copy2(source, target)
        # Copy only declared final outputs; HBDX9's obj/ build directory is not a runtime input.
        details[name] = dict(archive_sha256=sha(archive), files=sorted(selected))
    return details


def indiana(root, destination, unpack):
    paths = list(root.rglob('RESULT.json'))
    matches = [path for path in paths if json.loads(path.read_text()).get('status') == 'INDIANA_SOURCE_BUILT_NOT_RELEASE_ACCEPTED']
    require(len(matches) == 1, 'Exactly one successful Indiana compile report is required')
    detail = report(matches[0], 'INDIANA_SOURCE_BUILT_NOT_RELEASE_ACCEPTED')
    require(detail['build']['status'] == 'INDIANA_SOURCE_BUILT_NOT_RELEASE_ACCEPTED', 'Indiana library was not compiled')
    archive = root / 'c33r-indiana-component.tar.gz'
    require(sha(archive) == Path(str(archive) + '.sha256').read_text().split()[0], 'Indiana tar sidecar differs')
    unpack(archive, destination)
    library = destination / 'libMoltenVK.dylib'
    require(sha(library) == detail['build']['sha256'] and library.stat().st_size == detail['build']['bytes'],
            'Indiana library differs from its source build')
    license_path = destination / 'LICENSE'
    require(license_path.is_file() and not license_path.is_symlink(), 'Indiana Apache license is missing')
    return dict(driver=dict(path=str(library), sha256=sha(library)),
                license=dict(name='moltenvk-LICENSE.txt', path=str(license_path), sha256=sha(license_path)))

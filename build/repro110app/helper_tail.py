"""Shared post-package producer steps; independent cloud diagnosis is not acceptance."""
from pathlib import Path
import re
import shutil
import tarfile

SOURCE_AXES = ('licenses-legendary', 'licenses-gogdl', 'licenses-xdelta3', 'gitlink-gogdl')
BUILD_AXES = ('helper-legendary', 'helper-gogdl', 'runtime-dependency-closure',
              'compiled-python-extensions-architectures', 'helpers-architectures',
              'prefix-hidden-cli', 'licenses-copy', 'archive', 'publish-copy')
AXES = SOURCE_AXES + BUILD_AXES


def gitlink(source, rows, command, work):
    link = command(['/usr/bin/git', '-C', str(source), 'ls-tree', 'HEAD', 'xdelta3'],
                   work, 'gogdl-xdelta-gitlink', 30).decode().split()
    if len(link) != 4 or link[:3] != ['160000', 'commit', rows['xdelta3']['revision']]:
        raise ValueError('Gogdl xdelta3 submodule revision drift')
    return dict(revision=link[2], path=link[3])


def source_axis(axis, rows, work, prefix, checkout, runner, command, mark):
    if axis not in SOURCE_AXES:
        raise ValueError('Unknown source tail axis')
    name = axis.split('-', 1)[1]
    source = work / (name + '-source')
    proof = checkout(rows[name], source)
    if axis == 'gitlink-gogdl':
        proof['gitlink'] = gitlink(source, rows, command, work)
    else:
        mark(axis)
        proof['licenses'] = runner.licenses(source, prefix, name)
    return proof


def helper(name, c, collect_licenses=True):
    row = c.rows[name]; source = c.work / (name + '-source')
    proof = c.checkout(row, source)
    control, field = ('requirements.txt', 'requirements_sha256') if name == 'legendary' else ('pyproject.toml', 'pyproject_sha256')
    c.mark(name + '-source-controls')
    if c.sha(source / control) != row[field]:
        raise ValueError(name + ' source controls drift')
    if name == 'gogdl':
        gitlink(source, c.rows, c.command, c.work)
        proof['xdelta3'] = c.checkout(c.rows['xdelta3'], source / 'xdelta3')
        if collect_licenses:
            c.mark('licenses-xdelta3')
            proof['xdelta3']['licenses'] = c.runner.licenses(source / 'xdelta3', c.prefix, 'xdelta3')
    built = c.package(source, row, collect_licenses=collect_licenses)
    if name == 'gogdl':
        c.command([str(c.python), '-B', '-I', '-c',
                   'import gogdl.xdelta3; print("GOGDL_XDELTA3_IMPORT=PASS")'],
                  c.work, 'gogdl-native-extension-smoke', 120)
    c.mark(name + '-entry-point')
    entry = built['console_scripts'].get(name)
    if not isinstance(entry, str) or not re.fullmatch(r'[A-Za-z_][\w.]*:[A-Za-z_]\w*', entry):
        raise ValueError('Helper console entry point missing or unsafe')
    module, function = entry.split(':')
    script = c.work / (name + '-entry.py')
    script.write_text('from ' + module + ' import ' + function + '\nif __name__ == "__main__":\n    ' + function + '()\n')
    c.command([str(c.python), '-B', '-I', '-m', 'PyInstaller', '--clean', '--noconfirm', '--onefile',
               '--target-architecture', 'arm64', '--name', name, '--distpath', str(c.product),
               '--workpath', str(c.work / (name + '-pyinstaller')), '--specpath', str(c.work),
               '--collect-submodules', name, '--collect-data', 'certifi', str(script)],
              c.work, name + '-freeze', 1200)
    c.command([str(c.product / name), '--help'], c.work, name + '-cli-help', 120)
    proof.update(status='SOURCE_BUILT_CLI_HELP_PASS', version=row['version'],
                 bytes=(c.product / name).stat().st_size, sha256=c.sha(c.product / name))
    if not collect_licenses:
        proof['license_review'] = 'NOT_ENABLED_IN_INDEPENDENT_BUILD_AXIS'
    c.result['helpers'].append(proof); c.save()
    return proof


def archive(c):
    c.mark('archive')
    path = c.work / 'helpers.tar.gz'
    with tarfile.open(path, 'w:gz') as stream:
        for product in sorted(c.product.iterdir()): stream.add(product, arcname=product.name)
    record = dict(name=path.name, bytes=path.stat().st_size, sha256=c.sha(path))
    c.result['archive'] = record
    return path


def final_axis(axis, c):
    c.mark(axis)
    if axis == 'runtime-dependency-closure':
        c.command([str(c.python), '-B', '-I', '-m', 'pip', 'check'], c.work, axis, 120)
    elif axis == 'compiled-python-extensions-architectures':
        c.command(['/usr/bin/python3', '-B', '-I', str(c.here / 'check-macho-arch.py'), str(c.prefix)], c.work, axis, 120)
    elif axis == 'helpers-architectures':
        c.command(['/usr/bin/python3', '-B', '-I', str(c.here / 'check-macho-arch.py'), str(c.product)], c.work, axis, 120)
    elif axis == 'prefix-hidden-cli':
        c.portable_cli(c.prefix, c.product, c.command)
    elif axis == 'licenses-copy':
        shutil.copytree(c.prefix / 'share/licenses', c.product / 'licenses')
    elif axis in ('archive', 'publish-copy'):
        if not (c.product / 'licenses').exists():
            final_axis('licenses-copy', c)
        path = archive(c)
        if axis == 'publish-copy':
            c.mark('publish-copy')
            c.publish_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, c.publish_dir / path.name)
            if c.sha(c.publish_dir / path.name) != c.sha(path):
                raise ValueError('Published helper archive copy differs')
    else:
        raise ValueError('Unknown final tail axis')


def run(c, axis=None):
    if axis is not None and axis not in BUILD_AXES:
        raise ValueError('Unknown compiled tail axis')
    # License cells run independently, so a license refusal cannot hide compilation
    # and finalization errors. These outputs never receive full helper acceptance.
    names = [axis[7:]] if axis and axis.startswith('helper-') else ['legendary', 'gogdl']
    for name in names:
        helper(name, c, collect_licenses=axis is None)
    if axis is None:
        for stage in BUILD_AXES[2:7]:
            final_axis(stage, c)
        final_axis('publish-copy', c)
    elif not axis.startswith('helper-'):
        final_axis(axis, c)

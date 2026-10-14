#!/usr/bin/env python3
"""Bottle input catalogues of the previous releases, taken from the published release archives (REPRO-110).

The app updates a bottle that an earlier release prepared by difference. For that it needs the engine manifest (ENGINE.json)
of the release named by the bottle's stamp, and it finds it in its own resources as bottle-inputs-<SHA-256 of that manifest>.json
(BottleSetup.updateByDifference). The accepted composition carries those files ready-made. This step produces the same files
from the published archives: it downloads each pinned release archive, checks its size and SHA-256, takes the single
Contents/Resources/engine/ENGINE.json inside, checks the manifest's SHA-256, name and shape, and writes it under its
content-addressed name. Any difference refuses with the name and digest that were found.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
LOCK = HERE / 'bottle-catalogues.lock.json'
RESOURCES = 'Sources/MacRunnerControlCenter/Resources/BottleCatalogues'
MAX_MANIFEST = 8 * 1024 * 1024


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def read_lock(path=LOCK):
    lock = json.loads(Path(path).read_bytes())
    require(lock.get('schema') == 1 and lock.get('destination') == RESOURCES and lock.get('catalogues'), 'Catalogue lock differs')
    seen = set()
    for row in lock['catalogues']:
        for key in ('asset_sha256', 'catalogue_sha256'):
            require(isinstance(row.get(key), str) and len(row[key]) == 64 and set(row[key]) <= set('0123456789abcdef'),
                    'Unpinned catalogue digest')
        require(row['url'] == 'https://github.com/t0b1kent/macrunner-app/releases/download/%s/%s' % (row['tag'], row['asset']),
                'Foreign release URL')
        require(row['catalogue_sha256'] not in seen, 'Duplicate catalogue')
        seen.add(row['catalogue_sha256'])
    return lock


def curl_download(row, destination):
    done = subprocess.run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error', '--proto', '=https',
                           '--output', str(destination), row['url']], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                          timeout=1800)
    require(done.returncode == 0, 'Release download failed: ' + row['asset'] + ': ' + done.stderr[-300:])


def extract_manifest(archive, row):
    """The single engine manifest of a release archive, after the archive's own size and digest were checked."""
    archive = Path(archive)
    require(archive.stat().st_size == row['asset_bytes'] and sha_file(archive) == row['asset_sha256'],
            'Release archive differs from the pin: ' + row['asset'])
    with zipfile.ZipFile(archive) as stream:
        names = [n for n in stream.namelist() if n.endswith('/' + row['member_suffix'])]
        require(len(names) == 1, 'Expected one engine manifest in %s, found %d' % (row['asset'], len(names)))
        info = stream.getinfo(names[0])
        require(0 < info.file_size <= MAX_MANIFEST, 'Engine manifest size is out of bounds')
        data = stream.read(names[0])
    found = sha_bytes(data)
    try:
        manifest = json.loads(data)
    except ValueError:
        raise ValueError('Engine manifest of %s is not JSON (sha256 %s)' % (row['asset'], found))
    require(found == row['catalogue_sha256'] and manifest.get('name') == row['engine_name'],
            'Engine manifest of %s differs from the pin: name=%r sha256=%s' % (row['asset'], manifest.get('name'), found))
    require(manifest.get('schema') == row['schema'] and 'graphics' in manifest and isinstance(manifest.get('files'), (dict, list)),
            'Engine manifest shape differs: ' + row['asset'])
    return data


def install(destination_root, work, lock=None, download=curl_download):
    """Write the catalogues below destination_root/<RESOURCES>; return one report row per catalogue."""
    lock = lock or read_lock()
    target = Path(destination_root) / lock['destination']
    target.mkdir(parents=True, exist_ok=True)
    work = Path(work)
    work.mkdir(parents=True, exist_ok=True)
    report = []
    for row in lock['catalogues']:
        out = target / ('bottle-inputs-' + row['catalogue_sha256'] + '.json')
        require(not out.exists(), 'Catalogue already present: ' + out.name)
        archive = work / row['asset']
        require(not archive.exists(), 'Fresh archive path required')
        download(row, archive)
        data = extract_manifest(archive, row)
        out.write_bytes(data)
        report.append(dict(tag=row['tag'], asset=row['asset'], asset_sha256=row['asset_sha256'], engine_name=row['engine_name'],
                           catalogue=out.name, catalogue_bytes=len(data), catalogue_sha256=sha_bytes(data)))
        archive.unlink()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--plan', action='store_true')
    actions.add_argument('--check', action='store_true', help='Download, verify and write the catalogues below --work/catalogues')
    parser.add_argument('--work', type=Path)
    args = parser.parse_args()
    lock = read_lock()
    if args.plan:
        print(json.dumps(dict(status='BOTTLE_CATALOGUES_PLANNED_NOT_FETCHED',
                              catalogues=[(r['tag'], r['catalogue_sha256'][:12]) for r in lock['catalogues']]), sort_keys=True))
        return 0
    require(args.work is not None and not args.work.exists(), 'Fresh --work required')
    args.work.mkdir(parents=True)
    result = dict(schema=1, status='STARTED', first_failure=None, catalogues=[])
    try:
        result['catalogues'] = install(args.work / 'catalogues', args.work / 'archives', lock)
        result['status'] = 'BOTTLE_CATALOGUES_VERIFIED'
    except Exception as error:
        result.update(status='FAILED', first_failure=dict(error=str(error)[:1200]))
        raise
    finally:
        (args.work / 'RESULT.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
        print(json.dumps({k: result[k] for k in ('status', 'first_failure')}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired, zipfile.BadZipFile) as exc:
        print('REFUSED: ' + str(exc), file=sys.stderr)
        sys.exit(2)

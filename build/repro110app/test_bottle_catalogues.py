"""Offline controls for the bottle catalogue step (synthetic release archives only; nothing is downloaded)."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import bottle_catalogues as step


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Fixture(unittest.TestCase):
    def setUp(self):
        root = os.environ.get('REPRO109_TEST_TMP')
        if not root or not Path(root).is_dir():
            raise RuntimeError('REPRO109_TEST_TMP must name an owned existing fixture root')
        self.temp = tempfile.TemporaryDirectory(prefix='catalogues-', dir=root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def release(self, name='MacRunner 9.9 test', schema=2, extra_member=False, graphics=True):
        manifest = {'schema': schema, 'name': name, 'files': {'a': 1}}
        if graphics:
            manifest['graphics'] = {}
        data = json.dumps(manifest, sort_keys=True).encode()
        archive = self.root / 'release.zip'
        with zipfile.ZipFile(archive, 'w') as stream:
            stream.writestr('MacRunner.app/Contents/Resources/engine/ENGINE.json', data)
            if extra_member:
                stream.writestr('Other.app/Contents/Resources/engine/ENGINE.json', data)
        row = dict(tag='v9.9', asset='release.zip', asset_bytes=archive.stat().st_size, asset_sha256=step.sha_file(archive),
                   url='https://github.com/t0b1kent/macrunner-app/releases/download/v9.9/release.zip',
                   member_suffix='Contents/Resources/engine/ENGINE.json', engine_name=name,
                   catalogue_sha256=sha(data), catalogue_bytes=len(data), schema=schema)
        lock = dict(schema=1, destination=step.RESOURCES, catalogues=[row])
        return lock, row, data, archive

    def fake_download(self, source):
        def download(row, destination):
            Path(destination).write_bytes(source.read_bytes())
        return download


class CatalogueStep(Fixture):
    def test_the_manifest_is_written_under_its_content_address(self):
        lock, row, data, archive = self.release()
        report = step.install(self.root / 'tree', self.root / 'work', lock, self.fake_download(archive))
        out = self.root / 'tree' / step.RESOURCES / ('bottle-inputs-' + sha(data) + '.json')
        self.assertEqual(out.read_bytes(), data)
        self.assertEqual(report[0]['catalogue_sha256'], sha(data))
        self.assertFalse((self.root / 'work/release.zip').exists())

    def test_wrong_archive_digest_wrong_manifest_name_and_extra_members_are_refused(self):
        lock, row, data, archive = self.release()
        bad = dict(lock, catalogues=[dict(row, asset_sha256='0' * 64)])
        with self.assertRaisesRegex(ValueError, 'archive differs'):
            step.install(self.root / 't1', self.root / 'w1', bad, self.fake_download(archive))
        bad = dict(lock, catalogues=[dict(row, engine_name='Another name')])
        with self.assertRaisesRegex(ValueError, 'differs from the pin: name='):
            step.install(self.root / 't2', self.root / 'w2', bad, self.fake_download(archive))
        bad = dict(lock, catalogues=[dict(row, catalogue_sha256='1' * 64)])
        with self.assertRaisesRegex(ValueError, 'differs from the pin'):
            step.install(self.root / 't3', self.root / 'w3', bad, self.fake_download(archive))
        lock2, row2, data2, archive2 = self.release(extra_member=True)
        with self.assertRaisesRegex(ValueError, 'found 2'):
            step.install(self.root / 't4', self.root / 'w4', lock2, self.fake_download(archive2))

    def test_shape_and_existing_target_are_refused(self):
        lock, row, data, archive = self.release(graphics=False)
        with self.assertRaisesRegex(ValueError, 'shape'):
            step.install(self.root / 't5', self.root / 'w5', lock, self.fake_download(archive))
        lock, row, data, archive = self.release()
        (self.root / 't6' / step.RESOURCES).mkdir(parents=True)
        (self.root / 't6' / step.RESOURCES / ('bottle-inputs-' + sha(data) + '.json')).write_bytes(b'{}')
        with self.assertRaisesRegex(ValueError, 'already present'):
            step.install(self.root / 't6', self.root / 'w6', lock, self.fake_download(archive))


class RealLock(unittest.TestCase):
    def test_lock_pins_two_releases_with_distinct_catalogues_and_the_official_urls(self):
        lock = step.read_lock()
        self.assertEqual([r['tag'] for r in lock['catalogues']], ['v1.0.9', 'v1.0.8'])
        self.assertEqual([r['catalogue_sha256'][:8] for r in lock['catalogues']], ['09fe4a42', 'b4a31678'])

    def test_a_lock_with_a_foreign_url_is_refused(self):
        lock = json.loads(step.LOCK.read_bytes())
        lock['catalogues'][0]['url'] = 'https://example.invalid/x.zip'
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'lock.json'
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, 'Foreign release URL'):
                step.read_lock(path)


class ProducerHook(unittest.TestCase):
    def test_the_producer_installs_the_catalogues_after_preparation_and_before_swift(self):
        text = (HERE / 'build_source.py').read_text()
        self.assertLess(text.index('preparation = prepared.prepare('), text.index("install_bottle_catalogues(app_work / 'app'"))
        self.assertLess(text.index("install_bottle_catalogues(app_work / 'app'"), text.index("swift = output(['/usr/bin/xcrun'"))

    def test_without_the_lock_the_hook_does_nothing_and_never_touches_the_network(self):
        spec = __import__('importlib.util').util.spec_from_file_location('bs_under_test', HERE / 'build_source.py')
        module = __import__('importlib.util').util.module_from_spec(spec)
        spec.loader.exec_module(module)
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp, patch.object(module, 'HERE', Path(tmp)):
            self.assertEqual(module.install_bottle_catalogues(Path(tmp) / 'tree', Path(tmp) / 'archives'), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)

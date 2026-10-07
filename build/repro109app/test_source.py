#!/usr/bin/env python3
"""Offline real preparation controls; frameworks here are inert own fixtures."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('app_source_prepare', HERE / 'prepare_source.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class SourceControls(unittest.TestCase):
    def setUp(self):
        # Keep all fixture bytes in the selected checkout, never on the internal disk.
        scratch = HERE / '.source-controls'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='own-', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lock = json.loads((HERE / 'source.lock.json').read_text())
        self.module = p.framework_module(self.lock)

    def source_copy(self):
        destination = self.root / 'source'
        shutil.copytree(HERE / 'source', destination)
        return destination

    def framework_fixture(self):
        work = self.root / 'frameworks-work'
        prefix = work / 'prefix'
        prefix.mkdir(parents=True)
        components = []
        for row in self.module.read_lock()['components']:
            product = prefix / row['product']
            binaries = []
            for name in row['required_binaries']:
                target = product / name
                target.parent.mkdir(parents=True, exist_ok=True)
                # Inert bytes, not an executable and not any third-party file.
                target.write_bytes(bytes.fromhex('cffaedfe0c000001') + bytes(24) +
                                   b'OWN-OFFLINE-FIXTURE-' + name.encode())
                binaries.append(dict(path=name, sha256=p.sha(target), bytes=target.stat().st_size,
                                     architecture='arm64'))
            version = row['required_binaries'][0].split('/')[1]
            resources = product / 'Versions' / version / 'Resources'
            resources.mkdir(parents=True)
            (resources / 'Info.plist').write_bytes(plistlib.dumps(
                dict(CFBundleShortVersionString=row['version'])))
            (product / 'Versions/Current').symlink_to(version, target_is_directory=True)
            (product / row['target']).symlink_to('Versions/Current/' + row['target'])
            xc = prefix / (row['target'] + '.xcframework')
            xc.mkdir()
            shutil.copytree(product, xc / 'macos-arm64' / row['product'], symlinks=True)
            (xc / 'Info.plist').write_bytes(plistlib.dumps(dict(AvailableLibraries=[dict(
                LibraryIdentifier='macos-arm64', LibraryPath=row['product'],
                SupportedPlatform='macos', SupportedArchitectures=['arm64'])])))
            components.append(dict(name=row['name'], status='BUILT', revision=row['revision'],
                                   version=row['version'], binaries=binaries,
                                   compiled_paths=len(binaries), xcframework=xc.name))
        receipt = dict(status='FRAMEWORKS_SOURCE_BUILT_NOT_R2_COMPARED',
                       driver_sha256=self.lock['frameworks_recipe']['driver_sha256'],
                       lock_sha256=self.lock['frameworks_recipe']['lock_sha256'],
                       components=components, prefix_inventory=p.prefix_inventory(prefix), install_skipped=0)
        (work / 'reports').mkdir()
        self.save_receipt(work, receipt)
        return work

    def save_receipt(self, work, value):
        (work / 'reports/RESULT.json').write_text(json.dumps(value))

    def receipt(self, work):
        return json.loads((work / 'reports/RESULT.json').read_text())

    def test_exact_published_source_inventory_and_fixture(self):
        measured = p.verify_source(HERE / 'source', self.lock)
        self.assertEqual((measured['files'], measured['bytes']), (375, 4147584))
        data = p.fixture_bytes(self.lock)
        self.assertEqual(hashlib.sha256(data).hexdigest(),
                         '8c2a2f7328e85fc0868e174dd80057bbb9e136b5229d8d6f3ed316c67f37cd3b')

    def test_changed_source_and_executable_mode_refused(self):
        source = self.source_copy()
        target = source / 'Package.swift'
        target.write_bytes(target.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, 'differs from release'):
            p.verify_source(source, self.lock)
        shutil.copy2(HERE / 'source/Package.swift', target)
        target.chmod(target.stat().st_mode ^ 0o100)
        with self.assertRaisesRegex(ValueError, 'differs from release'):
            p.verify_source(source, self.lock)

    def test_source_images_restore_exact_original_bytes(self):
        restored = p.asset_bytes(HERE / 'source', self.lock)
        self.assertEqual(set(restored), {'scripts/assets/AppIcon-1024.png', 'scripts/assets/AppIcon.icns'})
        self.assertEqual(hashlib.sha256(restored['scripts/assets/AppIcon-1024.png']).hexdigest(),
                         '8fa609abef3ccfa1902a25e66bab03eff241288e87e105773107d998fe155f7e')
        self.assertEqual(hashlib.sha256(restored['scripts/assets/AppIcon.icns']).hexdigest(),
                         'be217c11f738543abc74fc4f65bd143fd881cd4d09bbf832039aa0eaefce57ab')

    def test_source_asset_census_destination_and_size_refused(self):
        for mutate in [lambda d: d['encoded_assets'].pop(),
                       lambda d: d['encoded_assets'].append(copy.deepcopy(d['encoded_assets'][0])),
                       lambda d: d['encoded_assets'][0].update(path='../escape.png'),
                       lambda d: d['encoded_assets'][0].update(encoded_path='../escape.b64'),
                       lambda d: d['encoded_assets'][0].update(bytes=True),
                       lambda d: d['encoded_assets'][0].update(bytes=4 * 1024 * 1024 + 1)]:
            with self.subTest(mutate=mutate):
                lock = copy.deepcopy(self.lock)
                mutate(lock)
                with self.assertRaisesRegex(ValueError, 'Source asset'):
                    p.asset_bytes(HERE / 'source', lock)

    def test_corrupt_asset_refused_before_frameworks_or_output(self):
        source = self.source_copy()
        asset = source / self.lock['encoded_assets'][0]['encoded_path']
        asset.write_bytes(b'INVALID!')
        with self.assertRaisesRegex(ValueError, 'encoding differs'):
            p.asset_bytes(source, self.lock)
        shutil.copy2(HERE / 'source' / self.lock['encoded_assets'][0]['encoded_path'], asset)
        lock = copy.deepcopy(self.lock)
        lock['encoded_assets'][0]['sha256'] = '0' * 64
        output = self.root / 'asset-refused-output'
        with self.assertRaisesRegex(ValueError, 'asset bytes differ'):
            p.prepare(source, output, self.root / 'not-built-frameworks', lock)
        self.assertFalse(output.exists())

    def test_source_asset_symlink_refused(self):
        source = self.source_copy()
        asset = source / self.lock['encoded_assets'][0]['encoded_path']
        asset.unlink()
        asset.symlink_to(HERE / 'source' / self.lock['encoded_assets'][0]['encoded_path'])
        with self.assertRaisesRegex(ValueError, 'asset file differs'):
            p.asset_bytes(source, self.lock)

    def test_source_missing_extra_symlink_and_compiled_refused(self):
        source = self.source_copy()
        extra = source / 'unexpected'
        extra.write_text('own fixture')
        with self.assertRaisesRegex(ValueError, 'differs from release'):
            p.verify_source(source, self.lock)
        extra.unlink()
        extra.symlink_to(self.root / 'absent')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            p.verify_source(source, self.lock)
        extra.unlink()
        extra.write_bytes(b'MZOWN-FIXTURE')
        with self.assertRaisesRegex(ValueError, 'Compiled input'):
            p.verify_source(source, self.lock)
        extra.unlink()
        (source / 'Package.swift').unlink()
        with self.assertRaisesRegex(ValueError, 'differs from release'):
            p.verify_source(source, self.lock)

    def test_framework_status_pin_and_count_refused(self):
        work = self.framework_fixture()
        good = self.receipt(work)
        for field, value in [('status', 'FAILED'), ('driver_sha256', '0' * 64),
                             ('lock_sha256', '1' * 64), ('components', {}),
                             ('install_skipped', None)]:
            bad = copy.deepcopy(good)
            bad[field] = value
            self.save_receipt(work, bad)
            with self.assertRaises(ValueError):
                p.verify_frameworks(work, self.lock, self.module)

    def test_wrong_component_revision_and_partial_component_refused(self):
        work = self.framework_fixture()
        good = self.receipt(work)
        for field, value in [('revision', '0' * 40), ('status', 'FAILED'), ('version', '0.0.0')]:
            bad = copy.deepcopy(good)
            bad['components'][0][field] = value
            self.save_receipt(work, bad)
            with self.assertRaisesRegex(ValueError, 'identity or status'):
                p.verify_frameworks(work, self.lock, self.module)

    def test_nested_helper_drift_refused_without_creating_workspace(self):
        work = self.framework_fixture()
        row = self.module.read_lock()['components'][0]
        helper = work / 'prefix' / row['product'] / row['required_binaries'][-1]
        helper.write_bytes(helper.read_bytes() + b'DRIFT')
        output = self.root / 'output'
        with self.assertRaisesRegex(ValueError, 'prefix bytes differ'):
            p.prepare(HERE / 'source', output, work, self.lock)
        self.assertFalse(output.exists())

    def test_xcframework_transport_architecture_and_path_refused(self):
        work = self.framework_fixture()
        good = self.receipt(work)
        info = work / 'prefix/Sparkle.xcframework/Info.plist'
        original = plistlib.loads(info.read_bytes())
        for field, value in [('SupportedArchitectures', ['x86_64']),
                             ('LibraryPath', '../outside.framework'), ('SupportedPlatform', 'ios')]:
            bad = copy.deepcopy(original)
            bad['AvailableLibraries'][0][field] = value
            info.write_bytes(plistlib.dumps(bad))
            adjusted = copy.deepcopy(good)
            adjusted['prefix_inventory'] = p.prefix_inventory(work / 'prefix')
            self.save_receipt(work, adjusted)
            with self.assertRaises(ValueError):
                p.verify_frameworks(work, self.lock, self.module)
        info.write_bytes(plistlib.dumps(original))
        copied = work / 'prefix/Sparkle.xcframework/macos-arm64/Sparkle.framework/Versions/B/Sparkle'
        copied.write_bytes(copied.read_bytes() + b'DRIFT')
        good['prefix_inventory'] = p.prefix_inventory(work / 'prefix')
        self.save_receipt(work, good)
        with self.assertRaisesRegex(ValueError, 'transport differs'):
            p.verify_frameworks(work, self.lock, self.module)

    def test_prefix_extra_and_escaping_symlink_refused(self):
        work = self.framework_fixture()
        extra = work / 'prefix/unreceipted.txt'
        extra.write_text('own fixture')
        with self.assertRaisesRegex(ValueError, 'prefix bytes differ'):
            p.verify_frameworks(work, self.lock, self.module)
        extra.unlink()
        extra.symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'symlink escapes'):
            p.verify_frameworks(work, self.lock, self.module)

    def test_real_preparation_preserves_inputs_symlinks_and_generated_bytes(self):
        work = self.framework_fixture()
        before = p.verify_source(HERE / 'source', self.lock)
        receipt = self.receipt(work)
        receipt['install_skipped'] = 2
        self.save_receipt(work, receipt)
        output = self.root / 'output'
        result = p.prepare(HERE / 'source', output, work, self.lock)
        self.assertEqual(result['frameworks']['compiled_paths'], 6)
        self.assertEqual(result['install_skipped'], 2)
        self.assertEqual(result['app_build'], 'NOT_ENABLED')
        self.assertEqual(set(result['runtime_inputs'].values()), {'NOT_ENABLED'})
        self.assertEqual(p.verify_source(HERE / 'source', self.lock), before)
        self.assertEqual((output / 'app/Tests/Fixtures/test-pe.exe').read_bytes(), p.fixture_bytes(self.lock))
        for name, image in p.asset_bytes(HERE / 'source', self.lock).items():
            self.assertEqual((output / 'app' / name).read_bytes(), image)
        self.assertEqual(result['restored_assets'], self.lock['encoded_assets'])
        self.assertEqual(p.prefix_inventory(output / 'app/Frameworks'), p.prefix_inventory(work / 'prefix'))
        self.assertTrue((output / 'app/Frameworks/Sparkle.framework/Versions/Current').is_symlink())
        self.assertEqual((output / 'app/scripts/app32-gate.sh').read_text(), p.PORTABLE_GATE)
        self.assertEqual(json.loads((output / 'PREPARED.json').read_text()), result)

    def test_existing_output_and_overlapping_inputs_refused(self):
        work = self.framework_fixture()
        output = self.root / 'existing'
        output.mkdir()
        with self.assertRaisesRegex(ValueError, 'Fresh'):
            p.prepare(HERE / 'source', output, work, self.lock)
        with self.assertRaisesRegex(ValueError, 'overlaps'):
            p.prepare(HERE / 'source', work / 'nested', work, self.lock)
        self.assertFalse((work / 'nested').exists())

    def test_portable_gate_executes_only_selected_own_fixture_checkout(self):
        repo = self.root / 'selected'
        (repo / 'config').mkdir(parents=True)
        (repo / 'config/env.sh').write_text('export OWN_FIXTURE_ENV=YES\n')
        probe = repo / 'scripts/probes/app32/gate.py'
        probe.parent.mkdir(parents=True)
        probe.write_text('import os,sys\n'
                         'assert os.environ["OWN_FIXTURE_ENV"] == "YES"\n'
                         'assert sys.argv[1:] == ["own-fixture"]\n'
                         'print("OWN_SELECTED_GATE_PASS")\n')
        script = self.root / 'portable-gate.sh'
        script.write_text(p.PORTABLE_GATE)
        env = dict(PATH='/usr/bin:/bin', MACRUNNER_ROOT=str(repo))
        r = subprocess.run(['/bin/bash', str(script), 'own-fixture'], env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), 'OWN_SELECTED_GATE_PASS')
        env.pop('MACRUNNER_ROOT')
        r = subprocess.run(['/bin/bash', str(script)], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=15)
        self.assertNotEqual(r.returncode, 0)

    def test_real_cli_host_refusal_creates_no_output(self):
        output = self.root / 'must-not-exist'
        env = dict(os.environ)
        env.pop('CI_XCODE_CLOUD', None)
        r = subprocess.run([sys.executable, '-B', '-I', str(HERE / 'prepare_source.py'), '--prepare',
                            '--work', str(output), '--framework-work', str(self.root / 'absent')],
                           env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 2)
        self.assertIn('Xcode Cloud ARM64 only', r.stderr)
        self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)

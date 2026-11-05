"""Own source-only BottleTools producer and resource-completeness controls."""
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_bottle_tools as producer


class BottleToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'; self.source.mkdir()
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.lock = {'schema': 1, 'tools': []}
        for name in ['checked-registration.c', 'device-refresh.c', 'checked-registration.inf']:
            (self.source / name).write_text('own inert source fixture\n')
        rows = [(producer.NAMES[0], 'aarch64-w64-mingw32-clang', 0xaa64, 'checked-registration.c'),
                (producer.NAMES[1], 'i686-w64-mingw32-clang', 0x14c, 'checked-registration.c'),
                (producer.NAMES[2], 'aarch64-w64-mingw32-clang', 0xaa64, 'device-refresh.c')]
        for name, driver, machine, source in rows:
            (self.bin / driver).touch()
            self.lock['tools'].append(dict(name=name, driver=driver, machine=machine, source=source,
                source_sha256=producer.sha(self.source / source), argv=['-O2'], reference_sha256='0' * 64))
        self.lock['inf'] = dict(name=producer.NAMES[3], source=producer.NAMES[3],
                               source_sha256=producer.sha(self.source / producer.NAMES[3]))
        self.calls = []

    def compiler(self, argv, log):
        self.calls.append(argv)
        machine = 0x14c if Path(argv[0]).name.startswith('i686') else 0xaa64
        data = bytearray(256); data[:2] = b'MZ'
        struct.pack_into('<I', data, 0x3c, 128); data[128:132] = b'PE\0\0'
        struct.pack_into('<H', data, 132, machine)
        Path(argv[-1]).write_bytes(data)
        Path(log).write_text('own inert compiler fixture\n')

    def build(self):
        return producer.build(self.source, self.root / 'work', self.bin, self.lock, self.compiler)

    def test_builds_both_registration_views_and_device_helper_with_inf(self):
        result = self.build()
        self.assertEqual(result['status'], 'BOTTLE_TOOLS_SOURCE_BUILT')
        self.assertEqual(set(result['files']), set(producer.NAMES))
        self.assertEqual([item['machine'] for item in result['tools']], [0xaa64, 0x14c, 0xaa64])
        self.assertEqual(len(self.calls), 3)

    def test_pinned_original_sources_and_toolchain_cover_the_complete_family(self):
        lock = producer.read_lock()
        for row in [*lock['tools'], lock['inf']]:
            self.assertTrue(producer.checked_source(producer.HERE / 'bottle-tools', row).is_file())

    def test_missing_inf_refuses_before_any_compiler(self):
        (self.source / producer.NAMES[3]).unlink()
        with self.assertRaisesRegex(ValueError, 'missing'):
            self.build()
        self.assertEqual(self.calls, [])

    def test_changed_source_refuses_before_any_compiler(self):
        (self.source / 'checked-registration.c').write_text('changed own fixture\n')
        with self.assertRaisesRegex(ValueError, 'differs from the pin'):
            self.build()
        self.assertEqual(self.calls, [])

    def test_wrong_native_machine_is_not_a_source_built_helper(self):
        self.lock['tools'][0]['machine'] = 0x8664
        with self.assertRaisesRegex(ValueError, 'PE machine differs'):
            self.build()
        report = json.loads((self.root / 'work/RESULT.json').read_text())
        self.assertEqual(report['status'], 'FAILED')

    def test_install_supports_flat_and_macos_resource_bundle_layouts(self):
        result = self.build()
        for nested in [False, True]:
            app = self.root / ('nested.app' if nested else 'flat.app')
            bundle = app / 'Contents/Resources' / producer.BUNDLE
            target = bundle / 'Contents/Resources' if nested else bundle
            target.mkdir(parents=True)
            receipt = producer.install(self.root / 'work', app)
            self.assertEqual(receipt['status'], 'BOTTLE_TOOLS_SOURCE_BUILT_AND_PLACED')
            for name in producer.NAMES:
                self.assertEqual(producer.sha(target / name), result['files'][name]['sha256'])

    def test_install_refuses_missing_family_member(self):
        self.build()
        path = self.root / 'work/RESULT.json'; result = json.loads(path.read_text())
        result['files'].pop(producer.NAMES[1]); path.write_text(json.dumps(result))
        with self.assertRaisesRegex(ValueError, 'Complete source-built'):
            producer.install(self.root / 'work', self.root / 'app')

    def test_install_refuses_drift_and_broken_target_symlink(self):
        self.build()
        app = self.root / 'app'; target = app / 'Contents/Resources' / producer.BUNDLE
        target.mkdir(parents=True)
        (target / producer.NAMES[0]).symlink_to(self.root / 'absent')
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            producer.install(self.root / 'work', app)
        self.assertFalse((self.root / 'absent').exists())
        (self.root / 'work/outputs' / producer.NAMES[1]).write_bytes(b'changed own fixture')
        other = self.root / 'other.app'
        (other / 'Contents/Resources' / producer.BUNDLE).mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, 'drifted'):
            producer.install(self.root / 'work', other)


if __name__ == '__main__':
    unittest.main()

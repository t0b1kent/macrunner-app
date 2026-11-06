"""Package path mapping and loader layout against inert PE and Mach-O files."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('release_preparation', HERE / 'assemble_release.py')
producer = importlib.util.module_from_spec(spec); spec.loader.exec_module(producer)

PREFIX = b'/test-ci/home'
LOADER_PATHS = b'/wine-loader/MacRunner Wine Loader.app/Contents/MacOS\0engine/wine/lib/wine/aarch64-unix/ntdll.so'


def macho(payload=PREFIX, identity='app.macrunner.wineloader'):
    info = plistlib.dumps(dict(CFBundleIdentifier=identity, CFBundleExecutable='wineloader',
                              GCSupportsGameMode=True, LSSupportsGameMode=True))
    data = bytearray(2048)
    struct.pack_into('<IIIIIIII', data, 0, 0xfeedfacf, 0x100000c, 0, 2, 1, 312, 0, 0)
    struct.pack_into('<II', data, 32, 0x19, 312)
    struct.pack_into('<I', data, 96, 3)
    for i, (name, offset, value, flags) in enumerate([
            ('__text', 512, b'CODE', 0x80000400), ('__cstring', 600, payload, 0),
            ('__info_plist', 768, info, 0)]):
        at = 104 + i * 80
        data[at:at + len(name)] = name.encode()
        data[at + 16:at + 22] = b'__TEXT'
        struct.pack_into('<Q', data, at + 40, len(value))
        struct.pack_into('<I', data, at + 48, offset)
        struct.pack_into('<I', data, at + 64, flags)
        data[offset:offset + len(value)] = value
    return bytes(data)


def pe(payload=PREFIX):
    data = bytearray(1024); data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 128); data[128:132] = b'PE\0\0'
    struct.pack_into('<H', data, 134, 2)
    for i, (name, offset, value, flags) in enumerate([
            ('.text', 512, b'CODE', 0x20000000), ('.rdata', 600, payload, 0x40000000)]):
        at = 152 + i * 40
        data[at:at + len(name)] = name.encode()
        struct.pack_into('<II', data, at + 16, len(value), offset)
        struct.pack_into('<I', data, at + 36, flags)
        data[offset:offset + len(value)] = value
    return bytes(data)


class ReleasePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_release_wine_selection_retains_dependency_inputs_and_matches_recipe(self):
        pins = json.loads((HERE / 'release-inputs.lock.json').read_text())
        old_inputs = dict(wine={'revision': 'old'}, deps={'revision': 'deps'}, llvm={'revision': 'llvm'})
        transport = SimpleNamespace(INPUTS=old_inputs)
        producer.select_wine_source(transport, pins['wine'])
        self.assertEqual(transport.INPUTS['wine'], pins['wine'])
        self.assertEqual(transport.INPUTS['deps'], old_inputs['deps'])
        self.assertEqual(transport.INPUTS['llvm'], old_inputs['llvm'])
        self.assertEqual(old_inputs['wine'], {'revision': 'old'})
        workflow = (HERE.parents[1] / '.github/workflows/repro110-app-c12-source-xcode27-arm64.yml').read_text()
        self.assertIn('ref: ' + pins['wine']['revision'] + '\n          path: wine\n', workflow)
        with self.assertRaisesRegex(ValueError, 'repository differs'):
            producer.select_wine_source(transport, dict(pins['wine'], repo='invalid/repository'))

    def helper_compiler_fixture(self):
        work = self.root / 'helpers'
        binary_dir = work / 'llvm-mingw/pinned/bin'
        binary_dir.mkdir(parents=True)
        (binary_dir / 'x86_64-w64-mingw32-clang').write_bytes(b'fixture compiler')
        compiler = json.loads((HERE / 'engine-tools.lock.json').read_bytes())['tools'][0]['compiler']
        return work, binary_dir, dict(pe_toolchain=dict(bin=str(binary_dir), compiler=compiler,
                                                       provenance='PINNED_ARCHIVE'))

    def test_helper_compiler_keeps_its_independent_pin(self):
        work, binary_dir, report = self.helper_compiler_fixture()
        self.assertEqual(producer.selected_helper_compiler(report, work), binary_dir)

    def test_new_wine_compiler_and_unverified_supplied_bin_are_refused_for_helpers(self):
        work, _, report = self.helper_compiler_fixture()
        report['pe_toolchain']['compiler'] = dict(report['pe_toolchain']['compiler'], clang='23.1.1')
        with self.assertRaisesRegex(ValueError, 'independent pinned archive'):
            producer.selected_helper_compiler(report, work)
        work_report = json.loads((HERE / 'engine-tools.lock.json').read_bytes())['tools'][0]['compiler']
        report['pe_toolchain'].update(compiler=work_report, provenance='SUPPLIED_BIN')
        with self.assertRaisesRegex(ValueError, 'independent pinned archive'):
            producer.selected_helper_compiler(report, work)

    def test_helper_compiler_cannot_escape_owned_work_or_omit_driver(self):
        work, binary_dir, report = self.helper_compiler_fixture()
        with self.assertRaisesRegex(ValueError, 'owned build directory'):
            producer.selected_helper_compiler(report, self.root / 'wine-compiler')
        (binary_dir / 'x86_64-w64-mingw32-clang').unlink()
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            producer.selected_helper_compiler(report, work)

    def test_macho_pe_and_json_mapping_preserves_code_and_originals(self):
        app = self.root / 'App'; app.mkdir()
        for name, value in [('native', macho()), ('guest.dll', pe()),
                            ('ENGINE.json', json.dumps({'path': PREFIX.decode()}).encode())]:
            (app / name).write_bytes(value)
        rows = producer.map_ci_paths(app, self.root / 'backup', old=PREFIX)
        self.assertEqual(len(rows), 3)
        for row in rows:
            old = (self.root / 'backup' / row['path']).read_bytes()
            new = (app / row['path']).read_bytes()
            self.assertIn(PREFIX, old); self.assertNotIn(PREFIX, new)
            self.assertEqual(len(old), len(new)); self.assertTrue(row['code_equal'])

    def test_mapping_inside_executable_code_is_refused_without_replacement(self):
        app = self.root / 'App'; app.mkdir()
        data = bytearray(macho())
        struct.pack_into('<Q', data, 104 + 40, len(PREFIX))
        data[512:512 + len(PREFIX)] = PREFIX
        target = app / 'native'; target.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'changed executable sections'):
            producer.map_ci_paths(app, self.root / 'backup', old=PREFIX)
        self.assertEqual(target.read_bytes(), data)

    def test_source_loader_bundle_uses_its_own_binary_and_preserves_alias_inputs(self):
        app = self.root / 'App'
        wine = app / 'Contents/Resources/engine/wine'
        source = wine / 'lib/wine/aarch64-unix/wine'; source.parent.mkdir(parents=True)
        binary = macho(payload=LOADER_PATHS)
        source.write_bytes(binary); source.chmod(0o755)
        shim = wine / 'bin/wine'; shim.parent.mkdir(); shim.write_bytes(b'original shim')
        result = producer.stage_wine_loader(app, self.root / 'backup')
        helper = app / result['bundle']; executable = helper / 'Contents/MacOS/wine'
        self.assertEqual(executable.read_bytes(), binary)
        self.assertFalse(executable.is_symlink())
        self.assertTrue(os.access(executable, os.X_OK))
        self.assertEqual(shim.resolve(), executable); self.assertEqual(source.resolve(), executable)
        self.assertEqual((self.root / 'backup/0-wine').read_bytes(), b'original shim')
        self.assertEqual((self.root / 'backup/1-wine').read_bytes(), binary)
        self.assertEqual(plistlib.loads((helper / 'Contents/Info.plist').read_bytes())['CFBundleExecutable'], 'wine')
        self.assertEqual(result['profile'], 'LOCAL_SIGNING_REQUIRED')
        self.assertEqual(result['omitted_legacy_preloaders'], [])

    def test_legacy_preloaders_are_preserved_outside_the_signed_helper_package(self):
        app = self.root / 'App'
        wine = app / 'Contents/Resources/engine/wine'
        source = wine / 'lib/wine/aarch64-unix/wine'; source.parent.mkdir(parents=True)
        binary = macho(payload=LOADER_PATHS)
        source.write_bytes(binary)
        shim = wine / 'bin/wine'; shim.parent.mkdir(); shim.write_bytes(b'original shim')
        relatives = ('bin/wine-preloader', 'lib/wine/aarch64-unix/wine-preloader')
        for index, relative in enumerate(relatives):
            (wine / relative).write_bytes(b'legacy preloader ' + bytes([index]))
        result = producer.stage_wine_loader(app, self.root / 'backup')
        self.assertEqual([row['path'] for row in result['omitted_legacy_preloaders']], list(relatives))
        for index, relative in enumerate(relatives):
            self.assertFalse((wine / relative).exists())
            preserved = self.root / 'backup' / (str(index) + '-wine-preloader')
            self.assertEqual(preserved.read_bytes(), b'legacy preloader ' + bytes([index]))
            self.assertEqual(result['omitted_legacy_preloaders'][index]['sha256'], producer.sha(preserved))
        self.assertEqual((app / result['bundle'] / 'Contents/MacOS/wine').read_bytes(), binary)

    def test_unfixed_source_loader_is_rejected_before_helper_creation(self):
        app = self.root / 'App'
        path = app / 'Contents/Resources/engine/wine/lib/wine/aarch64-unix/wine'
        path.parent.mkdir(parents=True); path.write_bytes(macho())
        with self.assertRaisesRegex(ValueError, 'lacks the signed-helper runtime layout'):
            producer.stage_wine_loader(app, self.root / 'backup')
        self.assertFalse((app / 'Contents/Resources/wine-loader').exists())

    def test_foreign_embedded_loader_identity_is_refused(self):
        app = self.root / 'App'
        path = app / 'Contents/Resources/engine/wine/lib/wine/aarch64-unix/wine'
        path.parent.mkdir(parents=True); path.write_bytes(macho(identity='invalid.test.loader'))
        with self.assertRaisesRegex(ValueError, 'embedded identity differs'):
            producer.stage_wine_loader(app, self.root / 'backup')
        self.assertFalse((app / 'Contents/Resources/wine-loader').exists())


if __name__ == '__main__':
    unittest.main()

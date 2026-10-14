#!/usr/bin/env python3
"""Real app staging, owned inert files and command callbacks; no native execution."""
import importlib.util
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


p = load('source_app_package_controls', HERE / 'package_source.py')
framework = load('source_app_framework_inventory', HERE / 'build_frameworks.py')
inventory = framework.load_runner().inventory


def inert_macho(cpu=0x0100000C):
    # Complete inert MH_MAGIC_64 header; no machine code is executed.
    return struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 0, 0, 0, 0)


class PackageControls(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ['REPRO109_TEST_TMP'])
        if root.is_symlink() or not root.is_dir():
            raise ValueError('Selected owned fixture root must be a directory')
        self.temp = tempfile.TemporaryDirectory(prefix='package-own-', dir=root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / 'prefix'
        products = self.prefix / 'products'
        products.mkdir(parents=True)
        for name in ['MacRunnerControlCenter', 'macr-hud']:
            file = products / name
            file.write_bytes(inert_macho())
            file.chmod(0o755)
        resource = products / p.RESOURCE
        resource.mkdir()
        (resource / 'own-resource').write_text('own fixture')
        (self.prefix / 'licenses').mkdir()
        (self.prefix / 'licenses/own-LICENSE').write_text('own fixture license')
        self.lock = {'components': []}
        for name in ['Sparkle', 'CrashReporter']:
            product = name + '.framework'
            binary = self.prefix / 'Frameworks' / product / 'Versions/A' / name
            binary.parent.mkdir(parents=True)
            binary.write_bytes(inert_macho())
            (binary.parent.parent / 'Current').symlink_to('A', target_is_directory=True)
            (binary.parent.parent.parent / name).symlink_to('Versions/Current/' + name)
            self.lock['components'].append({'product': product, 'required_binaries': ['Versions/A/' + name]})
        self.icon = self.root / 'own.icns'
        self.icon.write_bytes(b'icns\x00\x00\x00\x08')
        self.paths = {}
        self.calls = []
        self.foreign = False
        self.no_change = False
        self.failure = False
        self.mutate = False
        self.import_override = None

    def output(self, argv, label):
        self.calls.append((argv, label))
        if argv[1] == '-L':
            lib = '/own/foreign/lib.dylib' if self.foreign else '/usr/lib/libSystem.B.dylib'
            lib = self.import_override or lib
            return argv[-1] + ':\n\t' + lib + ' (compatibility version 1.0.0, current version 1.0.0)\n'
        paths = self.paths.setdefault(argv[-1], ['/own/cloud-build/Frameworks', '/usr/lib/swift'])
        return 'Load command 0\n cmd LC_SEGMENT_64\n' + ''.join(
            'Load command 1\n cmd LC_RPATH\n cmdsize 80\n path '+v+' (offset 12)\n' for v in paths)

    def command(self, argv, label):
        self.calls.append((argv, label))
        if label == 'package-macho-architecture':
            result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
            self.architecture_stdout, self.architecture_stderr = result.stdout, result.stderr
            if result.returncode != 0:
                raise RuntimeError('OWN_ARCHITECTURE_REFUSED')
            return
        if self.failure:
            raise RuntimeError('OWN_RELOCATION_FAILED')
        if self.no_change:
            return
        if self.mutate:
            (self.prefix / 'products/macr-hud').write_bytes(b'OWN_DRIFT')
        paths = self.paths[argv[-1]]
        if argv[1] == '-delete_rpath':
            paths.remove(argv[2])
        elif argv[1] == '-add_rpath':
            paths.append(argv[2])
        else:
            raise AssertionError('Unexpected command')

    def stage(self):
        return p.package(self.prefix, self.icon, self.lock, inventory, self.command, self.output)

    def test_spm_hud_framework_links_licenses_and_typed_plist(self):
        raw = inventory(self.prefix)
        result = self.stage()
        contents = self.prefix / 'MacRunner.app/Contents'
        self.assertEqual((contents / 'Resources/macr-hud').read_bytes(), (self.prefix / 'products/macr-hud').read_bytes())
        self.assertTrue((contents / 'Resources' / p.RESOURCE / 'own-resource').is_file())
        self.assertTrue((contents / 'Frameworks/Sparkle.framework/Versions/Current').is_symlink())
        self.assertTrue((contents / 'Resources/licenses/own-LICENSE').is_file())
        info = plistlib.loads((contents / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '1.0.9')
        self.assertEqual(info['LSMinimumSystemVersion'], '26.5')
        self.assertIs(info['LSBackgroundOnly'], False)
        self.assertEqual(result['whole_product'], 'NOT_ENABLED')
        self.assertEqual(result['app_launch'], 'NOT_ENABLED')
        self.assertEqual(len(result['runtime_inputs']), 5)
        for row in raw:
            self.assertEqual(p.digest(self.prefix / row['path']), row['sha256'])
        self.assertEqual([v['removed'] for v in result['relocations'].values()], [1, 1])
        self.assertTrue(all('/usr/lib/swift' in v['after'] for v in result['relocations'].values()))
        self.assertTrue(all(c[0][0] in ['/usr/bin/otool', '/usr/bin/install_name_tool',
                                      '/usr/bin/python3'] for c in self.calls))
        self.assertEqual(result['macho_architecture']['required_slice'], 'arm64')
        self.assertEqual(result['macho_architecture']['status'], 'PASS')
        self.assertIn('ЧИСТО'.encode(), self.architecture_stdout)

    def test_x86_only_legendary_resource_is_refused_without_execution(self):
        helper = self.prefix / 'products' / p.RESOURCE / 'Contents/Resources/tools/legendary'
        helper.parent.mkdir(parents=True)
        helper.write_bytes(inert_macho(0x01000007))
        with self.assertRaisesRegex(RuntimeError, 'OWN_ARCHITECTURE_REFUSED'):
            self.stage()
        self.assertIn(b'legendary', self.architecture_stdout)
        self.assertIn('БЕЗ arm64'.encode(), self.architecture_stdout)
        self.assertTrue((self.prefix / 'MacRunner.app').exists())

    def test_universal_legendary_with_arm64_is_accepted(self):
        helper = self.prefix / 'products' / p.RESOURCE / 'Contents/Resources/tools/legendary'
        helper.parent.mkdir(parents=True)
        header = struct.pack('>II', 0xCAFEBABE, 2)
        entries = struct.pack('>5I', 0x01000007, 0, 48, 32, 0)
        entries += struct.pack('>5I', 0x0100000C, 0, 80, 32, 0)
        helper.write_bytes(header + entries + inert_macho(0x01000007) + inert_macho())
        self.assertEqual(self.stage()['macho_architecture']['status'], 'PASS')

    def test_already_portable_rpath_needs_no_mutation(self):
        for path in ['MacOS/' + p.EXECUTABLE, 'Resources/macr-hud']:
            self.paths[str(self.prefix / 'MacRunner.app/Contents' / path)] = [p.FRAMEWORK_RPATH]
        self.stage()
        self.assertFalse(any(c[0][0].endswith('install_name_tool') for c in self.calls))

    def test_linked_framework_resolves_through_staged_rpath(self):
        self.import_override = '@rpath/Sparkle.framework/Versions/A/Sparkle'
        self.stage()

    def test_missing_or_escaping_linked_library_refused(self):
        for ref in ['@rpath/Absent.framework/Absent', '@loader_path/../../../../outside.dylib']:
            with self.subTest(ref=ref), self.assertRaisesRegex(ValueError, 'missing|escapes bundle'):
                p.linked_files(self.prefix / 'MacRunner.app/Contents/MacOS/own', [ref],
                               [p.FRAMEWORK_RPATH], self.prefix / 'MacRunner.app')

    def test_missing_spm_bundle_refused_before_copy(self):
        (self.prefix / 'products' / p.RESOURCE / 'own-resource').unlink()
        (self.prefix / 'products' / p.RESOURCE).rmdir()
        with self.assertRaisesRegex(ValueError, 'resources/licenses'):
            self.stage()
        self.assertFalse((self.prefix / 'MacRunner.app').exists())

    def test_framework_link_escape_refused_before_copy(self):
        link = self.prefix / 'Frameworks/Sparkle.framework/Versions/Current'
        link.unlink()
        link.symlink_to(self.root)
        with self.assertRaisesRegex(AssertionError, 'leaves prefix'):
            self.stage()

    def test_foreign_dependency_refused_and_partial_preserved(self):
        self.foreign = True
        with self.assertRaisesRegex(ValueError, 'nonportable'):
            self.stage()
        self.assertTrue((self.prefix / 'MacRunner.app').is_dir())

    def test_tool_error_is_not_suppressed(self):
        self.failure = True
        with self.assertRaisesRegex(RuntimeError, 'OWN_RELOCATION_FAILED'):
            self.stage()

    def test_tool_success_with_no_transformation_is_refused(self):
        self.no_change = True
        with self.assertRaisesRegex(ValueError, 'transformation differs'):
            self.stage()

    def test_raw_compiler_product_drift_refused(self):
        self.mutate = True
        with self.assertRaisesRegex(ValueError, 'product changed'):
            self.stage()

    def test_existing_destination_refused_without_overwrite(self):
        self.stage()
        before = inventory(self.prefix / 'MacRunner.app')
        with self.assertRaisesRegex(ValueError, 'Fresh app destination'):
            self.stage()
        self.assertEqual(before, inventory(self.prefix / 'MacRunner.app'))

    def test_empty_duplicate_and_incomplete_rpath_output_refused(self):
        for value in ['', 'cmd LC_RPATH\ncmd LC_SEGMENT_64\n',
                      'cmd LC_RPATH\npath a (offset 12)\ncmd LC_RPATH\npath a (offset 12)\n']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                p.rpaths(value)


if __name__ == '__main__':
    unittest.main()

"""Offline tests: synthetic bytes, no native tools or package execution."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('portable_engine', Path(__file__).with_name('assemble_engine.py'))
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)


class PortableEngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / 'fresh-cloud-prefix'
        self.lib = self.prefix / 'lib'
        self.lib.mkdir(parents=True)
        self.output = self.root / 'selected-output'
        self.output.mkdir()
        self.license = self.root / 'COPYING'
        self.license.write_bytes(b'fixture-license\n')
        self.config = {
            'name': 'fixture-source-engine', 'wine': 'wine', 'fex': 'fex',
            'graphics': 'graphics', 'wineEntitlements': 'entitlements.plist',
            'dependencyRoots': ['fresh-cloud-prefix'], 'environment': {},
            'licenseInputs': [{'name': 'fixture-COPYING', 'path': 'COPYING',
                              'sha256': engine.sha256(self.license)}],
        }
        self.config_path = self.root / 'engine-inputs.json'

    def load(self, strip=False):
        self.config_path.write_text(json.dumps(self.config))
        return engine.load_config(self.config_path, strip)

    def library(self, name, content=None, directory=None):
        path = (directory or self.lib) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content or (b'\xcf\xfa\xed\xfe' + name.encode()))
        return path

    def closure(self, dep, graph=None, extra=()):
        graph = graph or {}
        def dependencies(path):
            return [str(dep)] if Path(path).name == 'fixture-main' else graph.get(Path(path).name, [])
        with patch.object(engine, 'macho_deps', side_effect=dependencies):
            return engine.dependency_closure([Path('fixture-main')], self.output,
                                             [self.prefix.resolve()], extra)

    def test_relative_config_paths_follow_config_location(self):
        config = self.load()
        self.assertEqual(config['wine'], str(self.root / 'wine'))
        self.assertEqual(config['dependencyRoots'], [str(self.prefix)])
        self.assertEqual(config['licenseInputs'][0]['path'], str(self.license))

    def test_unselected_prefix_is_rejected(self):
        self.config.pop('dependencyRoots')
        with self.assertRaisesRegex(SystemExit, 'dependencyRoots'):
            self.load()

    def test_unselected_licenses_are_rejected(self):
        self.config.pop('licenseInputs')
        with self.assertRaisesRegex(SystemExit, 'licenseInputs'):
            self.load()

    def test_license_bytes_are_checked(self):
        self.license.write_bytes(b'tampered')
        with self.assertRaisesRegex(SystemExit, 'SHA256 mismatch'):
            self.load()

    def test_license_destination_traversal_is_rejected(self):
        self.config['licenseInputs'][0]['name'] = '../escape'
        with self.assertRaisesRegex(SystemExit, 'name is invalid'):
            self.load()

    def test_duplicate_license_destination_is_rejected(self):
        self.config['licenseInputs'].append(dict(self.config['licenseInputs'][0]))
        with self.assertRaisesRegex(SystemExit, 'duplicated'):
            self.load()

    def test_strip_requires_selected_tool_and_digest(self):
        tool = self.library('llvm-strip')
        self.config['stripTool'] = str(tool.relative_to(self.root))
        with self.assertRaisesRegex(SystemExit, 'llvm-strip SHA256'):
            self.load(strip=True)
        self.config['stripToolSHA256'] = engine.sha256(tool)
        self.assertEqual(self.load(strip=True)['stripTool'], str(tool))

    def test_non_homebrew_prefix_has_transitive_closure(self):
        a, b = self.library('libA.dylib'), self.library('libB.dylib')
        bundled, inputs = self.closure(a, {'libA.dylib': [str(b), '/usr/lib/libSystem.B.dylib']})
        self.assertEqual(set(bundled), {'libA.dylib', 'libB.dylib'})
        self.assertEqual(set(inputs), set(bundled))
        self.assertEqual((self.output / b.name).read_bytes(), b.read_bytes())
        self.assertFalse((self.output / 'libSystem.B.dylib').exists())

    def test_explicit_dlopen_library_is_copied(self):
        a, b = self.library('linked.dylib'), self.library('dlopen.dylib')
        bundled, _ = self.closure(a, extra=[b])
        self.assertEqual(set(bundled), {a.name, b.name})

    def test_relative_sibling_dependency_is_copied(self):
        a, b = self.library('libA.dylib'), self.library('libB.dylib')
        bundled, _ = self.closure(a, {a.name: ['@loader_path/' + b.name]})
        self.assertEqual(set(bundled), {a.name, b.name})

    def test_symlink_escape_from_selected_prefix_is_rejected(self):
        foreign = self.library('foreign.dylib', directory=self.root / 'foreign')
        link = self.lib / 'escape.dylib'
        link.symlink_to(foreign)
        with self.assertRaisesRegex(SystemExit, 'outside selected'):
            self.closure(link)

    def test_absolute_dependency_outside_selected_prefix_is_rejected(self):
        foreign = self.library('foreign.dylib', directory=self.root / 'foreign')
        with self.assertRaisesRegex(SystemExit, 'outside selected'):
            self.closure(foreign)

    def test_different_inputs_with_same_leaf_name_are_rejected(self):
        a = self.library('collision.dylib', b'first', self.lib / 'first')
        b = self.library('collision.dylib', b'second', self.lib / 'second')
        with self.assertRaisesRegex(SystemExit, 'conflicting dependency sources'):
            self.closure(a, extra=[b])

    def test_existing_wine_dist_dependency_must_match_selected_bytes(self):
        a = self.library('same.dylib')
        (self.output / a.name).write_bytes(b'foreign-existing-output')
        with self.assertRaisesRegex(SystemExit, 'differs from selected'):
            self.closure(a)

    def test_matching_existing_dependency_still_expands_children(self):
        a, b = self.library('libA.dylib'), self.library('libB.dylib')
        (self.output / a.name).write_bytes(a.read_bytes())
        bundled, _ = self.closure(a, {a.name: [str(b)]})
        self.assertEqual(bundled[a.name], 'wine-dist')
        self.assertIn(b.name, bundled)

    def test_complete_assembler_produces_pinned_manifest_on_inert_inputs(self):
        wanted_entitlements = getattr(self, 'wanted_entitlements', {})
        wine = self.root / 'wine'
        unix = wine / 'lib/wine/aarch64-unix'
        unix.mkdir(parents=True)
        (wine / 'share/wine').mkdir(parents=True)
        (wine / 'bin').mkdir()
        multiarch = getattr(self, 'multiarch_wine', False)
        programs = ('wine', 'wineserver') if multiarch else ('wine', 'wine-preloader', 'wineserver')
        for name in programs:
            self.library(name, directory=wine / 'bin')
        if multiarch:
            for name in ('wine', 'wine-preloader'):
                self.library(name, directory=unix)
        for name in ('fex', 'graphics'):
            (self.root / name).mkdir()
            (self.root / name / 'fixture.txt').write_bytes(name.encode())
        (self.root / 'entitlements.plist').write_bytes(plistlib.dumps(wanted_entitlements))
        deferred = getattr(self, 'defer_signing', False)
        if deferred:
            self.config['wineEntitlementsSHA256'] = engine.sha256(self.root / 'entitlements.plist')
        a, b = self.library('libA.dylib'), self.library('libB.dylib')
        self.load()
        states = {}
        temporary_entitlements = []
        native_commands = []
        def info(path):
            path = Path(path)
            if str(path) not in states:
                deps = [str(a)] if path.name == 'wine' else ([str(b)] if path.name == a.name else [])
                states[str(path)] = {'deps': deps + ['/usr/lib/libSystem.B.dylib'],
                                     'id': str(path) if path.suffix == '.dylib' else None,
                                     'rpaths': []}
            return states[str(path)]
        def command(*argv, **kwargs):
            native_commands.append(argv)
            self.assertIn(argv[0], ('install_name_tool', 'codesign'))
            self.assertTrue(Path(argv[-1]).is_file())
            if '--entitlements' in argv:
                temporary = Path(argv[argv.index('--entitlements') + 1])
                self.assertEqual(plistlib.loads(temporary.read_bytes()), wanted_entitlements)
                temporary_entitlements.append(temporary)
            if argv[0] == 'install_name_tool':
                current = info(argv[-1])
                i = 1
                while i < len(argv) - 1:
                    option = argv[i]
                    if option == '-change':
                        current['deps'] = [argv[i+2] if value == argv[i+1] else value for value in current['deps']]
                        i += 3
                    elif option == '-id':
                        current['id'] = argv[i+1]
                        i += 2
                    elif option == '-add_rpath':
                        current['rpaths'].append(argv[i+1])
                        i += 2
                    else:
                        self.fail('Unexpected native command option')
            return SimpleNamespace(stdout='', stderr='', returncode=0)
        destination = self.root / 'engine'
        def selected_entitlements(path):
            if deferred:
                self.fail('Deferred assembly must not inspect code signatures')
            path = Path(path)
            self.assertTrue(path.is_file())
            if multiarch and path == destination / 'wine/bin/wine':
                return {}
            if getattr(self, 'native_entitlements_mismatch', False) and path == destination / 'wine/lib/wine/aarch64-unix/wine':
                return {}
            return wanted_entitlements
        with patch.object(engine, 'macho_info', side_effect=info), \
             patch.object(engine, 'run', side_effect=command), \
             patch.object(engine, 'entitlements', side_effect=selected_entitlements), contextlib.redirect_stdout(io.StringIO()):
            argv = ['assemble_engine.py', str(self.config_path), str(destination)]
            engine.main(argv + (['--defer-signing'] if deferred else []))
        manifest = json.loads((destination / 'ENGINE.json').read_bytes())
        self.assertEqual(manifest['launcher'], 'wine/bin/wine')
        runtime = manifest['report']['wineRuntime']
        self.assertEqual(runtime['layout'], 'MULTIARCH_DISPATCHER' if multiarch else 'LEGACY_BIN')
        self.assertIn('wine/' + runtime['loader'], manifest['files'])
        self.assertIn('wine/' + runtime['preloader'], manifest['files'])
        self.assertEqual((destination / 'wine/bin/wine-preloader').exists(), not multiarch)
        self.assertEqual(len(manifest['report']['dependencyInputs']), 2)
        self.assertEqual((destination / 'licenses/fixture-COPYING').read_bytes(), self.license.read_bytes())
        for name, digest in manifest['files'].items():
            self.assertEqual(hashlib.sha256((destination / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(info(destination / 'wine/bin/wine')['deps'][0], '@rpath/' + a.name)
        self.assertTrue(all(not path.exists() for path in temporary_entitlements))
        if deferred:
            self.assertFalse(any(argv[0] == 'codesign' for argv in native_commands))
            self.assertTrue(any(argv[0] == 'install_name_tool' for argv in native_commands))
            signing = manifest['report']['signing']
            self.assertEqual(signing['mode'], 'DEFERRED_FOR_OWNER')
            self.assertEqual(signing['actual_entitlements'], 'NOT_ENABLED')
            self.assertTrue(signing['final_owner_signing_required'])
            intent = destination / signing['intent_path']
            self.assertEqual(intent.read_bytes(), (self.root / 'entitlements.plist').read_bytes())
            self.assertEqual(manifest['files'][signing['intent_path']], self.config['wineEntitlementsSHA256'])
        elif wanted_entitlements:
            self.assertEqual(len(temporary_entitlements), 3)

    def test_entitlements_survive_relocation_and_temporary_files_are_closed(self):
        self.wanted_entitlements = {'com.apple.security.custom-x18-abi-toggle': True}
        self.test_complete_assembler_produces_pinned_manifest_on_inert_inputs()

    def test_multiarch_dispatcher_and_native_loader_survive_full_assembly(self):
        self.multiarch_wine = True
        self.test_complete_assembler_produces_pinned_manifest_on_inert_inputs()

    def test_multiarch_checks_native_loader_entitlements_instead_of_dispatcher(self):
        self.multiarch_wine = True
        self.wanted_entitlements = {'com.apple.security.custom-x18-abi-toggle': True}
        self.test_complete_assembler_produces_pinned_manifest_on_inert_inputs()

    def test_multiarch_native_loader_entitlement_mismatch_is_rejected(self):
        self.multiarch_wine = True
        self.wanted_entitlements = {'com.apple.security.custom-x18-abi-toggle': True}
        self.native_entitlements_mismatch = True
        with self.assertRaisesRegex(SystemExit, 'wine loader entitlements'):
            self.test_complete_assembler_produces_pinned_manifest_on_inert_inputs()

    def test_multiarch_native_preloader_is_required(self):
        wine = self.root / 'wine'
        for name in ('bin/wine', 'bin/wineserver', 'lib/wine/aarch64-unix/wine'):
            self.library(Path(name).name, directory=wine / Path(name).parent)
        with self.assertRaisesRegex(SystemExit, 'aarch64-unix/wine-preloader'):
            engine.wine_runtime_layout(wine)

    def test_dispatcher_without_either_preloader_layout_is_rejected(self):
        wine = self.root / 'wine'
        for name in ('wine', 'wineserver'):
            self.library(name, directory=wine / 'bin')
        with self.assertRaisesRegex(SystemExit, 'no multiarch native loader'):
            engine.wine_runtime_layout(wine)

    def test_wineserver_is_required_in_both_layouts(self):
        wine = self.root / 'wine'
        self.library('wine', directory=wine / 'bin')
        with self.assertRaisesRegex(SystemExit, 'bin/wineserver'):
            engine.wine_runtime_layout(wine)

    def signing_config(self, value=None, raw=None):
        raw = raw if raw is not None else plistlib.dumps(value or {'fixture-abi': True})
        intent = self.root / 'entitlements.plist'
        intent.write_bytes(raw)
        self.config['wineEntitlementsSHA256'] = hashlib.sha256(raw).hexdigest()
        return self.load()

    def test_deferred_signing_legacy_layout_preserves_exact_intent(self):
        self.defer_signing = True
        self.wanted_entitlements = {'com.apple.security.custom-x18-abi-toggle': True}
        self.test_complete_assembler_produces_pinned_manifest_on_inert_inputs()

    def test_deferred_signing_multiarch_layout_preserves_exact_intent(self):
        self.defer_signing = True
        self.multiarch_wine = True
        self.wanted_entitlements = {'com.apple.security.custom-x18-abi-toggle': True}
        self.test_complete_assembler_produces_pinned_manifest_on_inert_inputs()

    def test_deferred_signing_requires_intent_pin(self):
        config = self.signing_config()
        config.pop('wineEntitlementsSHA256')
        with self.assertRaisesRegex(SystemExit, 'wineEntitlementsSHA256'):
            engine.signing_intent(config)

    def test_deferred_signing_rejects_intent_digest_drift(self):
        config = self.signing_config()
        (self.root / 'entitlements.plist').write_bytes(b'changed')
        with self.assertRaisesRegex(SystemExit, 'SHA256 mismatch'):
            engine.signing_intent(config)

    def test_deferred_signing_rejects_malformed_pinned_plist(self):
        config = self.signing_config(raw=b'not-a-plist')
        with self.assertRaisesRegex(SystemExit, 'valid plist'):
            engine.signing_intent(config)

    def test_deferred_signing_rejects_non_dictionary_pinned_plist(self):
        config = self.signing_config(raw=plistlib.dumps(['fixture']))
        with self.assertRaisesRegex(SystemExit, 'nonempty dictionary'):
            engine.signing_intent(config)

    def test_deferred_signing_rejects_empty_pinned_plist(self):
        config = self.signing_config(raw=plistlib.dumps({}))
        with self.assertRaisesRegex(SystemExit, 'nonempty dictionary'):
            engine.signing_intent(config)

    def test_deferred_signing_captures_exact_plist_bytes(self):
        config = self.signing_config(raw=plistlib.dumps({'fixture-abi': True}, fmt=plistlib.FMT_BINARY))
        self.assertEqual(engine.signing_intent(config), (self.root / 'entitlements.plist').read_bytes())

    def test_duplicate_or_unknown_cli_flags_fail_before_source_access(self):
        for flags in (['--defer-signing', '--defer-signing'], ['--strip-pe', '--strip-pe'], ['--unknown']):
            with self.subTest(flags=flags), patch.object(engine, 'load_config') as load:
                with self.assertRaises(SystemExit):
                    engine.main(['assemble_engine.py', 'fixture-inputs.json', 'fixture-output', *flags])
                load.assert_not_called()

    def test_both_cli_flags_accept_either_order(self):
        for flags in (['--strip-pe', '--defer-signing'], ['--defer-signing', '--strip-pe']):
            self.assertEqual(engine.assembly_options(['assemble_engine.py', 'fixture-in', 'fixture-out', *flags]),
                             (True, True))

    def test_default_and_single_cli_flags_preserve_signed_mode(self):
        self.assertEqual(engine.assembly_options(['assemble_engine.py', 'fixture-in', 'fixture-out']),
                         (False, False))
        self.assertEqual(engine.assembly_options(['assemble_engine.py', 'fixture-in', 'fixture-out', '--strip-pe']),
                         (True, False))

    def test_deferred_signing_invalid_pin_fails_before_output_or_native_tools(self):
        config = self.signing_config()
        config['wineEntitlementsSHA256'] = '0' * 64
        self.config_path.write_text(json.dumps(config))
        destination = self.root / 'engine'
        with patch.object(engine, 'wine_runtime_layout') as layout, patch.object(engine, 'run') as native:
            with self.assertRaisesRegex(SystemExit, 'SHA256 mismatch'):
                engine.main(['assemble_engine.py', str(self.config_path), str(destination), '--defer-signing'])
            layout.assert_not_called()
            native.assert_not_called()
        self.assertFalse(destination.exists())

    def test_signed_mode_mismatch_does_not_log_entitlement_values(self):
        self.multiarch_wine = True
        self.wanted_entitlements = {'fixture-private-key': 'fixture-private-value'}
        self.native_entitlements_mismatch = True
        with self.assertRaisesRegex(SystemExit, 'wine loader entitlements mismatch') as caught:
            self.test_complete_assembler_produces_pinned_manifest_on_inert_inputs()
        self.assertNotIn('fixture-private-key', str(caught.exception))
        self.assertNotIn('fixture-private-value', str(caught.exception))


if __name__ == '__main__':
    unittest.main()

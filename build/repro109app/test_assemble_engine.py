#!/usr/bin/env python3
"""CPU-only regression checks for dynamically loaded media packaging."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('assemble_engine', Path(__file__).with_name('assemble_engine.py'))
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)
VERIFY_SPEC = importlib.util.spec_from_file_location('verify_engine_media',
                                                   Path(__file__).with_name('verify_engine_media.py'))
verifier = importlib.util.module_from_spec(VERIFY_SPEC)
VERIFY_SPEC.loader.exec_module(verifier)


def load_command(index, command, value):
    field = 'path' if command == 'LC_RPATH' else 'name'
    return f'Load command {index}\n          cmd {command}\n      cmdsize 96\n         {field} {value} (offset 24)\n'


class MachOLoadCommandsTests(unittest.TestCase):
    def test_scanner_first_dependency_is_not_discarded_as_a_library_id(self):
        core = '/opt/homebrew/Cellar/gstreamer/1.28.3/lib/' + engine.GSTREAMER_CORE
        output = load_command(0, 'LC_LOAD_DYLIB', core)
        output += load_command(1, 'LC_LOAD_DYLIB', '/usr/lib/libSystem.B.dylib')
        info = engine.parse_macho_info(output)
        self.assertIsNone(info['id'])
        self.assertEqual(info['deps'], [core, '/usr/lib/libSystem.B.dylib'])

    def test_library_identity_is_separate_from_all_dependency_kinds(self):
        output = load_command(0, 'LC_ID_DYLIB', '/source/libgstplayback.dylib')
        output += load_command(1, 'LC_LOAD_WEAK_DYLIB', '@rpath/liboptional.dylib')
        output += load_command(2, 'LC_REEXPORT_DYLIB', '@rpath/libexport.dylib')
        output += load_command(3, 'LC_RPATH', '@loader_path/../../lib')
        info = engine.parse_macho_info(output)
        self.assertEqual(info['id'], '/source/libgstplayback.dylib')
        self.assertEqual(info['deps'], ['@rpath/liboptional.dylib', '@rpath/libexport.dylib'])
        self.assertEqual(info['rpaths'], ['@loader_path/../../lib'])

    def test_scanner_relocation_replaces_host_dependency_and_rpath_without_id(self):
        core = '/opt/homebrew/Cellar/gstreamer/1.28.3/lib/' + engine.GSTREAMER_CORE
        info = {'id': None, 'deps': [core], 'rpaths': ['/opt/homebrew/lib']}
        args = engine.relocation_args(info, Path('/bundle/media/bin/gst-plugin-scanner'),
                                      Path('/bundle/wine/lib/wine/aarch64-unix'),
                                      {engine.GSTREAMER_CORE: 'source'})
        self.assertNotIn('-id', args)
        self.assertEqual(args[:3], ['-change', core, '@rpath/' + engine.GSTREAMER_CORE])
        self.assertIn('-delete_rpath', args)
        self.assertEqual(args[-2:], ['-add_rpath', '@loader_path/../../wine/lib/wine/aarch64-unix'])

    def test_plugin_id_is_relocated_even_without_external_dependencies(self):
        info = {'id': '/opt/homebrew/lib/gstreamer-1.0/libgsttest.dylib',
                'deps': ['/usr/lib/libSystem.B.dylib'], 'rpaths': []}
        args = engine.relocation_args(info, Path('/bundle/media/gstreamer-1.0/libgsttest.dylib'),
                                      Path('/bundle/wine/lib/wine/aarch64-unix'), {})
        self.assertEqual(args[:2], ['-id', '@rpath/libgsttest.dylib'])
        self.assertIn('-add_rpath', args)

    def test_host_path_policy_covers_ids_and_rpaths_outside_homebrew(self):
        for value in ['/source/build/lib', '/cloud/source/lib', '/tmp/build/lib', '/opt/homebrew/lib']:
            self.assertTrue(engine.external_reference(value))
        for value in ['@rpath/libgst.dylib', '@loader_path/../lib', '/usr/lib/libSystem.B.dylib',
                      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation']:
            self.assertFalse(engine.external_reference(value))


class MediaClosureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'gstreamer/1.28.3'
        self.module = Path(self.temp.name).resolve() / 'wine/winegstreamer.so'
        self.core = self.root / 'lib' / engine.GSTREAMER_CORE
        self.plugin_dir = self.root / 'lib/gstreamer-1.0'
        self.scanner = self.root / 'libexec/gstreamer-1.0/gst-plugin-scanner'
        self.inputs = [self.module, self.core, self.scanner]
        self.inputs += [self.plugin_dir / f'libgst{p}.dylib' for p in engine.GSTREAMER_PLUGINS]
        for source in self.inputs:
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(b'\xcf\xfa\xed\xfe' + source.name.encode())
        self.deps = {str(f): [str(self.core)] for f in self.inputs if f != self.core}
        mock = patch.object(engine, 'macho_deps', side_effect=lambda p: self.deps.get(str(p), []))
        mock.start()
        self.addCleanup(mock.stop)

    def test_discovery_includes_unlinked_plugins_and_scanner_from_same_core(self):
        media = engine.discover_gstreamer(self.module)
        self.assertEqual(media['core'], self.core)
        self.assertEqual(len(media['sources']), 34)
        self.assertIn((self.scanner, 'media/bin/gst-plugin-scanner'), media['sources'])
        names = [p.name for p, _ in media['sources']]
        for name in ['libgstplayback.dylib', 'libgsttheora.dylib', 'libgstogg.dylib',
                     'libgstlibav.dylib', 'libgstvpx.dylib',
                     'libgstdeinterlace.dylib', 'libgstvideofilter.dylib']:
            self.assertIn(name, names)
        out = Path(self.temp.name) / 'bundle'
        report = engine.stage_gstreamer(media, out)
        self.assertEqual(len(report['inputs']), 34)
        for relative, item in report['inputs'].items():
            self.assertEqual(engine.sha256(out / relative), item['sha256'])
            self.assertTrue(Path(item['source']).is_relative_to(self.root))

    def test_missing_linked_core_fails_instead_of_using_another_host_installation(self):
        self.core.unlink()
        with self.assertRaisesRegex(SystemExit, 'missing or invalid GStreamer core'):
            engine.discover_gstreamer(self.module)

    def test_relocated_core_without_source_provenance_is_rejected(self):
        self.deps[str(self.module)] = ['@rpath/' + engine.GSTREAMER_CORE]
        with self.assertRaisesRegex(SystemExit, 'exactly one absolute GStreamer core'):
            engine.discover_gstreamer(self.module)

    def test_missing_playback_plugin_fails_before_producing_a_package(self):
        (self.plugin_dir / 'libgstplayback.dylib').unlink()
        with self.assertRaisesRegex(SystemExit, 'missing GStreamer media component'):
            engine.discover_gstreamer(self.module)

    def test_missing_wine_raw_video_converters_fail_before_packaging(self):
        for name in ['deinterlace', 'videofilter']:
            with self.subTest(plugin=name):
                source = self.plugin_dir / f'libgst{name}.dylib'
                original = source.read_bytes()
                source.unlink()
                try:
                    with self.assertRaisesRegex(SystemExit, 'missing GStreamer media component'):
                        engine.discover_gstreamer(self.module)
                finally:
                    source.write_bytes(original)

    def test_plugin_with_different_core_version_is_rejected(self):
        self.deps[str(self.plugin_dir / 'libgstplayback.dylib')] = [
            str(self.root.parent / '1.26.0/lib' / engine.GSTREAMER_CORE)]
        with self.assertRaisesRegex(SystemExit, 'different or missing core'):
            engine.discover_gstreamer(self.module)

    def test_plugin_symlink_to_another_installation_is_rejected(self):
        target = Path(self.temp.name) / 'foreign/libgstplayback.dylib'
        target.parent.mkdir()
        target.write_bytes(b'\xcf\xfa\xed\xfe')
        source = self.plugin_dir / target.name
        source.unlink()
        source.symlink_to(target)
        with self.assertRaisesRegex(SystemExit, 'escapes core installation'):
            engine.discover_gstreamer(self.module)

    def test_no_wine_media_module_preserves_non_media_builds(self):
        self.assertIsNone(engine.discover_gstreamer(Path(self.temp.name) / 'absent.so'))

    def test_environment_replaces_both_host_search_paths_and_registry(self):
        original = {'MACRUNNER_CPU_BACKEND': 'fex', 'GST_PLUGIN_PATH_1_0': '/host/plugins',
                    'GST_PLUGIN_SYSTEM_PATH': '/host/system', 'GST_REGISTRY': '/host/registry'}
        result = engine.media_environment(original)
        self.assertEqual(result['MACRUNNER_CPU_BACKEND'], 'fex')
        for suffix in ['', '_1_0']:
            self.assertEqual(result['GST_PLUGIN_PATH' + suffix], '')
            self.assertEqual(result['GST_PLUGIN_SYSTEM_PATH' + suffix], '${ENGINE}/media/gstreamer-1.0')
            self.assertEqual(result['GST_PLUGIN_SCANNER' + suffix], '${ENGINE}/media/bin/gst-plugin-scanner')
            self.assertEqual(result['GST_REGISTRY' + suffix], '${DATA}/gstreamer-registry.bin')
        self.assertEqual(original['GST_REGISTRY'], '/host/registry')


class MediaFactoryTests(unittest.TestCase):
    def test_wine_explicit_factories_are_checked_in_their_bundled_plugins(self):
        # Wine 11 wg_parser.c / wg_transform.c factory calls, independently of
        # codec autoplugging. winegstreamerstepper is registered by Wine itself.
        required = {
            'decodebin': 'playback', 'audioconvert': 'audioconvert',
            'audioresample': 'audioresample', 'videoconvert': 'videoconvertscale',
            'deinterlace': 'deinterlace', 'videoflip': 'videofilter',
            'capsfilter': 'coreelements', 'avdec_h264': 'libav',
        }
        for factory, plugin in required.items():
            with self.subTest(factory=factory):
                self.assertEqual(verifier.FACTORY_PLUGINS[factory], plugin)
                self.assertIn(plugin, engine.GSTREAMER_PLUGINS)
        self.assertTrue(set(verifier.FACTORY_PLUGINS.values()) <= set(engine.GSTREAMER_PLUGINS))
        self.assertNotIn('winegstreamerstepper', verifier.FACTORIES)
        self.assertNotIn('vaapidecodebin', verifier.FACTORIES)

    def test_construction_failure_is_not_hidden_by_other_available_factories(self):
        calls, released = [], []

        def make(name, instance):
            self.assertIsNone(instance)
            name = name.decode('ascii')
            calls.append(name)
            # Simulate registry/loader success but actual construction failure.
            return None if name in {'deinterlace', 'videoflip'} else name

        created, errors = verifier.construct_elements(make, released.append)
        self.assertIn('Failed to construct deinterlace', errors)
        self.assertIn('Failed to construct videoflip', errors)
        self.assertEqual(len(errors), 2)
        self.assertEqual(calls, list(verifier.FACTORIES))
        self.assertEqual(released, created)
        self.assertNotIn('deinterlace', created)
        self.assertNotIn('videoflip', created)
        self.assertIn('audioresample', created)  # Check continues after failures.


if __name__ == '__main__':
    unittest.main()

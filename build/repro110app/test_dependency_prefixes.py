"""Producer-prefix relocation must preserve dependency and media provenance."""
import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('prefix_engine', Path(__file__).with_name('assemble_engine.py'))
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)


class DependencyPrefixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.prefix = '/producer/build/deps/prefix'
        self.maps = [{'from': self.prefix, 'to': str(self.root)}]
        (self.root / 'lib').mkdir()

    def test_transitive_closure_uses_exact_pinned_bytes_without_editing_inputs(self):
        for name in ['liba.dylib', 'libb.dylib']:
            (self.root / 'lib' / name).write_bytes(name.encode())
        old_a = self.prefix + '/lib/liba.dylib'
        old_b = self.prefix + '/lib/libb.dylib'
        dependencies = {str(self.root / 'lib/liba.dylib'): [old_b]}
        dest = self.root / 'bundle'
        dest.mkdir()
        with patch.object(engine, 'macho_deps', side_effect=lambda p: dependencies.get(str(p), [])):
            bundled, inputs = engine.dependency_closure([], dest, [self.root], [old_a], mappings=self.maps)
        self.assertEqual(set(bundled), {'liba.dylib', 'libb.dylib'})
        for name in bundled:
            self.assertEqual((dest / name).read_bytes(), (self.root / 'lib' / name).read_bytes())
            self.assertEqual(inputs[name]['source'], str(self.root / 'lib' / name))

    def test_mapping_rejects_traversal_symlink_escape_and_prefix_lookalike(self):
        outside = self.root.parent / (self.root.name + '-outside')
        (self.root / 'lib/escape').symlink_to(outside)
        for path in [self.prefix + '/../outside', self.prefix + '/lib/escape',
                     self.prefix + '-other/lib/a', '/opt/homebrew/lib/a']:
            with self.subTest(path=path), self.assertRaises(SystemExit):
                engine.selected_dependency(path, [self.root], self.maps)

    def test_initial_relative_import_keeps_versioned_alias_beside_canonical_extra(self):
        canonical = self.root / 'lib/libjpeg.8.3.2.dylib'
        canonical.write_bytes(b'pinned jpeg8 ABI')
        (self.root / 'lib/libjpeg.8.dylib').symlink_to(canonical.name)
        plugin = self.root / 'staged/libgstjpeg.dylib'
        dest = self.root / 'bundle'
        dest.mkdir()
        with patch.object(engine, 'macho_deps', side_effect=lambda p:
                          ['@rpath/libjpeg.8.dylib'] if p == plugin else []):
            bundled, inputs = engine.dependency_closure([plugin], dest, [self.root], [canonical])
        self.assertEqual(set(bundled), {'libjpeg.8.dylib', canonical.name})
        self.assertEqual((dest / 'libjpeg.8.dylib').read_bytes(), canonical.read_bytes())
        self.assertEqual(inputs['libjpeg.8.dylib']['source'], str(canonical))

    def test_transitive_loader_relative_import_uses_selected_source_prefix(self):
        parent = self.root / 'lib/libparent.dylib'
        parent.write_bytes(b'parent')
        nested = self.root / 'nested/libcodec.2.4.dylib'
        nested.parent.mkdir()
        nested.write_bytes(b'pinned codec ABI2')
        (self.root / 'lib/libcodec.2.dylib').symlink_to(nested)
        dest = self.root / 'bundle'
        dest.mkdir()
        with patch.object(engine, 'macho_deps', side_effect=lambda p:
                          ['@loader_path/libcodec.2.dylib'] if p == parent else []):
            bundled, _ = engine.dependency_closure([], dest, [self.root], [parent])
        self.assertIn('libcodec.2.dylib', bundled)
        self.assertEqual((dest / 'libcodec.2.dylib').read_bytes(), nested.read_bytes())

    def test_relative_import_rejects_missing_or_conflicting_prefix_bytes(self):
        plugin = self.root / 'staged/plugin.dylib'
        dest = self.root / 'bundle'
        dest.mkdir()
        other = self.root / 'other'
        (other / 'lib').mkdir(parents=True)
        with patch.object(engine, 'macho_deps', return_value=['@rpath/libcodec.2.dylib']):
            with self.assertRaisesRegex(SystemExit, 'missing selected-prefix relative dependency'):
                engine.dependency_closure([plugin], dest, [self.root])
            (self.root / 'lib/libcodec.2.dylib').write_bytes(b'ABI2-one')
            (other / 'lib/libcodec.2.dylib').write_bytes(b'ABI2-other')
            with self.assertRaisesRegex(SystemExit, 'conflicting dependency sources'):
                engine.dependency_closure([plugin], dest, [self.root, other])

    def test_missing_mapped_file_does_not_fall_back_to_another_root(self):
        with self.assertRaisesRegex(SystemExit, 'missing dependency'):
            engine.selected_dependency(self.prefix + '/lib/absent', [self.root], self.maps)

    def test_config_requires_unambiguous_prefixes_and_selected_targets(self):
        license_path = self.root / 'LICENSE'
        license_path.write_bytes(b'pinned license')
        config = dict(wine='.', fex='.', graphics='.', wineEntitlements='LICENSE',
                      dependencyRoots=['.'],
                      licenseInputs=[dict(name='LICENSE', path='LICENSE',
                                          sha256=hashlib.sha256(b'pinned license').hexdigest())])
        path = self.root / 'engine-inputs.json'
        def load(rows):
            path.write_text(json.dumps(dict(config, dependencyPrefixMappings=rows)))
            return engine.load_config(path)
        good = {'from': self.prefix, 'to': '.'}
        self.assertEqual(load([good])['dependencyPrefixMappings'], self.maps)
        for rows in ['bad', [dict(good, to='..')], [dict(good, **{'from': '/'})],
                     [dict(good, **{'from': self.prefix + '/../prefix'})],
                     [good, good], [good, dict(good, **{'from': self.prefix + '/lib'})]]:
            with self.subTest(rows=rows), self.assertRaises(SystemExit):
                load(rows)

    def test_media_plugin_core_is_mapped_and_foreign_core_still_rejected(self):
        module = self.root / 'winegstreamer.so'
        core = self.root / 'lib' / engine.GSTREAMER_CORE
        scanner = self.root / 'libexec/gstreamer-1.0/gst-plugin-scanner'
        plugins = [self.root / 'lib/gstreamer-1.0' / ('libgst' + p + '.dylib')
                   for p in engine.GSTREAMER_PLUGINS]
        for path in [module, core, scanner, *plugins]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'\xcf\xfa\xed\xfe')
        old_core = self.prefix + '/lib/' + engine.GSTREAMER_CORE
        deps = {str(path): [old_core] for path in [module, scanner, *plugins]}
        with patch.object(engine, 'macho_deps', side_effect=lambda p: deps.get(str(p), [])):
            self.assertEqual(engine.discover_gstreamer(module, self.maps)['core'], core)
            deps[str(plugins[0])] = ['/foreign/lib/' + engine.GSTREAMER_CORE]
            with self.assertRaisesRegex(SystemExit, 'different or missing core'):
                engine.discover_gstreamer(module, self.maps)


if __name__ == '__main__':
    unittest.main()

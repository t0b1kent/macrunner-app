"""Inert component-consumption checks; no cloud access, runtime or build tools."""
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

import assemble_release as composer
import release111_components as component


class CurrentComponentInputs(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=os.environ.get('REPRO109_TEST_TMP'))
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def archive(self, path, files):
        path.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(path, 'w:gz') as stream:
            for name, data in files.items():
                row = tarfile.TarInfo(name); row.mode = 0o755; row.size = len(data)
                stream.addfile(row, io.BytesIO(data))
        Path(str(path) + '.sha256').write_text(component.sha(path) + '  ' + path.name + '\n')

    def graphics_fixture(self):
        roots = {}
        for name, variant, _ in component.GRAPHICS:
            root = self.root / name; roots[name] = root
            basename = variant + '.own'; data = ('own ' + variant).encode()
            archive = root / ('graphics-' + variant + '.tar.gz')
            self.archive(archive, {basename: data, 'obj/should-not-ship.o': b'own build intermediate'})
            scratch = self.write(root / 'own-product', data)
            detail = dict(status='HBDX9_SOURCE_BUILT_NOT_RELEASE_ACCEPTED' if variant.startswith('hbdx9-') else 'GRAPHICS_SOURCE_BUILT_NOT_RELEASE_ACCEPTED',
                          stage='compile', first_failure=None,
                          outputs=[dict(path=basename, sha256=component.sha(scratch), bytes=len(data))])
            self.write(root / 'release110-graphics-build/reports/RESULT.json', json.dumps(detail).encode())
        return roots

    def test_all_six_renderers_select_only_declared_outputs(self):
        roots = self.graphics_fixture(); output = self.root / 'graphics'
        details = component.graphics(roots, output, composer.unpack)
        self.assertEqual(set(details), {row[0] for row in component.GRAPHICS})
        self.assertEqual(len([p for p in output.rglob('*') if p.is_file()]), 6)
        self.assertFalse(any(p.name == 'should-not-ship.o' for p in output.rglob('*')))
        self.assertTrue(all(p.stat().st_mode & 0o111 for p in output.rglob('*') if p.is_file()))

    def test_wrong_renderer_hash_refuses(self):
        roots = self.graphics_fixture()
        path = roots['graphics_x64'] / 'release110-graphics-build/reports/RESULT.json'
        detail = json.loads(path.read_text()); detail['outputs'][0]['sha256'] = '0' * 64
        path.write_text(json.dumps(detail))
        with self.assertRaisesRegex(ValueError, 'product bytes differ'):
            component.graphics(roots, self.root / 'graphics', composer.unpack)

    def test_configure_only_result_is_not_a_compiled_renderer(self):
        roots = self.graphics_fixture()
        path = roots['graphics_x64'] / 'release110-graphics-build/reports/RESULT.json'
        detail = json.loads(path.read_text()); detail['stage'] = 'configure'; path.write_text(json.dumps(detail))
        with self.assertRaisesRegex(ValueError, 'Compiled renderer'):
            component.graphics(roots, self.root / 'graphics', composer.unpack)

    def fex_fixture(self):
        root = self.root / 'translator'
        files = {'fex32/engine/fex/aarch64-windows/xtajit.dll': b'own32',
                 'fex64/engine/fex/aarch64-windows/xtajit64.dll': b'own64',
                 'fex64/engine/wine/lib/wine/aarch64-windows/libarm64ecfex.dll': b'legacy-alias-not-selected'}
        license_data = b'Own inert permission notice\n'
        license_path = self.write(self.root / 'own-license', license_data)
        for variant in ['fex32', 'fex64']:
            for category in ['FEX', 'FEXCore']:
                files[variant + '/licenses/' + category + '/LICENSE'] = license_data
            files[variant + '/license-inputs.json'] = json.dumps({category: dict(LICENSE=component.sha(license_path))
                for category in ['FEX', 'FEXCore']}).encode()
        archive = root / 'release111-hyperbridge/fex-c33r-unsigned.tar'
        self.archive(archive, files)
        detail = dict(status='BUILT_SOURCE_ONLY_NOT_ACCEPTED', first_failure=None,
                      variants={name: dict(status='BUILT_SOURCE_ONLY', release_bytes='EXACT_ACCEPTED_BYTES') for name in ['fex32', 'fex64']},
                      archive=dict(path=archive.name, sha256=component.sha(archive)))
        self.write(root / 'release111-hyperbridge/RESULT.json', json.dumps(detail).encode())
        expected = {}
        for name, data in files.items():
            if '/engine/fex/' in name:
                path = self.write(self.root / ('fixture-' + str(len(expected))), data)
                expected['fex/' + name.split('/engine/fex/', 1)[1]] = component.sha(path)
        return root, dict(files=expected)

    def test_unified_fex_keeps_wines_separate_pe_bridge(self):
        root, template = self.fex_fixture(); output = self.root / 'fex'
        detail = component.fex(root, template, output, composer.unpack, composer.merge_tree)
        self.assertEqual(detail['exact_files'], 2)
        self.assertEqual(len(detail['license_roots']), 2)
        self.assertFalse(any(p.name == 'libarm64ecfex.dll' for p in output.rglob('*')))

    def test_fex_must_match_the_complete_selected_overlay(self):
        root, template = self.fex_fixture()
        template['files']['fex/aarch64-windows/xtajit.dll'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'complete translator overlay differs'):
            component.fex(root, template, self.root / 'fex', composer.unpack, composer.merge_tree)

    def test_component_report_cannot_select_a_parent_or_absolute_path(self):
        for name in ['../product', '/product', 'dir/product', 'dir\\product', '.', '..']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                component.filename(name)

    def test_missing_upstream_license_is_not_a_complete_component(self):
        root, template = self.fex_fixture(); output = self.root / 'fex'
        component.fex(root, template, output, composer.unpack, composer.merge_tree)
        parts = output.with_name(output.name + '-parts')
        (parts / 'fex32/licenses/FEX/LICENSE').unlink()
        with self.assertRaisesRegex(ValueError, 'license bytes differ'):
            component.license_roots(parts)


if __name__ == '__main__':
    unittest.main()

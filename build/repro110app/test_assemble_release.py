"""Own inert source-output composition tests, without runtime or cloud acquisition."""
import ast
import importlib.util
import io
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_composer', Path(__file__).with_name('assemble_release.py'))
producer = importlib.util.module_from_spec(spec); spec.loader.exec_module(producer)


class ReleaseCompositionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['REPRO109_TEST_TMP'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_workflow_uploads_the_archive_produced_by_the_composer(self):
        here = Path(__file__).resolve().parent
        tree = ast.parse((here / 'assemble_release.py').read_text())
        archives = [call.args[1].elts[2].right.value for call in ast.walk(tree)
                    if isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
                    and call.func.id == 'run' and call.args
                    and isinstance(call.args[0], ast.Constant)
                    and call.args[0].value == 'archive-app']
        self.assertEqual(len(archives), 1)
        workflow = (here.parents[1] / '.github/workflows/repro110-app-c12-source-xcode27-arm64.yml').read_text()
        self.assertIn('${{ runner.temp }}/release110-package/' + archives[0], workflow)

    def test_tar_preserves_executable_and_internal_framework_link(self):
        archive = self.root / 'app.tar.gz'
        with tarfile.open(archive, 'w:gz') as stream:
            binary = tarfile.TarInfo('Framework/Versions/A/Framework'); binary.mode = 0o755; binary.size = 3
            stream.addfile(binary, io.BytesIO(b'own'))
            link = tarfile.TarInfo('Framework/Versions/Current'); link.type = tarfile.SYMTYPE; link.linkname = 'A'
            stream.addfile(link)
        producer.unpack(archive, self.root / 'output')
        self.assertTrue(os.access(self.root / 'output/Framework/Versions/Current/Framework', os.X_OK))
        self.assertTrue((self.root / 'output/Framework/Versions/Current').is_symlink())

    def test_native_fex_companion_is_selected_from_the_fex_output(self):
        deps = self.root / 'deps/lib'; deps.mkdir(parents=True)
        fex = self.root / 'fex/aarch64-unix'; fex.mkdir(parents=True)
        (deps / 'libdependency.dylib').write_bytes(b'dependency')
        companion = fex / 'libmacrunner-hwtso.dylib'; companion.write_bytes(b'FEX source output')
        self.assertEqual(producer.source_libraries(
            ['libdependency.dylib', companion.name], [deps, fex]),
            [str(deps / 'libdependency.dylib'), str(companion)])

    def test_missing_and_conflicting_source_libraries_are_refused(self):
        first = self.root / 'first'; first.mkdir()
        second = self.root / 'second'; second.mkdir()
        name = 'libmacrunner-hwtso.dylib'
        with self.assertRaisesRegex(ValueError, 'leaves missing: ' + name):
            producer.source_libraries([name], [first, second])
        (first / name).write_bytes(b'one')
        (second / name).write_bytes(b'two')
        with self.assertRaisesRegex(ValueError, 'Conflicting selected dependency'):
            producer.source_libraries([name], [first, second])
        (second / name).write_bytes(b'one')
        self.assertEqual(producer.source_libraries([name], [first, second]), [str(first / name)])

    def test_tar_parent_escape_is_refused(self):
        archive = self.root / 'bad.tar.gz'
        with tarfile.open(archive, 'w:gz') as stream:
            row = tarfile.TarInfo('../escape'); row.size = 3
            stream.addfile(row, io.BytesIO(b'own'))
        with self.assertRaises(tarfile.FilterError):
            producer.unpack(archive, self.root / 'output')
        self.assertFalse((self.root / 'escape').exists())

    def test_runtime_collision_does_not_replace_evidence(self):
        before = self.root / 'before'; before.mkdir(); (before / 'own.dll').write_bytes(b'one')
        source = self.root / 'source'; source.mkdir(); (source / 'own.dll').write_bytes(b'two')
        with self.assertRaisesRegex(ValueError, 'collision'):
            producer.merge_tree(source, before)
        self.assertEqual((before / 'own.dll').read_bytes(), b'one')

    def test_each_absent_composition_tool_refuses(self):
        for name in ['gh', 'tar', 'install_name_tool', 'xcrun']:
            with self.subTest(name=name), patch.object(producer.shutil, 'which',
                    side_effect=lambda value: None if value == name else '/own/tool'):
                with self.assertRaisesRegex(ValueError, 'tool missing'):
                    producer.require_tools()

    def test_receiver_checkout_cannot_silently_replace_the_selected_source_recipe(self):
        args = SimpleNamespace(transport=self.root / 'receiver.py', wine=self.root / 'host',
                               dxmt=self.root / 'dxmt', hyperbridge=self.root / 'fex')
        args.transport.write_text('# own artifact receiver fixture\n')
        with self.assertRaisesRegex(ValueError, 'build/repro110wine/build_wine.py'):
            producer.source_inputs(args)


if __name__ == '__main__':
    unittest.main()

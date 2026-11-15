"""Inert archive fixtures for source selection; no compiler, GPU or network is used."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

import build_indiana as step


class IndianaSources(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('REPRO109_TEST_TMP'))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archives = self.root / 'archives'; self.archives.mkdir()
        self.here = self.root / 'recipe'; self.here.mkdir()
        base = {'LICENSE': b'Own inert fixture\n', 'Source.cpp': b'// before\n',
                'Scripts/gen_moltenvk_rev_hdr.sh': b'MVK_GIT_REV=old\n'}
        after = dict(base, **{'Source.cpp': b'// after\n'})
        cross = {'own.hpp': b'// own cross fixture\n'}
        def digest(rows):
            raw = ''.join(n + '\t' + hashlib.sha256(v).hexdigest() + '\n' for n, v in sorted(rows.items())).encode()
            return hashlib.sha256(raw).hexdigest()
        self.write_tar(self.archives / 'indiana.tar.gz', {
            **{'snapshot/' + n: v for n, v in base.items()},
            **{'snapshot/External/SPIRV-Cross/' + n: v for n, v in cross.items()},
            'snapshot/Package/Release/libMoltenVK.dylib': b'not a runtime input',
            'snapshot/External/unselected/prebuilt.a': b'not an input',
        })
        rows = []
        for name in ['Vulkan-Headers', 'SPIRV-Headers', 'SPIRV-Tools', 'cereal']:
            path = self.archives / (name + '.tar.gz')
            self.write_tar(path, {name + '/own.txt': b'Own source fixture\n'})
            rows.append(dict(name=name, bytes=path.stat().st_size, sha256=step.sha(path)))
        archive = self.archives / 'indiana.tar.gz'
        post = self.here / 'post.cpp'; post.write_bytes(after['Source.cpp'])
        self.lock = dict(sources=dict(macrunner=dict(bytes=archive.stat().st_size, sha256=step.sha(archive)), pinned=rows),
            source_profile=dict(core_prefix='snapshot/', core_files=3, core_before_inventory_sha256=digest(base),
                core_after_inventory_sha256=digest(after), cross_prefix='snapshot/External/SPIRV-Cross/', cross_files=1,
                cross_inventory_sha256=digest(cross), excluded_core_trees=['External', 'Package', 'macrunner'],
                revision='1' * 40, postimages=[dict(path='Source.cpp', store='post.cpp', bytes=post.stat().st_size,
                    before_sha256=hashlib.sha256(base['Source.cpp']).hexdigest(), after_sha256=step.sha(post))]))

    def write_tar(self, path, rows, unsafe_link=None):
        with tarfile.open(path, 'w:gz') as stream:
            for name, data in rows.items():
                info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o644
                stream.addfile(info, io.BytesIO(data))
            if unsafe_link:
                info = tarfile.TarInfo(unsafe_link); info.type = tarfile.SYMTYPE; info.linkname = '/etc/hosts'
                stream.addfile(info)

    def test_sources_are_sealed_and_package_binaries_are_excluded(self):
        result = step.prepare(self.lock, self.archives, self.root / 'sources', self.here)
        self.assertEqual(result['status'], 'INDIANA_EXACT_REBUILD_SOURCES_PREPARED')
        source = Path(result['source'])
        self.assertEqual((source / 'Source.cpp').read_bytes(), b'// after\n')
        self.assertFalse((source / 'Package').exists())
        self.assertFalse((source / 'External/unselected').exists())
        self.assertTrue((source / 'External/SPIRV-Tools/external/spirv-headers/own.txt').is_file())
        self.assertEqual((source / 'Scripts/gen_moltenvk_rev_hdr.sh').read_text(), 'MVK_GIT_REV=' + '1' * 40 + '\n')

    def test_corrupt_archive_refuses_before_materializing_sources(self):
        (self.archives / 'cereal.tar.gz').write_bytes(b'wrong archive')
        with self.assertRaisesRegex(ValueError, 'Archive pin differs'):
            step.prepare(self.lock, self.archives, self.root / 'sources', self.here)
        self.assertFalse((self.root / 'sources').exists())

    def test_wrong_postimage_does_not_replace_the_original(self):
        (self.here / 'post.cpp').write_bytes(b'// wrong\n')
        with self.assertRaisesRegex(ValueError, 'preimage/postimage differs'):
            step.prepare(self.lock, self.archives, self.root / 'sources', self.here)
        self.assertEqual((self.root / 'sources/MoltenVK/Source.cpp').read_bytes(), b'// before\n')

    def test_parent_escape_refuses_before_any_source_is_written(self):
        path = self.root / 'bad.tar.gz'
        self.write_tar(path, {'root/safe.cpp': b'// own\n', 'root/../escape.cpp': b'// own\n'})
        with self.assertRaisesRegex(ValueError, 'Unsafe source path'):
            step.select_archive(path, [('root/', self.root / 'selected', set())])
        self.assertFalse((self.root / 'selected').exists())

    def test_selected_symlink_is_refused(self):
        path = self.root / 'link.tar.gz'; self.write_tar(path, {}, unsafe_link='root/foreign.hpp')
        with self.assertRaisesRegex(ValueError, 'Foreign selected archive member'):
            step.select_archive(path, [('root/', self.root / 'selected', set())])
        self.assertFalse((self.root / 'selected').exists())

    def test_compile_guard_keeps_local_invocations_inert(self):
        with mock.patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, 'authorized ARM64 macOS cloud job'):
            step.cloud_guard()

    def test_pinned_link_is_validated_before_regular_source_extraction(self):
        path = self.root / 'pinned-link.tar.gz'
        with tarfile.open(path, 'w:gz') as stream:
            info = tarfile.TarInfo('root/header.hpp'); info.size = 4
            stream.addfile(info, io.BytesIO(b'own\n'))
            info = tarfile.TarInfo('root/include/header.hpp'); info.type = tarfile.SYMTYPE
            info.linkname = '../header.hpp'; stream.addfile(info)
        selected = self.root / 'selected'
        step.select_archive(path, [('root/', selected, set())], {'root/include/header.hpp': '../header.hpp'})
        self.assertFalse((selected / 'include').exists())
        step.restore_links(selected, {'include/header.hpp': '../header.hpp'})
        self.assertTrue((selected / 'include/header.hpp').is_symlink())
        self.assertEqual((selected / 'include/header.hpp').read_bytes(), b'own\n')

    def test_changed_pinned_link_refuses_before_writing_sources(self):
        path = self.root / 'changed-link.tar.gz'
        self.write_tar(path, {'root/safe.cpp': b'// own\n'}, unsafe_link='root/foreign.hpp')
        with self.assertRaisesRegex(ValueError, 'Pinned source symlink differs'):
            step.select_archive(path, [('root/', self.root / 'selected', set())],
                                {'root/foreign.hpp': 'safe.cpp'})
        self.assertFalse((self.root / 'selected').exists())

    def test_missing_pinned_link_refuses_before_writing_sources(self):
        path = self.root / 'missing-link.tar.gz'; self.write_tar(path, {'root/safe.cpp': b'// own\n'})
        with self.assertRaisesRegex(ValueError, 'Pinned source symlink missing'):
            step.select_archive(path, [('root/', self.root / 'selected', set())],
                                {'root/header.hpp': 'safe.cpp'})
        self.assertFalse((self.root / 'selected').exists())

    def test_restored_link_escape_refuses_the_whole_link_set(self):
        selected = self.root / 'selected'; selected.mkdir()
        with self.assertRaisesRegex(ValueError, 'escapes source root'):
            step.restore_links(selected, {'safe/header.hpp': '../header.hpp', 'bad': '../foreign'})
        self.assertEqual(list(selected.iterdir()), [])

    def test_isolated_plan_runs_from_another_directory_without_archives(self):
        child = subprocess.run([sys.executable, '-I', '-B', str(Path(step.__file__).resolve()), '--stage', 'plan'],
            cwd=self.root, capture_output=True, text=True, timeout=10)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertEqual(json.loads(child.stdout)['downloads'], 0)


if __name__ == '__main__':
    unittest.main()

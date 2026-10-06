"""Own source/backend/dispatch fixtures only; no vendor code or network."""
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest import mock
import zipfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_python_helpers as builder
import helper_package_worker as worker


class HelperBuildTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ['REPRO109_TEST_TMP']).resolve()
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def toml(self, data):
        return mock.patch.dict(sys.modules, {'tomllib': types.SimpleNamespace(loads=lambda _: data)})

    def test_actual_b45_graph_corrections(self):
        lock = builder.read_lock()
        self.assertEqual(len(lock['packages']), 23)
        self.assertEqual(lock['packages']['setuptools-scm']['version'], '8.3.1')
        self.assertEqual(lock['packages']['calver']['version'], '2025.10.20')
        self.assertEqual(lock['build_order'][:5], ['flit-core', 'setuptools', 'packaging', 'pip', 'wheel'])
        self.assertEqual(lock['static_requirements']['sha256'],
                         '180425500ee984e7a7337414009c5d2b351d71343465131506bf89e79dc6860a')

    def test_source_census_matches_tar_oracle(self):
        source = self.root / 'source'; source.mkdir()
        path = source / 'owned.c'; path.write_bytes(b'OWN_SOURCE\n'); path.chmod(0o644)
        stage = b'100644 ' + b'0'*40 + b' 0\towned.c\0' + b'160000 ' + b'1'*40 + b' 0\txdelta3\0'
        digest, count = builder.source_inventory(source, stage)
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as archive:
            info = tarfile.TarInfo('root/owned.c'); info.mode = 0o644
            info.size = len(path.read_bytes()); archive.addfile(info, io.BytesIO(path.read_bytes()))
        buffer.seek(0)
        with tarfile.open(fileobj=buffer) as archive:
            item = archive.getmembers()[0]; data = archive.extractfile(item).read()
            rows = [dict(path='owned.c', bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), mode=oct(item.mode))]
        oracle = hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        self.assertEqual((digest, count), (oracle, 1))

    def test_source_census_escape_refused(self):
        source = self.root / 'source'; source.mkdir()
        (self.root / 'escaped').write_bytes(b'OWN_FIXTURE')
        stage = b'100644 ' + b'0'*40 + b' 0\t../escaped\0'
        with self.assertRaisesRegex(ValueError, 'escapes source'):
            builder.source_inventory(source, stage)

    def test_backend_escape_refused(self):
        source = self.root / 'source'; source.mkdir(); (source / 'pyproject.toml').write_text('OWN_FIXTURE')
        table = {'build-system': {'requires': [], 'build-backend': 'own_fixture', 'backend-path': ['../escape']}}
        with self.toml(table), self.assertRaisesRegex(ValueError, 'escapes selected source'):
            worker.backend_config(source, [])

    def test_legacy_defaults_are_explicit(self):
        source = self.root / 'source'; source.mkdir()
        with self.toml({}):
            backend, required, roots = worker.backend_config(source, ['setuptools>=40.8.0', 'wheel'])
        self.assertEqual(backend, 'setuptools.build_meta:__legacy__')
        self.assertEqual(required, ['setuptools>=40.8.0', 'wheel'])
        self.assertEqual(roots, [])

    def test_actual_worker_builds_owned_backend_with_distribution_name(self):
        source = self.root / 'source'; source.mkdir(); wheels = self.root / 'wheels'; wheels.mkdir()
        (source / 'pyproject.toml').write_text('OWN_FIXTURE')
        module = source / 'own_repro109_backend.py'
        module.write_text('from pathlib import Path\nimport zipfile\n'
            'def get_requires_for_build_wheel(config): return []\n'
            'def build_wheel(out, config_settings=None):\n'
            '    name="owned_gl-1.2.3-py3-none-any.whl"\n'
            '    with zipfile.ZipFile(Path(out)/name,"w") as z:\n'
            '        z.writestr("owned_gl-1.2.3.dist-info/METADATA","Name: owned-gl\\nVersion: 1.2.3\\n")\n'
            '        z.writestr("owned_gl-1.2.3.dist-info/entry_points.txt","[console_scripts]\\nowned = owned.cli:main\\n")\n'
            '    return name\n')
        table = {'build-system': {'requires': [], 'build-backend': 'own_repro109_backend', 'backend-path': ['.']}}
        previous = list(sys.path)
        self.addCleanup(lambda: sys.path.__setitem__(slice(None), previous))
        self.addCleanup(lambda: sys.modules.pop('own_repro109_backend', None))
        with self.toml(table):
            result = worker.build(source, 'owned', '1.2.3', wheels, self.root / 'prefix',
                                  False, [], distribution='owned-gl')
        self.assertEqual(result['status'], 'SOURCE_WHEEL_BUILT')
        self.assertEqual(result['console_scripts']['owned'], 'owned.cli:main')

    def test_bootstrap_escape_refused(self):
        prefix = self.root / 'prefix'; destination = prefix / 'site'; destination.mkdir(parents=True)
        path = self.root / 'unsafe.whl'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('../escape', 'OWN_FIXTURE')
        with mock.patch.object(worker.sysconfig, 'get_path', return_value=str(destination)), \
                mock.patch.object(worker.sys, 'prefix', str(prefix)), \
                self.assertRaisesRegex(ValueError, 'unsafe installation'):
            worker.install_bootstrap(path, prefix)
        self.assertFalse((prefix / 'escape').exists())

    def test_built_wheel_duplicate_metadata_refused(self):
        path = self.root / 'unsafe.whl'
        with zipfile.ZipFile(path, 'w') as archive:
            for name in ['a', 'b']: archive.writestr(name + '.dist-info/METADATA', 'Name: owned\nVersion: 1\n')
        with self.assertRaisesRegex(ValueError, 'Exactly one'):
            worker.wheel_info(path)

    def test_noncloud_build_refuses_before_work(self):
        args = types.SimpleNamespace(work=self.root / 'must-not-exist')
        with mock.patch.dict(os.environ, {'CI_XCODE_CLOUD': ''}), \
                self.assertRaisesRegex(ValueError, 'Xcode Cloud ARM64 only'):
            builder.build(args, builder.read_lock())
        self.assertFalse(args.work.exists())

    def test_portable_smoke_hides_prefix_and_restores_after_failure(self):
        prefix = self.root / 'prefix'; prefix.mkdir()
        marker = prefix / 'OWN_FIXTURE'; marker.write_bytes(b'OWN_RUNTIME')
        def command(*args):
            self.assertFalse(prefix.exists())
            self.assertTrue((self.root / 'prefix-inactive-for-helper-smoke/OWN_FIXTURE').exists())
            raise ValueError('OWN_EXPECTED_FAILURE')
        with self.assertRaisesRegex(ValueError, 'OWN_EXPECTED_FAILURE'):
            builder.portable_cli(prefix, self.root / 'product', command)
        self.assertEqual(marker.read_bytes(), b'OWN_RUNTIME')
        self.assertFalse((self.root / 'prefix-inactive-for-helper-smoke').exists())

    def test_actual_wrapper_inert_handoff_and_body_coverage(self):
        repo = self.root / 'repo'; jobs = repo / 'jobs'; jobs.mkdir(parents=True)
        app = repo / 'repro109app'; app.mkdir()
        wrapper = jobs / 'repro109-python-helper-build.sh'
        wrapper.write_bytes((HERE.parent / 'jobs/repro109-python-helper-build.sh').read_bytes())
        driver = app / 'build_python_helpers.py'
        driver.write_text('import json,pathlib,sys\n'
            'args=sys.argv; work=pathlib.Path(args[args.index("--work")+1]); out=pathlib.Path(args[args.index("--publish-dir")+1])\n'
            'reports=work/"reports"; reports.mkdir(parents=True)\n'
            '(reports/"RESULT.json").write_text(json.dumps({"status":"OWN_INERT_FIXTURE"}))\n'
            '(reports/"retained.body").write_bytes(b"OWN_BODY")\n'
            '(out/"helpers.tar.gz").write_bytes(b"OWN_PRODUCT_NOT_VENDOR")\n')
        binary = self.root / 'bin'; binary.mkdir(); uname = binary / 'uname'
        uname.write_text('#!' + sys.executable + '\nimport sys\nprint("Darwin" if sys.argv[1]=="-s" else "arm64")\n')
        uname.chmod(0o700)
        env = dict(os.environ, PATH=str(binary) + ':/usr/bin:/bin', CI_XCODE_CLOUD='',
                   CI_WORKSPACE_PATH=str(self.root / 'cloud'))
        out = self.root / 'out'
        refused = subprocess.run(['/bin/bash', str(wrapper), str(out), 'xcode-cloud'],
                                 env=env, capture_output=True, timeout=30)
        self.assertEqual(refused.returncode, 1)
        self.assertFalse(out.exists())
        env['CI_XCODE_CLOUD'] = 'TRUE'
        accepted = subprocess.run(['/bin/bash', str(wrapper), str(out), 'xcode-cloud'],
                                  env=env, capture_output=True, timeout=30)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual((out / 'helper-build-rc.txt').read_text(), '0\n')
        self.assertFalse((out / 'retained.body').exists())
        omitted = json.loads((out / 'omitted-source-bodies.json').read_text())
        self.assertEqual(omitted[0]['sha256'], hashlib.sha256(b'OWN_BODY').hexdigest())
        self.assertEqual(omitted[0]['returned_bytes'], 'NOT_PUBLISHED_SOURCE_BODY_CLOUD_WORK_ONLY')
        self.assertEqual(json.loads((out / 'RESULT.json').read_text())['status'], 'OWN_INERT_FIXTURE')


if __name__ == '__main__':
    unittest.main()

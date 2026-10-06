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
import time
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

    def test_root_wheel_metadata_with_vendored_metadata(self):
        path = self.root / 'owned.whl'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('owned-1.dist-info/METADATA', 'Name: owned\nVersion: 1\n')
            archive.writestr('owned-1.dist-info/entry_points.txt',
                            '[console_scripts]\nowned = owned.cli:main\n')
            archive.writestr('owned/vendor/sibling-2.dist-info/METADATA',
                            'Name: sibling\nVersion: 2\n')
            archive.writestr('owned/vendor/sibling-2.dist-info/entry_points.txt',
                            '[console_scripts]\nwrong = sibling.cli:main\n')
        diagnostics = {}
        result = worker.wheel_info(path, diagnostics)
        self.assertEqual(result, dict(name='owned', version='1',
                                     console_scripts={'owned': 'owned.cli:main'}))
        self.assertEqual(diagnostics['wheel_metadata']['root_count'], 1)
        self.assertEqual(diagnostics['wheel_metadata']['suffix_count'], 2)

    def test_nested_only_metadata_cannot_replace_root(self):
        path = self.root / 'nested-only.whl'
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('owned/vendor/sibling-2.dist-info/METADATA',
                            'Name: sibling\nVersion: 2\n')
        with self.assertRaisesRegex(ValueError, 'Exactly one'):
            worker.wheel_info(path)

    def test_worker_diagnostics_survive_actual_metadata_refusal(self):
        source = self.root / 'source'; source.mkdir(); wheels = self.root / 'wheels'; wheels.mkdir()
        (source / 'pyproject.toml').write_text('OWN_FIXTURE')
        (source / 'own_diag_backend.py').write_text('from pathlib import Path\nimport zipfile\n'
            'def build_wheel(out, config_settings=None):\n'
            '    name="owned-1-py3-none-any.whl"\n'
            '    with zipfile.ZipFile(Path(out)/name,"w") as z:\n'
            '        for root in ["a","b"]:\n'
            '            z.writestr(root+".dist-info/METADATA","Name: owned\\nVersion: 1\\n")\n'
            '    return name\n')
        table = {'build-system': {'requires': [], 'build-backend': 'own_diag_backend', 'backend-path': ['.']}}
        previous_path = list(sys.path); previous_cwd = Path.cwd()
        self.addCleanup(lambda: sys.path.__setitem__(slice(None), previous_path))
        self.addCleanup(lambda: sys.modules.pop('own_diag_backend', None))
        self.addCleanup(lambda: os.chdir(previous_cwd))
        diagnostics = self.root / 'worker-diagnostics.json'
        argv = ['helper_package_worker.py', '--source', str(source), '--name', 'owned',
                '--version', '1', '--wheels', str(wheels), '--prefix', str(self.root / 'prefix'),
                '--receipt', str(self.root / 'receipt.json'), '--diagnostics', str(diagnostics)]
        with self.toml(table), mock.patch.object(worker.native, 'require_cloud'), \
                mock.patch.object(worker.sys, 'argv', argv), self.assertRaisesRegex(ValueError, 'root_count=2'):
            worker.main()
        saved = json.loads(diagnostics.read_text())
        self.assertEqual(saved['status'], 'FAILED')
        self.assertEqual(saved['wheel_metadata']['root_count'], 2)
        self.assertEqual(saved['wheel_metadata']['suffix_count'], 2)
        self.assertEqual(saved['first_failure']['exception'], 'ValueError')
        for name in ['pip', 'setuptools', 'flit', 'flit-core']:
            self.assertIn(saved['versions_before'][name]['state'], ['PRESENT', 'NOT_INSTALLED'])
            self.assertIn(saved['versions_after'][name]['state'], ['PRESENT', 'NOT_INSTALLED'])

    def test_noncloud_build_refuses_before_work(self):
        args = types.SimpleNamespace(work=self.root / 'must-not-exist')
        with mock.patch.dict(os.environ, {'CI_XCODE_CLOUD': ''}), \
                self.assertRaisesRegex(ValueError, 'Xcode Cloud ARM64 only'):
            builder.build(args, builder.read_lock())
        self.assertFalse(args.work.exists())

    def test_scope_uses_exact_order_and_keeps_prerequisites(self):
        lock = builder.read_lock()
        self.assertIsNone(builder.selection(lock))
        selected = builder.selection(lock, only_step=1)
        self.assertEqual(selected['package'], 'flit-core')
        self.assertEqual(selected['build_order'], ['flit-core'])
        self.assertEqual(builder.selection(lock, only_package='wheel')['build_order'],
                         ['flit-core', 'setuptools', 'packaging', 'pip', 'wheel'])
        self.assertEqual(builder.selection(lock, only_step=23)['build_order'], lock['build_order'])

    def test_scope_rejects_conflicting_unknown_and_out_of_range_inputs(self):
        lock = builder.read_lock()
        for values in [dict(only_step=0), dict(only_step=24), dict(only_step=True),
                       dict(only_package='../escape'), dict(only_package='flit-core', only_step=1)]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                builder.selection(lock, **values)

    def test_scoped_actual_driver_skips_native_and_stops_after_first_package(self):
        lock = builder.read_lock()
        args = types.SimpleNamespace(work=self.root / 'scoped', minutes=3, jobs=3,
                                     only_package='flit-core', only_step=None)
        actual_runner = builder.native.framework.load_runner()
        calls, sources = [], []
        def preflight(tool, out):
            (out / 'toolchain-preflight.json').write_text(json.dumps(dict(actual=dict(
                clang_path='/OWN_CC', clangxx_path='/OWN_CXX', sdk_path='/OWN_SDK'))))
            return Path('/OWN_SDK'), '/OWN_CC', '/OWN_CXX'
        def command(argv, cwd, env, log, out, component, deadline, **kwargs):
            calls.append((component, argv, kwargs))
            log.write_bytes(b'OWN_STDOUT\n')
            if kwargs.get('stderr_log'):
                kwargs['stderr_log'].write_bytes(b'OWN_STDERR\n')
            if component == 'scoped-bootstrap-venv':
                prefix = Path(argv[-1]); (prefix / 'bin').mkdir(parents=True)
                (prefix / 'bin/python3').write_bytes(b'OWN_INTERPRETER_FIXTURE')
            if component == 'flit-core-wheel':
                receipt = Path(argv[argv.index('--receipt') + 1])
                receipt.write_text(json.dumps(dict(name='flit-core', wheel='own.whl',
                                                  status='OWN_SOURCE_FIXTURE')))
        def download(row, archive, reports, transfer):
            sources.append(row['name']); archive.write_bytes(b'OWN_ARCHIVE_FIXTURE')
        def unpack(archive, destination):
            destination.mkdir(); (destination / 'OWN_SOURCE').write_bytes(b'OWN_SOURCE')
            return destination
        runner = types.SimpleNamespace(command=command, toolchain_preflight=preflight,
            environment=actual_runner.environment, unpack=unpack, licenses=lambda *a: [])
        env = {'REPRO109_HELPER_PROFILE': 'github-macos15-arm64', 'GITHUB_TOKEN': 'OWN_SECRET'}
        with mock.patch.dict(os.environ, env), mock.patch.object(builder.native, 'require_cloud'), \
                mock.patch.object(builder.native, 'build', side_effect=AssertionError('NATIVE_MUST_NOT_RUN')), \
                mock.patch.object(builder.native.framework, 'load_runner', return_value=runner), \
                mock.patch.object(builder.native.public_archive, 'download', side_effect=download), \
                mock.patch.object(builder.sys, 'version_info', (3, 14, 7)):
            builder.build(args, lock)
        self.assertEqual(sources, ['flit-core'])
        self.assertEqual([name for name, _, _ in calls], ['scoped-bootstrap-venv', 'flit-core-wheel'])
        result = json.loads((args.work / 'reports/RESULT.json').read_text())
        self.assertEqual(result['status'], 'SCOPED_SOURCE_PACKAGE_BUILT_DIAGNOSTIC_ONLY')
        self.assertEqual(result['source_python_acceptance'], 'NOT_ENABLED')
        environment = json.loads((args.work / 'reports/flit-core-build-environment.json').read_text())
        self.assertNotIn('GITHUB_TOKEN', environment)
        self.assertNotIn('OWN_SECRET', json.dumps(environment))
        self.assertEqual(environment['SETUPTOOLS_SCM_PRETEND_VERSION'], '3.12.0')
        self.assertEqual((args.work / 'reports/flit-core-wheel.stdout.log').read_bytes(), b'OWN_STDOUT\n')
        self.assertEqual((args.work / 'reports/flit-core-wheel.stderr.log').read_bytes(), b'OWN_STDERR\n')

    def test_separate_streams_preserve_failing_child_and_timeline(self):
        runner = builder.native.framework.load_runner()
        stdout, stderr = self.root / 'child.stdout.log', self.root / 'child.stderr.log'
        argv = [sys.executable, '-B', '-I', '-c',
                'import sys; print("OWN_OUT",flush=True); print("OWN_ERR",file=sys.stderr,flush=True); sys.exit(5)']
        with self.assertRaises(AssertionError):
            runner.command(argv, self.root, {}, stdout, self.root, 'own-streams',
                           time.monotonic() + 10, timeout=5, stderr_log=stderr)
        self.assertEqual(stdout.read_bytes(), b'OWN_OUT\n')
        self.assertEqual(stderr.read_bytes(), b'OWN_ERR\n')
        timeline = [json.loads(row) for row in (self.root / 'timeline.jsonl').read_text().splitlines()]
        self.assertEqual(timeline[-1]['rc'], 5)
        self.assertEqual(timeline[-1]['log_bytes'], 16)
        self.assertEqual(timeline[-1]['stderr_log'], stderr.name)

    def test_stderr_limit_is_counted_and_stops_only_owned_child(self):
        runner = builder.native.framework.load_runner()
        stdout, stderr = self.root / 'limit.stdout.log', self.root / 'limit.stderr.log'
        argv = [sys.executable, '-B', '-I', '-c',
                'import sys,time; print("X"*64,file=sys.stderr,flush=True); time.sleep(10)']
        with mock.patch.object(runner, 'MAX_LOG', 32), self.assertRaises(AssertionError):
            runner.command(argv, self.root, {}, stdout, self.root, 'own-limit',
                           time.monotonic() + 10, timeout=5, stderr_log=stderr)
        timeline = [json.loads(row) for row in (self.root / 'timeline.jsonl').read_text().splitlines()]
        self.assertEqual(timeline[-1]['state'], 'LOG_LIMIT_DROPPED')
        self.assertEqual(stdout.read_bytes(), b'')
        self.assertEqual(stderr.read_bytes(), b'X'*64 + b'\n')

    def test_scope_cli_plan_is_offline_and_invalid_step_is_refused(self):
        driver = HERE / 'build_python_helpers.py'
        good = subprocess.run([sys.executable, '-B', '-I', str(driver), '--only-step', '1'],
                              capture_output=True, timeout=15)
        self.assertEqual(good.returncode, 0, good.stderr)
        plan = json.loads(good.stdout)
        self.assertEqual(plan['selection']['build_order'], ['flit-core'])
        self.assertEqual((plan['network'], plan['builds'], plan['install']), (0, 0, 'skipped'))
        bad = subprocess.run([sys.executable, '-B', '-I', str(driver), '--only-step', '0'],
                             capture_output=True, timeout=15)
        self.assertNotEqual(bad.returncode, 0)

    def test_github_wrapper_scope_args_and_complete_report_handoff(self):
        repo = self.root / 'repo'; jobs = repo / 'jobs'; jobs.mkdir(parents=True)
        app = repo / 'repro109app'; app.mkdir()
        wrapper = jobs / 'repro109-python-helper-build-github.sh'
        wrapper.write_bytes((HERE.parent / 'jobs' / wrapper.name).read_bytes())
        (app / 'build_python_helpers.py').write_text('import json,pathlib,sys\n'
            'args=sys.argv; work=pathlib.Path(args[args.index("--work")+1])\n'
            'reports=work/"reports"; reports.mkdir(parents=True)\n'
            '(reports/"argv.json").write_text(json.dumps(args))\n'
            '(reports/"selected.stdout.log").write_bytes(b"OWN_FULL_OUT\\n")\n'
            '(reports/"selected.stderr.log").write_bytes(b"OWN_FULL_ERR\\n")\n'
            '(reports/"retained.body").write_bytes(b"OWN_CLOUD_BODY")\n')
        binary = self.root / 'bin'; binary.mkdir(); uname = binary / 'uname'
        uname.write_text('#!' + sys.executable + '\nimport sys\nprint("Darwin" if sys.argv[1]=="-s" else "arm64")\n')
        uname.chmod(0o700)
        runner_temp = self.root / 'runner'; runner_temp.mkdir()
        env = dict(os.environ, PATH=str(binary) + ':/usr/bin:/bin', GITHUB_ACTIONS='true',
                   RUNNER_OS='macOS', RUNNER_ARCH='ARM64', RUNNER_TEMP=str(runner_temp),
                   REPRO109_HELPER_ONLY_PACKAGE='', REPRO109_HELPER_ONLY_STEP='1')
        out = self.root / 'out'
        result = subprocess.run(['/bin/bash', str(wrapper), str(out)], env=env,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((out / 'argv.json').read_text())
        self.assertEqual(args[args.index('--minutes') + 1], '3')
        self.assertEqual(args[args.index('--only-step') + 1], '1')
        self.assertEqual((out / 'selected.stdout.log').read_bytes(), b'OWN_FULL_OUT\n')
        self.assertEqual((out / 'selected.stderr.log').read_bytes(), b'OWN_FULL_ERR\n')
        self.assertFalse((out / 'retained.body').exists())
        self.assertEqual((out / 'helper-wrapper-rc.txt').read_text(), '0\n')
        # macOS Bash 3.2 with nounset must also accept the empty selector.
        full_temp = self.root / 'runner-full'; full_temp.mkdir()
        full_out = self.root / 'out-full'
        env.update(RUNNER_TEMP=str(full_temp), REPRO109_HELPER_ONLY_STEP='')
        full = subprocess.run(['/bin/bash', str(wrapper), str(full_out)], env=env,
                              capture_output=True, timeout=30)
        self.assertEqual(full.returncode, 0, full.stderr)
        full_args = json.loads((full_out / 'argv.json').read_text())
        self.assertNotIn('--only-step', full_args)
        self.assertNotIn('--only-package', full_args)
        self.assertEqual(full_args[full_args.index('--minutes') + 1], '120')
        self.assertEqual((full_out / 'helper-wrapper-rc.txt').read_text(), '0\n')

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

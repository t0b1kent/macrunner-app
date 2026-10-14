"""Own synthetic PBX controls; no vendor source, subprocess, or temporary files."""
import ast
import copy
import hashlib
import json
from pathlib import Path
import unittest


def load_graph():
    tree = ast.parse(Path(__file__).with_name('build_app_frameworks.py').read_text())
    node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'project_graph')
    scope = {'hashlib': hashlib}
    exec(compile(ast.Module(body=[node], type_ignores=[]), '<own-project-graph>', 'exec'), scope)
    return scope['project_graph']


class ProjectGraphTests(unittest.TestCase):
    def setUp(self):
        self.graph = load_graph()
        self.data = {'rootObject': 'P', 'objects': {
            'P': {'isa': 'PBXProject', 'targets': ['D', 'S']},
            'D': {'isa': 'PBXNativeTarget', 'name': 'Dynamic', 'dependencies': ['DEP'],
                  'buildPhases': ['PH'], 'buildConfigurationList': 'CONF'},
            'S': {'isa': 'PBXNativeTarget', 'name': 'Static', 'dependencies': []},
            'DEP': {'isa': 'PBXTargetDependency', 'target': 'S'},
            'PH': {'isa': 'PBXSourcesBuildPhase', 'files': ['BF']},
            'BF': {'isa': 'PBXBuildFile', 'fileRef': 'F', 'settings': {'COMPILER_FLAGS': '-fno-objc-arc'}},
            'F': {'isa': 'PBXFileReference', 'path': 'Source/file.m', 'sourceTree': '<group>'},
            'CFG': {'isa': 'XCBuildConfiguration', 'name': 'Release', 'buildSettings': {
                'OTHER_CFLAGS': ['-DTEST'], 'DEVELOPMENT_TEAM': 'SYNTHETIC_SECRET',
                'CODE_SIGN_IDENTITY': 'SYNTHETIC_SECRET'}},
            'SCRIPT': {'isa': 'PBXShellScriptBuildPhase', 'shellScript': 'SYNTHETIC_SCRIPT_BODY',
                       'inputPaths': ['Input'], 'outputPaths': ['Output']}}}

    def test_membership_and_dependency_closure(self):
        d = self.graph(self.data, 'Dynamic')
        self.assertEqual(d['dependency_targets'], ['D', 'S'])
        self.assertEqual(d['objects']['PH']['files'], ['BF'])
        self.assertEqual(d['objects']['BF']['fileRef'], 'F')
        self.assertEqual(d['objects']['BF']['settings']['COMPILER_FLAGS'], '-fno-objc-arc')

    def test_scripts_hashed_and_identity_values_absent(self):
        d = self.graph(self.data, 'Dynamic')
        text = json.dumps(d)
        self.assertNotIn('SYNTHETIC_SECRET', text)
        self.assertNotIn('SYNTHETIC_SCRIPT_BODY', text)
        self.assertEqual(d['objects']['SCRIPT']['shellScript']['sha256'],
                         hashlib.sha256(b'SYNTHETIC_SCRIPT_BODY').hexdigest())
        self.assertEqual(d['objects']['CFG']['buildSettings'], {'OTHER_CFLAGS': ['-DTEST']})

    def test_unresolved_dependency_named(self):
        self.data['objects']['DEP'].pop('target')
        self.assertEqual(self.graph(self.data, 'Dynamic')['unresolved_dependencies'], ['DEP'])

    def test_dependency_cycle_is_bounded(self):
        self.data['objects']['S']['dependencies'] = ['BACK']
        self.data['objects']['BACK'] = {'isa': 'PBXTargetDependency', 'target': 'D'}
        self.assertEqual(self.graph(self.data, 'Dynamic')['dependency_targets'], ['D', 'S'])

    def test_missing_or_ambiguous_target_rejected(self):
        with self.assertRaises(ValueError):
            self.graph(self.data, 'Missing')
        self.data['objects']['COPY'] = copy.deepcopy(self.data['objects']['D'])
        with self.assertRaises(ValueError):
            self.graph(self.data, 'Dynamic')

    def test_original_not_mutated_and_invalid_shapes_rejected(self):
        original = copy.deepcopy(self.data)
        self.graph(self.data, 'Dynamic')
        self.assertEqual(self.data, original)
        for data in [None, {}, {'objects': []}, {'objects': {'BAD': None}}]:
            with self.assertRaises(ValueError):
                self.graph(data, 'Dynamic')


if __name__ == '__main__':
    unittest.main()

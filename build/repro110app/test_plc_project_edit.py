"""Offline controls for the recipe edit of the pinned PLCrashReporter project (synthetic fixtures only)."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


edit = load('plc_project_edit_under_test', HERE / 'plc_project_edit.py')
driver = load('build_app_frameworks_under_test', HERE / 'build_app_frameworks.py')
BUILD_FILE, FILE_REF = edit.PROTO_BUILD_FILE, edit.PROTO_FILE_REFERENCE


def project(entry=True, definition=True, ref=FILE_REF, extra=''):
    rows = ['// !$*UTF8*$!', '{', '/* Begin PBXBuildFile section */',
            '\t\tAAAA00000000000000000001 /* a.c in Sources */ = {isa = PBXBuildFile; fileRef = AAAA00000000000000000002 /* a.c */; };']
    if definition:
        rows.append('\t\t%s /* PLCrashReport.proto in Sources */ = {isa = PBXBuildFile; fileRef = %s /* PLCrashReport.proto */; };' % (BUILD_FILE, ref))
    rows += ['/* End PBXBuildFile section */', '/* Begin PBXSourcesBuildPhase section */', '\t\t05E731F00EFA1AAB005EDFB7 = {',
             '\t\t\tfiles = (', '\t\t\t\tAAAA00000000000000000001 /* a.c in Sources */,']
    if entry:
        rows.append('\t\t\t\t%s /* PLCrashReport.proto in Sources */,' % BUILD_FILE)
    rows += ['\t\t\t);', '\t\t};', '/* End PBXSourcesBuildPhase section */', extra, '}', '']
    return '\n'.join(rows).encode()


def pin(data):
    return (len(data), hashlib.sha256(data).hexdigest())


class ProjectEdit(unittest.TestCase):
    def test_removes_exactly_the_definition_and_the_phase_entry(self):
        data = project()
        out, report = edit.apply(data, pin(data))
        self.assertEqual(out.decode().count('\n'), data.decode().count('\n') - 2)
        self.assertNotIn(BUILD_FILE, out.decode())
        self.assertIn('AAAA00000000000000000001 /* a.c in Sources */,', out.decode())
        self.assertEqual(report['removed_lines'], 2)
        self.assertEqual(report['before']['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(report['after']['sha256'], hashlib.sha256(out).hexdigest())
        self.assertEqual(len(report['removed_row_sha256']), 2)
        self.assertEqual(edit.apply(data, pin(data)), (out, report))

    def test_other_bytes_are_refused_before_any_edit(self):
        data = project()
        with self.assertRaisesRegex(ValueError, 'pinned bytes'):
            edit.apply(data, (len(data), '0' * 64))
        with self.assertRaisesRegex(ValueError, 'pinned bytes'):
            edit.apply(data + b' ')

    def test_missing_extra_or_changed_rows_are_refused(self):
        for broken in (project(entry=False), project(definition=False), project(ref='BBBB00000000000000000003'),
                       project(extra='\t\t\t\t%s /* PLCrashReport.proto in Sources */,' % BUILD_FILE)):
            with self.subTest(len(broken)), self.assertRaises(ValueError):
                edit.apply(broken, pin(broken))

    def test_the_pin_is_the_diagnosed_project_file(self):
        # Graph captured by run 38495582844 from the pinned revision: 318366 bytes, this digest.
        self.assertEqual((edit.PINNED_BYTES, edit.PINNED_SHA256),
                         (318366, '6168cf17e8abda407455179c59b769c0c1f491e3ffe77cfd312caa34c8b626ad'))


class DriverUsesTheEdit(unittest.TestCase):
    def setUp(self):
        self.lock = driver.read_lock()
        self.row = next(r for r in self.lock['components'] if r['name'] == 'plcrashreporter')

    def test_lock_pins_the_module_bytes_and_only_plc_has_an_edit(self):
        self.assertEqual(self.row['project_edit'], {'name': edit.NAME,
            'module_sha256': hashlib.sha256((HERE / 'plc_project_edit.py').read_bytes()).hexdigest()})
        self.assertEqual([r['name'] for r in self.lock['components'] if 'project_edit' in r], ['plcrashreporter'])

    def test_lock_with_a_foreign_or_unpinned_edit_is_refused(self):
        for bad in ({'name': 'other', 'module_sha256': 'a' * 64}, {'name': edit.NAME}, {'name': edit.NAME, 'module_sha256': 'xyz'}):
            lock = json.loads(json.dumps(self.lock))
            next(r for r in lock['components'] if r['name'] == 'plcrashreporter')['project_edit'] = bad
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / 'lock.json'
                path.write_text(json.dumps(lock))
                with self.assertRaisesRegex(ValueError, 'project edit'):
                    driver.read_lock(path)
        lock = json.loads(json.dumps(self.lock))
        next(r for r in lock['components'] if r['name'] == 'sparkle')['project_edit'] = self.row['project_edit']
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'lock.json'
            path.write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, 'project edit'):
                driver.read_lock(path)

    def test_module_bytes_must_match_the_lock_and_the_file_is_edited_in_place(self):
        data = project()
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'project.pbxproj'
            target.write_bytes(data)
            with self.assertRaisesRegex(ValueError, 'module differs'):
                driver.apply_project_edit(target, dict(self.row['project_edit'], module_sha256='0' * 64))
            self.assertEqual(target.read_bytes(), data)
            real = edit.apply
            with patch.object(edit, 'apply', side_effect=lambda value: real(value, pin(data))), \
                    patch.object(driver.importlib.util, 'module_from_spec', return_value=edit):
                with patch.object(driver.importlib.util, 'spec_from_file_location',
                                  return_value=type('S', (), {'loader': type('L', (), {'exec_module': lambda self, m: None})()})()):
                    report = driver.apply_project_edit(target, self.row['project_edit'])
            self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), report['after']['sha256'])

    def test_post_build_status_allows_only_the_edited_project_file(self):
        text = (HERE / 'build_app_frameworks.py').read_text()
        self.assertIn("expected_status = ' M ' + row['project'] + '/project.pbxproj'", text)
        self.assertIn("if after.rstrip('\\n') != expected_status:", text)
        self.assertNotIn('if after.strip():', text)
        self.assertLess(text.index('apply_project_edit(source /'), text.index("command(argv + ['build']"))
        self.assertLess(text.index("name + '-archive'"), text.index('apply_project_edit(source /'))

    def test_source_lock_pins_the_current_driver_and_lock(self):
        pins = json.loads((HERE / 'source.lock.json').read_bytes())['frameworks_recipe']
        self.assertEqual(pins, {'driver_sha256': hashlib.sha256((HERE / 'build_app_frameworks.py').read_bytes()).hexdigest(),
                                'lock_sha256': hashlib.sha256((HERE / 'frameworks.lock.json').read_bytes()).hexdigest()})


if __name__ == '__main__':
    unittest.main(verbosity=2)

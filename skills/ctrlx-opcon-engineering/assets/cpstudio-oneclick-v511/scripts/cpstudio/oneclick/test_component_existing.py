"""Protocol checks with native API doubles; does not contact PLE or a PLC."""
import hashlib
import contextlib
import io
import json
from pathlib import Path
import runpy
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

WRAPPER = Path(__file__).with_name('component_existing.py')

class ComponentNativeTest(unittest.TestCase):
    def run_component(self, role='library', logged_in=False, wrong_project=False,
                      digest_changed=False, dirty_after=False):
        with tempfile.TemporaryDirectory(prefix='component-native-test-') as directory:
            root = Path(directory)
            operation = root / 'operation'
            operation.mkdir()
            script_path = root / 'scripts' / 'ple' / 'import_library.py'
            script_path.parent.mkdir(parents=True)
            extension = '.library' if role == 'library' else '.project'
            project_path = root / ('copy' + extension)
            project_path.write_text('opaque test double')
            payload = b'TARGET_PROJECT.ran = True\nCOMPONENT_RESULT = {"verified": True}\n'
            if dirty_after:
                payload += b'TARGET_PROJECT.dirty = True\n'
            script_path.write_bytes(payload)
            (operation / 'component_payload.py').write_bytes(payload)
            job = dict(operationId='unit-operation', phase='component', expectedPid=71,
                       project=str(project_path), projectRole=role, componentRoot=str(root),
                       isolatedRoot=str(root), reviewedScript=dict(
                           path='scripts/ple/import_library.py',
                           sha256='0' * 64 if digest_changed else hashlib.sha256(payload).hexdigest()))
            (operation / 'job.json').write_text(json.dumps(job), encoding='utf-8')
            info = types.SimpleNamespace(title='Test', company='Owned', version='1.0.0.0')
            applications = [] if role == 'library' else [types.SimpleNamespace(is_application=True)]
            project = types.SimpleNamespace(path=str(root / 'wrong.library') if wrong_project else str(project_path),
                                            dirty=False, ran=False, get_children=lambda recursive: applications,
                                            get_project_info=lambda: info)
            engine = types.ModuleType('scriptengine')
            engine.projects = types.SimpleNamespace(primary=project)
            engine.online = types.SimpleNamespace(create_online_application=lambda app:
                                                   types.SimpleNamespace(is_logged_in=logged_in))
            system = types.ModuleType('System')
            diagnostics = types.ModuleType('System.Diagnostics')
            diagnostics.Process = types.SimpleNamespace(GetCurrentProcess=lambda: types.SimpleNamespace(Id=71))
            with patch.dict(sys.modules, {'scriptengine': engine, 'System': system, 'System.Diagnostics': diagnostics}):
                copied = operation / WRAPPER.name
                copied.write_bytes(WRAPPER.read_bytes())
                try:
                    with contextlib.redirect_stdout(io.StringIO()):
                        runpy.run_path(str(copied))
                except RuntimeError:
                    pass
            return json.loads((operation / 'component.json').read_text()), project.ran

    def test_library_without_an_application_has_native_identity_and_evidence(self):
        result, ran = self.run_component()
        self.assertTrue(ran and result['complete'] and result['saved'] and result['offline'])
        self.assertEqual(result['libraryInfo']['version'], '1.0.0.0')
        self.assertEqual(result['evidence'], {'verified': True})

    def test_online_consumer_wrong_project_and_substituted_source_never_run(self):
        for options in ({'role': 'consumer', 'logged_in': True}, {'wrong_project': True}, {'digest_changed': True}):
            with self.subTest(options=options):
                result, ran = self.run_component(**options)
                self.assertFalse(ran or result['complete'])

    def test_unsaved_return_is_an_error_instead_of_an_implicit_save(self):
        result, ran = self.run_component(dirty_after=True)
        self.assertTrue(ran)
        self.assertFalse(result['complete'])
        self.assertIn('explicitly save', result['exception'])

if __name__ == '__main__':
    unittest.main()

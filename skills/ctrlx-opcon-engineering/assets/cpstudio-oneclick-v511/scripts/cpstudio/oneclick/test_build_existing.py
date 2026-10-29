"""Exercise offline fail-stop conditions without loading PLE or touching Station060."""
import contextlib
import io
import json
import pathlib
import runpy
import sys
import tempfile
import types
import unittest
import warnings
from unittest.mock import patch


HERE = pathlib.Path(__file__).resolve().parent
ENGINEERING_ROOT = HERE.parents[2]


class BuildGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = pathlib.Path(self.temp.name)
        self.project_path = self.folder / 'fixture.project'
        self.project_path.write_bytes(b'offline fixture')
        self.declaration = types.SimpleNamespace(text='VAR x : BOOL; END_VAR')
        self.implementation = types.SimpleNamespace(text='x := FALSE;')
        program = types.SimpleNamespace(get_name=lambda: 'Protected',
            textual_declaration=self.declaration, textual_implementation=self.implementation,
            get_children=lambda recursive: [])
        self.hook_text = types.SimpleNamespace(text='RequiredHook();')
        hook = types.SimpleNamespace(get_name=lambda: 'GeneratedHook',
            textual_implementation=self.hook_text, get_children=lambda recursive: [])
        self.builds = self.cleans = self.saves = 0
        self.symbol_variable = types.SimpleNamespace(name='x', configured_access='ReadWriteExecute')
        signature = types.SimpleNamespace(full_qualified_name='Application', library_id=None, variables=[self.symbol_variable])
        self.signature = signature
        self.after_build = lambda: None
        symbols = types.SimpleNamespace(get_name=lambda: 'Symbols', is_symbol_config=True,
            get_only_configured_signatures=lambda: [signature], get_only_configured_datatypes=lambda: [],
            client_side_layout_calculator_guid='fixture', enable_direct_io_access=False, content_feature_flags=0,
            symbol_attribute_filter_type=0, symbol_attribute_filter_data='', symbol_comment_filter_type=0)
        self.symbol_config = symbols
        self.app = types.SimpleNamespace(get_name=lambda: 'Application',
            get_children=lambda recursive: [program, hook, symbols], clean=self.clean, build=self.build)
        symbols.get_children = lambda recursive: []
        self.mapping = types.SimpleNamespace(variable='Application.x', automatic_iec_address='%IX0.0',
            manual_iec_address='', maps_to_existing_variable=True)
        channel = types.SimpleNamespace(is_mappable_io=True, io_mapping=self.mapping,
            identifier='1', name='Input', bit_size=1, channel_type='Input', has_sub_elements=False)
        device = types.SimpleNamespace(get_name=lambda: 'Device', is_device=True,
            get_device_identification=lambda: types.SimpleNamespace(type=1, id='fixture', version='1'),
            connectors=[types.SimpleNamespace(host_parameters=[channel])], get_children=lambda recursive: [])
        self.project = types.SimpleNamespace(path=str(self.project_path), active_application=self.app,
            dirty=False, save=self.save, get_children=lambda recursive: [device, self.app])
        self.online = types.SimpleNamespace(is_logged_in=False)
        self.messages = {'build': [], 'checks': []}
        self.module = types.ModuleType('scriptengine')
        self.module.projects = types.SimpleNamespace(primary=self.project)
        self.module.online = types.SimpleNamespace(create_online_application=lambda app: self.online)
        self.module.system = types.SimpleNamespace(get_message_categories=lambda: ['build', 'checks'],
            get_message_category_description=lambda c: {'build': 'Build', 'checks': 'Additional code checks'}[c],
            clear_messages=lambda c: self.messages[c].clear(), get_message_objects=lambda c: self.messages[c])
        self.new_messages = [types.SimpleNamespace(severity='Warning', text='reviewed fixture warning')]
        self.job = dict(operationId='test-operation', phase='preflight', project=str(self.project_path),
            engineeringRoot=str(ENGINEERING_ROOT), preserveObjects=['Application/Protected'],
            hooks=[dict(object='Application/GeneratedHook', tokens=['RequiredHook'])],
            allowedWarnings=['reviewed fixture warning'])

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        self.saves += 1
        self.project.dirty = False

    def clean(self):
        self.cleans += 1

    def build(self):
        self.builds += 1
        self.messages['build'].extend(self.new_messages)
        self.after_build()

    def run_phase(self, phase):
        self.job['phase'] = phase
        (self.folder / 'job.json').write_text(json.dumps(self.job), encoding='utf-8')
        script = self.folder / 'build_existing.py'
        script.write_bytes((HERE / script.name).read_bytes())
        with patch.dict(sys.modules, {'scriptengine': self.module}), contextlib.redirect_stdout(io.StringIO()), warnings.catch_warnings():
            # The production host is IronPython 2, which uses datetime.utcnow().
            warnings.simplefilter('ignore', DeprecationWarning)
            try:
                runpy.run_path(str(script), init_globals={'unicode': str})
            except RuntimeError:
                pass
        return json.loads((self.folder / (phase + '.json')).read_text(encoding='utf-8'))

    def test_wrong_project_stops_before_save(self):
        self.project.path = str(self.folder / 'wrong.project')
        result = self.run_phase('preflight')
        self.assertFalse(result['complete'])
        self.assertEqual(self.saves, 0)

    def test_cold_session_registers_messages_during_first_build(self):
        self.run_phase('preflight')
        self.module.system.get_message_categories = lambda: ['build', 'checks'] if self.builds else []
        result = self.run_phase('build')
        self.assertTrue(result['complete'])
        self.assertEqual(result['warnings'], 1)
        self.assertEqual(self.builds, 1)

    def test_missing_messages_after_build_cannot_pass(self):
        self.run_phase('preflight')
        self.module.system.get_message_categories = lambda: []
        result = self.run_phase('build')
        self.assertFalse(result['complete'])
        self.assertIn('unavailable after native build', result['exception'])
        self.assertEqual(self.saves, 1)

    def test_unresolved_library_namespace_cannot_be_the_preflight_baseline(self):
        datatype = types.SimpleNamespace(full_qualified_name='.FixtureType', library_id='fixture, 1.0.0.0',
                                         variables=[self.symbol_variable])
        self.symbol_config.get_only_configured_datatypes = lambda: [datatype]
        result = self.run_phase('preflight')
        self.assertFalse(result['complete'])
        self.assertIn('run native compile_project once', result['exception'])
        self.assertEqual(self.builds, 0)

    def test_online_stops_before_save(self):
        self.online.is_logged_in = True
        result = self.run_phase('preflight')
        self.assertIn('online', result['exception'])
        self.assertEqual(self.saves, 0)

    def test_protected_change_stops_before_build(self):
        self.assertTrue(self.run_phase('preflight')['complete'])
        self.implementation.text = 'x := TRUE;'
        result = self.run_phase('build')
        self.assertIn('protected PLC source', result['exception'])
        self.assertEqual(self.builds, 0)

    def test_io_change_stops_before_build(self):
        self.run_phase('preflight')
        self.mapping.variable = 'Application.other'
        result = self.run_phase('build')
        self.assertIn('I/O bindings', result['exception'])
        self.assertEqual(self.builds, 0)

    def test_missing_hook_stops_before_build(self):
        self.run_phase('preflight')
        self.hook_text.text = 'OtherHook();'
        result = self.run_phase('build')
        self.assertIn('hook token', result['exception'])
        self.assertEqual(self.builds, 0)

    def test_symbol_access_change_stops_before_save(self):
        self.run_phase('preflight')
        self.symbol_variable.configured_access = 'ReadOnly'
        result = self.run_phase('build')
        self.assertIn('symbol access', result['exception'])
        self.assertEqual(self.builds, 1)
        self.assertEqual(self.saves, 1)  # Only the original preflight save.

    def test_symbol_type_cache_is_refreshed_after_clean_build(self):
        self.run_phase('preflight')
        self.signature.full_qualified_name = '.Application'
        self.after_build = lambda: setattr(self.signature, 'full_qualified_name', 'Application')
        result = self.run_phase('build')
        self.assertTrue(result['complete'])
        self.assertTrue(result['existingSymbolAccessesPreserved'])

    def test_new_warning_fails_even_with_same_warning_count(self):
        self.run_phase('preflight')
        self.new_messages[0].text = 'unreviewed warning'
        result = self.run_phase('build')
        self.assertFalse(result['complete'])
        self.assertEqual(result['warnings'], 1)
        self.assertFalse(result['warningBaselineMatches'])

    def test_native_warning_spacing_matches_adapter_baseline(self):
        self.run_phase('preflight')
        self.new_messages[0].text = 'reviewed  fixture warning'
        result = self.run_phase('build')
        self.assertTrue(result['complete'])
        self.assertEqual(result['messages'][0]['text'], 'reviewed  fixture warning')

    def test_fresh_error_is_reported(self):
        self.run_phase('preflight')
        self.new_messages.append(types.SimpleNamespace(severity='Error', text='compile error'))
        result = self.run_phase('build')
        self.assertFalse(result['complete'])
        self.assertEqual(result['errors'], 1)

    def test_success_uses_fresh_messages_and_preserves_recovery_copy(self):
        self.assertTrue(self.run_phase('preflight')['complete'])
        self.messages['build'].append(types.SimpleNamespace(severity='Error', text='stale error'))
        result = self.run_phase('build')
        self.assertTrue(result['complete'])
        self.assertEqual((result['errors'], result['warnings'], result['boundIoCount']), (0, 1, 1))
        self.assertEqual((self.cleans, self.builds), (1, 1))
        self.assertEqual((self.folder / 'before.project').read_bytes(), b'offline fixture')


if __name__ == '__main__':
    unittest.main()

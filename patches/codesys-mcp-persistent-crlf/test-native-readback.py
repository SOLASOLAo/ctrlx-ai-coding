"""Run state/library templates with doubles, never a PLC, CLR or broker."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE
PROJECT = 'C:/fixture/Consumer.project'


class Utf8Capture(io.StringIO):
    def write(self, value):
        return super().write(value.decode('utf-8') if isinstance(value, bytes) else value)


class Online:
    def __init__(self, state='run', logged_in=True):
        self.application_state, self.is_logged_in = state, logged_in
        self.calls = []
        self.failure = None
        self.no_change = False

    def logout(self):
        self.calls.append('logout')
        if self.failure:
            raise RuntimeError(self.failure)
        if not self.no_change:
            self.is_logged_in = False

    def stop(self):
        self.calls.append('stop')
        if self.application_state == 'stop':
            raise RuntimeError('Already STOP')
        if not self.no_change:
            self.application_state = 'stop'

    def start(self):
        self.calls.append('start')
        if not self.no_change:
            self.application_state = 'run'


class LibraryManager:
    def __init__(self, references=()):
        self.references = list(references)
        self.failure = None
        self.reads = 0

    def get_libraries(self):
        self.reads += 1
        if self.failure:
            raise RuntimeError(self.failure)
        return self.references

    def get_children(self, recursive):
        return []  # Native references need not appear as project tree children.


class Application:
    is_application = True

    def __init__(self, manager=None):
        self.manager = manager

    def get_library_manager(self):
        return self.manager


class Readback(unittest.TestCase):
    def setUp(self):
        self.online = Online()
        self.manager = LibraryManager()
        self.application = Application(self.manager)
        self.project = SimpleNamespace(path=PROJECT, active_application=self.application,
                                       get_children=lambda recursive: [self.application])
        self.constructions = 0
        self.construct_failure = None

    def run_template(self, name, action='stop'):
        def construct(application):
            self.assertIs(application, self.application)
            self.constructions += 1
            if self.construct_failure:
                raise RuntimeError(self.construct_failure)
            return self.online
        engine = SimpleNamespace(projects=SimpleNamespace(primary=self.project),
                                 online=SimpleNamespace(create_online_application=construct))
        source = (SCRIPTS / name).read_text(encoding='utf-8-sig')
        source = source.replace('{PROJECT_FILE_PATH}', PROJECT).replace('{APP_ACTION}', action)
        output = Utf8Capture()
        namespace = dict(unicode=str, _to_unicode=str, with_executor=lambda fn, *args: fn(*args))
        with patch.dict(sys.modules, {'scriptengine': engine}), contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as exit:
                exec(compile(source, str(SCRIPTS / name), 'exec'), namespace)
        text = output.getvalue()
        if exit.exception.code:
            self.assertIn('SCRIPT_ERROR:', text)
            self.assertNotIn('SCRIPT_SUCCESS:', text)
        else:
            self.assertIn('SCRIPT_SUCCESS:', text)
            self.assertNotIn('SCRIPT_ERROR:', text)
        return exit.exception.code, text

    def test_constructor_error_is_not_logout_success(self):
        self.construct_failure = 'Stack empty'
        code, text = self.run_template('disconnect_from_device.py')
        self.assertEqual(code, 1)
        self.assertIn('Stack empty', text)
        self.assertTrue(self.online.is_logged_in)

    def test_logout_exception_is_not_success(self):
        self.online.failure = 'logout failed'
        self.assertEqual(self.run_template('disconnect_from_device.py')[0], 1)

    def test_logout_return_without_state_change_is_not_success(self):
        self.online.no_change = True
        self.assertEqual(self.run_template('disconnect_from_device.py')[0], 1)
        self.assertTrue(self.online.is_logged_in)

    def test_logout_success_requires_false_readback(self):
        self.assertEqual(self.run_template('disconnect_from_device.py')[0], 0)
        self.assertIs(self.online.is_logged_in, False)
        self.assertEqual(self.online.calls, ['logout'])

    def test_already_logged_out_is_verified_without_logout(self):
        self.online.is_logged_in = False
        self.assertEqual(self.run_template('disconnect_from_device.py')[0], 0)
        self.assertEqual(self.online.calls, [])

    def test_wrong_project_does_not_construct_or_change_online_state(self):
        self.project.path = 'C:/fixture/Other.project'
        self.assertEqual(self.run_template('disconnect_from_device.py')[0], 1)
        self.assertEqual(self.constructions, 0)
        self.assertEqual(self.online.calls, [])

    def test_stop_in_stop_is_verified_without_duplicate_stop(self):
        self.online.application_state = 'stop'
        self.assertEqual(self.run_template('start_stop_application.py')[0], 0)
        self.assertEqual(self.online.calls, [])

    def test_stop_from_run_checks_stop_readback(self):
        self.assertEqual(self.run_template('start_stop_application.py')[0], 0)
        self.assertEqual(self.online.application_state, 'stop')
        self.assertEqual(self.online.calls, ['stop'])

    def test_unchanged_run_is_not_stop_success(self):
        self.online.no_change = True
        self.assertEqual(self.run_template('start_stop_application.py')[0], 1)

    def test_unknown_state_is_not_success(self):
        self.online.application_state = None
        self.assertEqual(self.run_template('start_stop_application.py')[0], 1)
        self.assertEqual(self.online.calls, [])

    def test_start_in_run_does_not_repeat_start(self):
        self.assertEqual(self.run_template('start_stop_application.py', 'start')[0], 0)
        self.assertEqual(self.online.calls, [])

    def test_start_from_stop_checks_run_readback(self):
        self.online.application_state = 'stop'
        self.assertEqual(self.run_template('start_stop_application.py', 'start')[0], 0)
        self.assertEqual(self.online.application_state, 'run')
        self.assertEqual(self.online.calls, ['start'])

    def test_unlogged_state_cannot_certify_runtime_stop(self):
        self.online.is_logged_in = False
        self.assertEqual(self.run_template('start_stop_application.py')[0], 1)
        self.assertEqual(self.online.calls, [])

    def test_library_references_are_read_even_with_empty_manager_children(self):
        self.manager.references = ['InntaiLeakTest, 1.1.0.1 (InntaiLeakTestLib)', '\u6c14\u5bc6\u5e93, 2.0']
        code, text = self.run_template('list_project_libraries.py')
        self.assertEqual(code, 0)
        payload = text.split('### LIBRARIES_START ###\n')[1].split('### LIBRARIES_END ###')[0]
        libraries = json.loads(payload)
        self.assertEqual([entry['name'] for entry in libraries], self.manager.references)
        self.assertEqual(self.manager.reads, 1)

    def test_missing_manager_is_not_successful_empty_list(self):
        self.application.manager = None
        code, text = self.run_template('list_project_libraries.py')
        self.assertEqual(code, 1)
        self.assertNotIn('### LIBRARIES_START ###', text)

    def test_failed_enumeration_is_not_successful_empty_list(self):
        self.manager.failure = 'enumeration failed'
        self.assertEqual(self.run_template('list_project_libraries.py')[0], 1)

    def test_confirmed_empty_native_enumeration_is_valid(self):
        code, text = self.run_template('list_project_libraries.py')
        self.assertEqual(code, 0)
        self.assertIn('### LIBRARIES_START ###\n[]\n', text)
        self.assertEqual(self.manager.reads, 1)

    def test_multiple_applications_need_explicit_active_scope(self):
        self.project.active_application = None
        self.project.get_children = lambda recursive: [self.application, Application()]
        self.assertEqual(self.run_template('list_project_libraries.py')[0], 1)
        self.assertEqual(self.manager.reads, 0)

    def test_wrong_project_does_not_enumerate_libraries(self):
        self.project.path = 'C:/fixture/Other.project'
        self.assertEqual(self.run_template('list_project_libraries.py')[0], 1)
        self.assertEqual(self.manager.reads, 0)

    def test_library_project_uses_its_native_manager(self):
        self.project.active_application = None
        self.project.get_children = lambda recursive: []
        self.project.get_library_manager = lambda: self.manager
        self.manager.references = ['Dependency, 1.0']
        self.assertEqual(self.run_template('list_project_libraries.py')[0], 0)
        self.assertEqual(self.manager.reads, 1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--scripts-dir', type=Path, default=HERE)
    args, remaining = parser.parse_known_args()
    SCRIPTS = args.scripts_dir
    unittest.main(argv=[sys.argv[0]] + remaining)

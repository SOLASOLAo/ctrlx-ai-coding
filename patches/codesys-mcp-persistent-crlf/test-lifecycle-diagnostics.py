"""Offline watcher-stage and borrowed online-executor checks; no CLR/IDE calls."""
import ast
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import traceback
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
ONLINE_HELPER = (Path(os.environ['APPDATA']) / 'npm/node_modules/codesys-mcp-persistent'
                 / 'dist/scripts/ensure_online_connection.py')


def load_definitions(source, names, namespace):
    tree = ast.parse(source.read_text(encoding='utf-8-sig'))
    nodes = [node for node in ast.walk(tree)
             if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names]
    if {node.name for node in nodes} != set(names):
        raise AssertionError('Expected definitions missing from ' + str(source))
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), 'exec'), namespace)


class BorrowedExecutor:
    def __init__(self):
        self.calls = 0
        self.failure = False

    def ExecuteSource(self, source):
        self.calls += 1
        if self.failure:
            raise RuntimeError('executor failure')
        exec(source, {})

    def Dispose(self):
        raise AssertionError('The online executor is borrowed, not owned by with_executor')


class OnlineLifecycle(unittest.TestCase):
    def setUp(self):
        self.builtins = ModuleType('__builtin__')
        alias = patch.dict(sys.modules, {'__builtin__': self.builtins})
        alias.start()
        self.addCleanup(alias.stop)
        self.executor = BorrowedExecutor()
        self.namespace = {'_get_online_executor': lambda: self.executor}
        load_definitions(ONLINE_HELPER, ['with_executor'], self.namespace)

    def assert_clean(self):
        self.assertFalse([name for name in vars(self.builtins) if name.startswith('_mcp_online_')])

    def test_return_and_cleanup_without_disposing_borrowed_executor(self):
        self.assertEqual(self.namespace['with_executor'](lambda x: x + 1, 41), 42)
        self.assertEqual(self.executor.calls, 1)
        self.assert_clean()

    def test_wrapped_exception_and_cleanup(self):
        def fail():
            raise ValueError('call failure')
        with self.assertRaisesRegex(ValueError, 'call failure'):
            self.namespace['with_executor'](fail)
        self.assert_clean()

    def test_executor_exception_and_cleanup(self):
        self.executor.failure = True
        with self.assertRaisesRegex(RuntimeError, 'executor failure'):
            self.namespace['with_executor'](lambda: None)
        self.assert_clean()

    def test_no_executor_uses_direct_call(self):
        self.namespace['_get_online_executor'] = lambda: None
        self.assertEqual(self.namespace['with_executor'](lambda: 42), 42)
        self.assertEqual(self.executor.calls, 0)
        self.assert_clean()


class TraceCut(BaseException):
    """Stop a stub at a boundary without a blocking thread or real wait."""


class EventStub:
    def __init__(self, initial):
        self.signalled = initial
        self.waits = []

    def Set(self):
        self.signalled = True

    def WaitOne(self, milliseconds):
        self.waits.append(milliseconds)
        return self.signalled


class WatcherStages(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.request = 'fixture-request'
        self.logs, self.results, self.events = [], [], []
        def event(initial):
            created = EventStub(initial)
            self.events.append(created)
            return created
        self.namespace = dict(os=os, sys=sys, time=time, traceback=traceback, json=json,
                              COMMANDS_DIR=str(self.root), RESULTS_DIR=str(self.root),
                              _log=self.logs.append, ManualResetEvent=event,
                              atomic_write=lambda path, value: self.results.append(json.loads(value)),
                              se=SimpleNamespace(system=SimpleNamespace(
                                  execute_on_primary_thread=lambda callback: callback())))
        load_definitions(HERE / 'watcher.py.patched',
                         ['OutputCapture', '_do_exec', 'process_command'], self.namespace)

    def run_script(self, code):
        script = self.root / (self.request + '.py')
        script.write_text(code, encoding='utf-8')
        command = self.request + '.command.json'
        (self.root / command).write_text(json.dumps({'scriptPath': str(script)}), encoding='utf-8')
        self.namespace['process_command'](command)

    def test_success_keeps_result_and_stage_order(self):
        self.run_script("print('SCRIPT_SUCCESS')\n")
        self.assertEqual(self.logs[:4], [
            'Processing command: ' + self.request,
            'Marshaling to primary thread... requestId=' + self.request,
            'Primary thread entered: ' + self.request,
            'Primary marshal returned: ' + self.request])
        self.assertTrue(self.results[0]['success'])
        self.assertEqual(self.results[0]['requestId'], self.request)
        self.assertEqual(self.results[0]['output'], 'SCRIPT_SUCCESS\n')
        self.assertEqual(self.events[0].waits, [120000])

    def test_script_failure_keeps_terminal_failure(self):
        self.run_script("raise RuntimeError('script failure')\n")
        self.assertFalse(self.results[0]['success'])
        self.assertIn('script failure', self.results[0]['error'])
        self.assertIn('Primary marshal returned: ' + self.request, self.logs)

    def test_cut_before_callback_has_no_entry_or_wait_or_result(self):
        def dispatch(callback):
            raise TraceCut()
        self.namespace['se'].system.execute_on_primary_thread = dispatch
        with self.assertRaises(TraceCut):
            self.run_script('pass\n')
        self.assertNotIn('Primary thread entered: ' + self.request, self.logs)
        self.assertEqual(self.events[0].waits, [])
        self.assertEqual(self.results, [])

    def test_cut_inside_callback_records_entry_and_restores_output(self):
        def execute(code, namespace):
            raise TraceCut()
        self.namespace['_do_exec'] = execute
        old_stdout, old_stderr = sys.stdout, sys.stderr
        with self.assertRaises(TraceCut):
            self.run_script('pass\n')
        self.assertIn('Primary thread entered: ' + self.request, self.logs)
        self.assertNotIn('Primary marshal returned: ' + self.request, self.logs)
        self.assertEqual(self.events[0].waits, [])
        self.assertEqual(self.results, [])
        self.assertIs(sys.stdout, old_stdout)
        self.assertIs(sys.stderr, old_stderr)


if __name__ == '__main__':
    unittest.main()

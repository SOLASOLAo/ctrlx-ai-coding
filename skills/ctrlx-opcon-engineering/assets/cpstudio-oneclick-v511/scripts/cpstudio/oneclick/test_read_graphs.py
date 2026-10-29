import copy
import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('oneclick_graphs', HERE / 'read_graphs.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
spec = importlib.util.spec_from_file_location('existing_graph_format', HERE.parents[1] / 'plc' / 'sfc_graph_key.py')
formatting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(formatting)


class GraphGuards(unittest.TestCase):
    def setUp(self):
        self.before = dict(operationId='operation', graphs={'Application/Chain': dict(
            implementation='<SFC><step name="N000"/></SFC>', children=['N000', 'Finish'],
            language='SFC', elementProperties={'build': {'exclude': False}})})
        self.after = copy.deepcopy(self.before)

    def test_child_order_does_not_invent_a_graph_change(self):
        self.after['graphs']['Application/Chain']['children'].reverse()
        reader.verify(self.before, self.after, formatting.graph_key)

    def test_step_change_is_rejected(self):
        self.after['graphs']['Application/Chain']['implementation'] = '<SFC><step name="N100"/></SFC>'
        with self.assertRaisesRegex(RuntimeError, 'SFC graph'):
            reader.verify(self.before, self.after, formatting.graph_key)

    def test_sfc_flags_change_is_rejected(self):
        self.after['graphs']['Application/Chain']['elementProperties']['build']['exclude'] = True
        with self.assertRaisesRegex(RuntimeError, 'SFC properties'):
            reader.verify(self.before, self.after, formatting.graph_key)

    def test_stale_operation_is_rejected(self):
        self.after['operationId'] = 'another-operation'
        with self.assertRaisesRegex(RuntimeError, 'this operation'):
            reader.verify(self.before, self.after, formatting.graph_key)

    def test_portable_after_uses_bundled_helper_without_sidecar_module(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            job_file = root / 'job.json'
            job = dict(operationId='operation', engineeringRoot=str(root / 'sidecar'),
                       project=str(root / 'target.project'), profile='test profile',
                       restBase='http://127.0.0.1:12001/api/v2',
                       graphicalObjects=[dict(path='Application/Chain', apiPath='/chain')])
            job_file.write_text(json.dumps(job), encoding='utf-8')
            (root / 'before-graphs.json').write_text(json.dumps(self.before), encoding='utf-8')
            responses = {'/projects/current': dict(path=job['project'], profileName=job['profile']),
                         '/devices/Device/Plc%20Logic/Application': dict(isOnline=False),
                         '/chain': self.after['graphs']['Application/Chain']}
            def get(url, timeout):
                self.assertEqual(timeout, 20)
                return io.BytesIO(json.dumps(responses[url[len(job['restBase']):]]).encode('utf-8'))
            with patch.object(reader.urllib.request, 'build_opener') as opener, \
                    patch.object(reader.sys, 'argv', ['read_graphs.py', str(job_file), 'after']), \
                    contextlib.redirect_stdout(io.StringIO()):
                opener.return_value.open.side_effect = get
                reader.main()
            self.assertEqual(json.loads((root / 'after-graphs.json').read_text(encoding='utf-8')), self.before)

    def test_project_helper_takes_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = pathlib.Path(directory) / 'scripts' / 'plc' / 'sfc_graph_key.py'
            helper.parent.mkdir(parents=True)
            helper.write_text("def graph_key(text): return 'project:' + text\n", encoding='utf-8')
            self.assertEqual(reader.load_graph_key(directory)('graph'), 'project:graph')

    def test_broken_project_helper_is_not_replaced_by_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = pathlib.Path(directory) / 'scripts' / 'plc' / 'sfc_graph_key.py'
            helper.parent.mkdir(parents=True)
            helper.write_text('def graph_key(:\n', encoding='utf-8')
            with self.assertRaises(SyntaxError):
                reader.load_graph_key(directory)


if __name__ == '__main__':
    unittest.main()

"""Offline HTTP/SSE boundary checks. All network access is replaced by a fake opener."""
import importlib.util
import io
import json
from email.message import Message
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'skills/ctrlx-opcon-engineering/scripts/read_core_datalayer.py'
spec = importlib.util.spec_from_file_location('core_reader', SOURCE)
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)


class Response(io.BytesIO):
    status = 200

    def __init__(self, body=b'{}', chunks=None):
        super().__init__(body)
        self.headers = Message()
        self.headers['Content-Type'] = 'text/event-stream' if chunks is not None else 'application/json'
        self.chunks = list(chunks or [])

    def read1(self, size):
        return self.chunks.pop(0) if self.chunks else b''


class CoreReadOnlyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.config = Path(self.temporary.name) / 'target.xml'
        self.config.write_text('<Target><Hostname>core.invalid</Hostname><Username>fixture</Username>'
                               '<Password>fixture-password</Password></Target>', encoding='utf-8')
        self.opener_patch = patch.object(core.urllib.request, 'build_opener')
        self.opener = self.opener_patch.start().return_value
        self.addCleanup(self.opener_patch.stop)

    def reader(self, *responses):
        self.opener.open.side_effect = [Response(b'{"access_token":"fixture-token"}'), *responses]
        return core.CoreReader(self.config, 'core.invalid')

    def test_target_mismatch_sends_nothing(self):
        with self.assertRaises(ValueError):
            core.CoreReader(self.config, 'other.invalid')
        self.opener.open.assert_not_called()

    def test_only_authentication_post_then_reads(self):
        reader = self.reader(Response(), Response(), Response())
        for mode in ('read', 'browse', 'metadata'):
            self.assertEqual(reader.read('plc/app/value', mode)['httpStatus'], 200)
        requests = [call.args[0] for call in self.opener.open.call_args_list]
        self.assertEqual([r.get_method() for r in requests], ['POST', 'GET', 'GET', 'GET'])
        self.assertTrue(all(r.full_url.startswith('https://core.invalid/') for r in requests))

    def test_fragmented_sse_closes_without_reconnect(self):
        response = Response(chunks=[b'event: up', b'date\r\ndata: {"value":', b'42}\r\n\r\n'])
        reader = self.reader(response)
        events = []
        self.assertTrue(reader.subscribe(['plc/app/value'], 1, 250, events.append))
        self.assertEqual(events[1]['data'], {'value': 42})
        self.assertFalse(events[-1]['automaticReconnect'])
        self.assertTrue(response.closed)
        self.assertEqual(self.opener.open.call_count, 2)

    def test_sse_error_is_failure_not_retried(self):
        reader = self.reader(Response(chunks=[b'event: error\ndata: unavailable\n\n']))
        events = []
        self.assertFalse(reader.subscribe(['plc/app/value'], 1, 250, events.append))
        self.assertEqual(events[-1]['errors'], 1)
        self.assertEqual(self.opener.open.call_count, 2)

    def test_nested_credentials_are_redacted(self):
        result = core.readable({'data': json.dumps({'password': 'fixture-password', 'value': 42})})
        self.assertEqual(result, {'data': {'password': '<redacted>', 'value': 42}})

    def test_invalid_nodes_are_rejected(self):
        for node in ('/absolute', 'a/../b', 'a?type=write', 'a\\b', 'a\nb'):
            with self.subTest(node=node), self.assertRaises(core.argparse.ArgumentTypeError):
                core.node_path(node)

    def test_existing_output_is_preserved_before_authentication(self):
        output = Path(self.temporary.name) / 'samples.jsonl'
        output.write_text('existing evidence', encoding='utf-8')
        args = ['reader', '--target-config', str(self.config), '--expect-host', 'core.invalid',
                '--node', 'plc/app/value', '--output', str(output)]
        with patch.object(core.sys, 'argv', args), patch.object(core.sys, 'stderr', io.StringIO()):
            self.assertEqual(core.main(), 2)
        self.assertEqual(output.read_text(encoding='utf-8'), 'existing evidence')
        self.opener.open.assert_not_called()


if __name__ == '__main__':
    unittest.main()

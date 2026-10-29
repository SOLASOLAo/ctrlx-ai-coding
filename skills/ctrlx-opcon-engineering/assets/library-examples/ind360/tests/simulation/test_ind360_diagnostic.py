"""Run the real PowerShell diagnostic against loopback only; no physical devices."""
import json
import os
from pathlib import Path
import queue
import shutil
import socketserver
import subprocess
import threading
import time

from ind360_wire import Endpoint


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/diagnostics/Test-Ind360.ps1'
POWERSHELL = shutil.which('powershell.exe') or shutil.which('pwsh')


def run_ps(arguments, text=None, **environment):
    result = subprocess.run(
        [POWERSHELL, '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', *arguments],
        input=text, capture_output=True, encoding='utf-8', errors='replace', timeout=35,
        env={**os.environ, 'IND360_TEST_SCRIPT': str(SCRIPT), **environment},
    )
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    return result.stdout


def wire_check():
    cases = [
        ('SI', [b'S S    ', b'4.320 kg\r', b'\n'], 'OK', False),
        ('SI', [b'S D     -0.125 kg\r\n'], 'OK', False),
        ('S', [b'S S      4.320 kg\r\n'], 'OK', False),
        ('TA', [b'TA A      1.250 kg\r\n'], 'OK', False),
        ('I2', [b'I2 A "IND360 Analog"\r\n'], 'OK', False),
        ('I3', [b'I3 A "2.08.0000"\r\n'], 'OK', False),
        ('I4', [b'I4 A "C631296220"\r\n'], 'OK', False),
        ('Z', [b'Z A\r\n'], 'OK', False),
        ('T', [b'T S      1.250 kg\r\n'], 'OK', False),
        ('TAC', [b'TAC A\r\n'], 'OK', False),
        ('SI', [b'S I\r\n'], 'REJECTED', False),
        ('Z', [b'Z I\r\n'], 'REJECTED', False),
        ('I2', [b'ES\r\n'], 'REJECTED', False),
        ('SI', [b'I3 A "wrong command"\r\n'], 'BAD_REPLY', False),
        ('SI', [b'S S 1 kg'], 'TRANSPORT_ERROR', False),
        ('SI', None, 'TRANSPORT_ERROR', False),
        ('SI', [b'X' * 4100], 'TRANSPORT_ERROR', False),
        ('Z', [], 'TRANSPORT_ERROR', True),
        ('T', [b'Z A\r\n'], 'BAD_REPLY', True),
    ]
    pending = queue.Queue()
    received = []
    for case in cases:
        pending.put(case)

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            expected, chunks, _, _ = pending.get(timeout=2)
            self.request.settimeout(2)
            wire = b''
            while not wire.endswith(b'\r\n'):
                piece = self.request.recv(32)
                if not piece:
                    break
                wire += piece
            received.append(wire)
            if chunks is None:
                time.sleep(0.7)
            else:
                try:
                    for chunk in chunks:
                        self.request.sendall(chunk)
                        time.sleep(0.02)
                except OSError:
                    pass

    with Endpoint(('127.0.0.1', 0), Handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        output = run_ps(['-Command', '''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. $env:IND360_TEST_SCRIPT
$commands = $env:IND360_TEST_COMMANDS.Split(',')
$results = foreach ($command in $commands) {
  Invoke-Ind360Command -TargetIp '127.0.0.1' -Port ([int]$env:IND360_TEST_PORT) -Command $command -TimeoutMs 350
}
ConvertTo-Json -InputObject @($results) -Compress
'''], IND360_TEST_PORT=str(server.server_address[1]),
            IND360_TEST_COMMANDS=','.join(case[0] for case in cases))
        results = json.loads(output)
        assert len(results) == len(cases)
        for case, result in zip(cases, results):
            assert (result['Status'], result['OutcomeUnknown']) == case[2:], (case, result)
        assert results[14]['Reply'] == 'S S 1 kg', results[14]
        assert received == [case[0].encode() + b'\r\n' for case in cases], received
        server.shutdown()
    print(f'PASS: {len(cases)} actual PowerShell TCP cases; commands sent once; partial replies preserved.')


def menu_and_log_check():
    received = []
    replies = {
        b'SI': b'S S 4.320 kg\r\n', b'I2': b'I2 A "IND360 Analog"\r\n',
        b'I3': b'I3 A "2.08.0000"\r\n', b'I4': b'I4 A "C631296220"\r\n',
        b'TA': b'TA A 0.000 kg\r\n', b'Z': b'',
    }

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(2)
            wire = b''
            while not wire.endswith(b'\r\n'):
                piece = self.request.recv(32)
                if not piece:
                    return
                wire += piece
            received.append(wire)
            self.request.sendall(replies[wire[:-2]])

    logs = ROOT / 'data/reports/ind360'
    before = set(logs.glob('IND360-*.txt'))
    with Endpoint(('127.0.0.1', 0), Handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        args = ['-File', str(SCRIPT), '-TargetIp', '127.0.0.1', '-Port', str(server.server_address[1])]
        output = run_ps([*args, '-ReadOnly'])
        reads = [b'SI\r\n', b'I2\r\n', b'I3\r\n', b'I4\r\n', b'TA\r\n']
        assert received == reads, received
        received.clear()
        # Cancel one zero request, confirm one, then attempt another after the lost ACK.
        output += run_ps(args, '\n\n5\nwrong\n5\nZ\n5\n0\n')
        assert received == [*reads, b'Z\r\n'], received
        assert '已取消，未发送' in output
        assert '上次控制结果不确定' in output
        server.shutdown()
    created = set(logs.glob('IND360-*.txt')) - before
    assert len(created) == 2, created
    log_text = '\n'.join(path.read_text(encoding='utf-8-sig') for path in created)
    for expected in ['127.0.0.1', 'TX SI<CR><LF>', 'RX S S 4.320 kg<CR><LF>',
                     'C631296220', 'TRANSPORT_ERROR', '命令可能已经执行', '当前选路']:
        assert expected in log_text, (expected, log_text)
    print('PASS: default reads, explicit control confirmation, uncertain-control lock, UTF-8 Chinese transcript.')
    print('Loopback test logs:', ', '.join(str(path) for path in sorted(created)))


if __name__ == '__main__':
    assert POWERSHELL, 'Windows PowerShell or pwsh is required.'
    wire_check()
    menu_and_log_check()

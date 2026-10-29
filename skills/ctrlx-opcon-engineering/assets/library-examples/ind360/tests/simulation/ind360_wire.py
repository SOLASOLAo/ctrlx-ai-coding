"""Dummy MT-SICS endpoints for PC and COREvirtual; never contacts a real scale."""
import argparse
import json
from pathlib import Path
import socket
import socketserver
import threading
import time

COMMANDS = [b'SI', b'SI', b'S', b'Z', b'T', b'TAC', b'SI', b'Z', b'SI', b'SI', b'SI', b'Z', b'SI', b'SI']
REPLIES = [b'S S      4.320 kg\r\n', b'S D      4.320 kg\r\n',
           b'S S      4.320 kg\r\n', b'Z A\r\n', b'T S      1.250 kg\r\n',
           b'TAC A\r\n', b'S I\r\n', None, b'X' * 100 + b'\r\n',
           b'S S     -0.125 kg\r\n', b'Z A\r\n', b'', None,
           b'S S      x.320 kg\r\n']


class Endpoint(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def endpoints(host, first_port, log):
    servers = []
    for case, (command, reply) in enumerate(zip(COMMANDS, REPLIES)):
        def handle(self, case=case, command=command, reply=reply):
            self.request.settimeout(8)
            data = b''
            try:
                while not data.endswith(b'\r\n') and len(data) <= 8:
                    piece = self.request.recv(1)
                    if not piece:
                        return
                    data += piece
                log.append(dict(case=case, request=data.hex(), correct=data == command + b'\r\n'))
                if data != command + b'\r\n':
                    self.request.sendall(b'ES\r\n')
                elif reply is None:
                    time.sleep(6)  # Explicit timeout. No automatic replay is expected.
                elif case == 0:
                    # Deliberately split the terminator and the fixed-width number.
                    for piece in [reply[:7], reply[7:-1], reply[-1:]]:
                        self.request.sendall(piece)
                        time.sleep(0.03)
                else:
                    self.request.sendall(reply)
                # Model persistent device sockets: the client owns request completion/close.
                if reply:
                    while self.request.recv(64):
                        pass
            except (OSError, TimeoutError):
                pass
        handler = type('Handler', (socketserver.BaseRequestHandler,), {'handle': handle})
        server = Endpoint((host, first_port + case if first_port else 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
    return servers


def self_check():
    log = []
    servers = endpoints('127.0.0.1', 0, log)
    try:
        for case, (command, expected) in enumerate(zip(COMMANDS, REPLIES)):
            with socket.create_connection(servers[case].server_address, timeout=1) as connection:
                connection.settimeout(0.15)
                for byte in command + b'\r\n':
                    connection.sendall(bytes([byte]))
                data = b''
                try:
                    while not data.endswith(b'\r\n'):
                        piece = connection.recv(128)
                        if not piece:
                            break
                        data += piece
                except TimeoutError:
                    assert expected is None, case
                assert data == (expected or b''), (case, data)
        assert len(log) == 14 and all(x['correct'] for x in log)
        print('PC dummy wire self-check: 14 cases passed; native ST acceptance is separate.')
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--serve', action='store_true')
    parser.add_argument('--log', type=Path)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--first-port', type=int, default=4710)
    args = parser.parse_args()
    if not args.serve:
        self_check()
    else:
        log = []
        if not 1 <= args.first_port <= 65522:
            parser.error('--first-port must be 1..65522 for fourteen endpoints')
        servers = endpoints(args.host, args.first_port, log)
        print(f'IND360 dummy endpoints {args.host}:{args.first_port}..{args.first_port + 13} ready', flush=True)
        try:
            while True:
                if args.log:
                    args.log.write_text(json.dumps(log, indent=2), encoding='utf-8')
                time.sleep(0.2)
        except KeyboardInterrupt:
            pass
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()

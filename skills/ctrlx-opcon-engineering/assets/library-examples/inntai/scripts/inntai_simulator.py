"""Local raw-stream device simulator; TCP is only a carrier for RS232 frames."""
import argparse
import json
import socket
import threading
import time
from pathlib import Path
from inntai_protocol import Stream, frame, encode_parameters, decode_parameters, make_result


class Simulator:
    def __init__(self, host='127.0.0.1', port=4546, fault='none', fragment=0, transcript=None, current_channel=1):
        self.host, self.port, self.fault, self.fragment = host, port, fault, fragment
        self.transcript = Path(transcript) if transcript else None
        self.events = []
        if current_channel not in range(32):
            raise ValueError('Current channel must be 0..31')
        self.current_channel = current_channel
        self.parameters = {i: dict(Channel=i, LeakUpper=20, LeakLower=-20, Pressure=120,
                                   PressureUpper=150, PressureLower=100) for i in range(32)}
        self.record = 1
        self.start_count = 0
        self.stop = threading.Event()
        self.listener = None

    @property
    def values(self):
        return self.parameters[self.current_channel]

    def log(self, direction, data):
        self.events.append(dict(time=time.time(), direction=direction, hex=data.hex(' ')))
        if self.transcript:
            self.transcript.parent.mkdir(parents=True, exist_ok=True)
            self.transcript.write_text(json.dumps(self.events, indent=2), encoding='utf-8')

    def send(self, conn, wire):
        self.log('TX', wire)
        size = self.fragment or len(wire)
        for i in range(0, len(wire), size):
            conn.sendall(wire[i:i+size])
            if self.fragment:
                time.sleep(.015)

    def serve(self):
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((self.host, self.port))
            self.port = listener.getsockname()[1]
            self.listener = listener
            listener.listen(2)
            listener.settimeout(.2)
            while not self.stop.is_set():
                try:
                    conn, _ = listener.accept()
                except socket.timeout:
                    continue
                with conn:
                    conn.settimeout(.1)
                    stream, pending = Stream(), None
                    try:
                        while not self.stop.is_set():
                            if pending and time.monotonic() >= pending:
                                pending = None
                                if self.fault != 'stale':
                                    self.record += 1
                                wire = make_result(self.record, int(self.values['Channel']),
                                                   leak='-12.34' if self.fault == 'negative' else '12.34',
                                                   code=2 if self.fault == 'ng' else 1)
                                if self.fault == 'bad-bcc':
                                    wire = wire[:-1] + bytes([wire[-1] ^ 1])
                                if self.fault == 'wrong-channel':
                                    wire = make_result(self.record, 31)
                                self.send(conn, wire)
                            try:
                                data = conn.recv(1024)
                            except socket.timeout:
                                continue
                            if not data:
                                break
                            self.log('RX', data)
                            for text in stream.feed(data):
                                if text == 'ST':
                                    self.start_count += 1
                                if text == 'ST' and self.fault == 'recover-once' and self.start_count == 2:
                                    continue
                                if text == 'ST' and self.fault == 'drop-start':
                                    conn.shutdown(socket.SHUT_RDWR)
                                    raise ConnectionError('injected disconnect')
                                if text == 'ST' and self.fault == 'timeout':
                                    continue
                                if text == 'ST' and self.fault in ('er1', 'er2'):
                                    self.send(conn, frame(self.fault.upper()))
                                elif text == 'ST':
                                    self.send(conn, frame('OK'))
                                    pending = time.monotonic() + .4
                                elif text == 'RT':
                                    pending = None
                                    self.send(conn, frame('OK'))
                                elif text == 'RP':
                                    self.send(conn, frame(encode_parameters(self.values)))
                                elif text.startswith('WP'):
                                    try:
                                        values = decode_parameters(text[2:])
                                        self.parameters[int(values['Channel'])] = values
                                        self.send(conn, frame('OK'))
                                    except ValueError:
                                        self.send(conn, frame('ER2'))
                                elif text == 'CS':
                                    self.send(conn, make_result(self.record, int(self.values['Channel'])))
                                else:
                                    self.send(conn, frame('ER2'))
                    except (ConnectionError, OSError):
                        pass


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host', default='127.0.0.1')
    p.add_argument('--port', type=int, default=4546)
    p.add_argument('--fault', default='none', choices=['none', 'er1', 'er2', 'timeout', 'drop-start', 'bad-bcc', 'stale', 'wrong-channel', 'negative', 'ng', 'recover-once'])
    p.add_argument('--fragment', type=int, default=0)
    p.add_argument('--channel', type=int, default=1, choices=range(32))
    p.add_argument('--transcript', default='tmp/simulator-wire.json')
    a = p.parse_args()
    s = Simulator(a.host, a.port, a.fault, a.fragment, a.transcript, a.channel)
    print(f'INNTAI simulator {a.host}:{a.port}; raw RS232 bytes, fault={a.fault}', flush=True)
    try:
        s.serve()
    except KeyboardInterrupt:
        s.stop.set()

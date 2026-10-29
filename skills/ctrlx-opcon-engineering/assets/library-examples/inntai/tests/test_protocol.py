import sys
import socket
import threading
import time
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from inntai_protocol import Stream, frame, result78, make_result, encode_parameters, decode_parameters
from inntai_simulator import Simulator


class ProtocolTests(unittest.TestCase):
    def test_known_commands(self):
        self.assertEqual(frame('ST'), bytes.fromhex('02 53 54 03 06'))
        self.assertEqual(frame('RT'), bytes.fromhex('02 52 54 03 07'))
        self.assertEqual(frame('CS'), bytes.fromhex('02 43 53 03 11'))

    def test_every_fragment_boundary_and_coalescing(self):
        wire = frame('OK') + make_result() + frame('ER2')
        expected = Stream().feed(wire)
        for n in range(len(wire)+1):
            stream = Stream()
            self.assertEqual(stream.feed(wire[:n]) + stream.feed(wire[n:]), expected)
        stream = Stream()
        self.assertEqual(sum((stream.feed(bytes([c])) for c in wire), []), expected)

    def test_binary_bcc_stx_etx(self):
        for text in ('AB', 'AC'):
            self.assertIn(frame(text)[-1], (2,3))
            self.assertEqual(Stream().feed(frame(text)+frame('OK')), [text, 'OK'])

    def test_checksum_corruption_and_zero(self):
        wire = frame('OK')[:-1] + b'\x00'
        self.assertEqual(Stream().feed(wire), [])
        self.assertEqual(Stream(True).feed(wire), ['OK'])
        self.assertEqual(Stream().feed(b'garbage\x02ab\x02'+frame('OK')[1:]), ['OK'])

    def test_vendor_workbook_fixture(self):
        # Literal Sheet1 sample; its supplied BCC 36 is not assumed to be correct.
        raw = bytes.fromhex('02 43 53 30 30 32 30 30 32 30 31 38 30 38 32 38 31 35 34 31 30 '
                            '32 30 30 30 20 20 20 20 20 20 20 20 20 20 20 20 20 20 20 20 20 '
                            '20 20 20 20 20 20 20 20 20 20 20 20 20 30 30 30 30 30 2E 30 30 '
                            '31 30 31 2D 30 30 30 30 32 2E 31 31 30 03 36')
        self.assertEqual(len(raw), 78)
        parsed = result78(raw[1:-2].decode())
        self.assertEqual(parsed['pressure'], -2.1)
        self.assertEqual(parsed['channel'], 1)
        self.assertEqual(parsed['workstation'], 1)

    def test_negative_result_and_invalid_fields(self):
        text = Stream().feed(make_result(leak='-12.34', pressure='-120.5'))[0]
        p = result78(text)
        self.assertEqual((p['leak'], p['pressure']), (-12.34, -120.5))
        for pos in (2,54,55,61,62,63,65,66,73):
            with self.assertRaises(ValueError):
                result78(text[:pos]+'X'+text[pos+1:])
        with self.assertRaises(ValueError):
            result78(text+'0')

    def test_parameters(self):
        p = dict(Channel=31, Release=99.9, LeakUpper=9999.999, LeakLower=-999.999,
                 PartVolume=99999.9, ReferenceVolume=1, Pressure=300, PressureUpper=400, PressureLower=-50)
        encoded = encode_parameters(p)
        self.assertEqual(len(encoded), 107)
        self.assertEqual(len(frame('WP'+encoded)), 112)
        read = decode_parameters(encoded)
        for k,v in p.items(): self.assertAlmostEqual(read[k],v)
        self.assertEqual(decode_parameters('WP'+encoded),read)
        for update in ({'Channel':32},{'Test':-1},{'Release':100},{'LeakLower':-1000},{'PartVolume':1e6},{'LeakUnit':4}):
            with self.assertRaises(ValueError): encode_parameters(dict(p,**update))

    def test_local_simulator_full_roundtrip(self):
        sim = Simulator(port=0, fragment=3, current_channel=0)
        thread = threading.Thread(target=sim.serve, daemon=True)
        thread.start()
        end = time.monotonic()+3
        while sim.listener is None and time.monotonic()<end: time.sleep(.01)
        try:
            with socket.create_connection(('127.0.0.1',sim.port),timeout=3) as conn:
                stream = Stream()
                def receive(n=1):
                    responses=[]
                    while len(responses)<n: responses += stream.feed(conn.recv(512))
                    return responses
                original = encode_parameters(sim.values)
                values = dict(Channel=1, LeakUpper=20, LeakLower=-20, Test=5, Pressure=321)
                conn.sendall(frame('WP'+encode_parameters(values)))
                self.assertEqual(receive(),['OK'])
                # WP emits only OK; RP is a separate operator request.
                conn.settimeout(.05)
                with self.assertRaises(socket.timeout):
                    conn.recv(512)
                conn.settimeout(3)
                conn.sendall(frame('RP')+frame('CS'))
                p,baseline=receive(2)
                self.assertEqual(p, original)
                self.assertEqual(decode_parameters(p)['Channel'],0)
                self.assertEqual(sim.current_channel,0)
                self.assertEqual(result78(baseline)['channel'],0)
                # Model the operator selecting channel 1 on the device panel.
                sim.current_channel = 1
                conn.sendall(frame('RP'))
                self.assertEqual(receive(), [encode_parameters(values)])
                conn.sendall(frame('ST'))
                ack,res=receive(2)
                self.assertEqual(ack,'OK')
                self.assertNotEqual(result78(res)['record'],result78(baseline)['record'])
                self.assertEqual(result78(res)['channel'],1)
                conn.sendall(frame('RT'))
                self.assertEqual(receive(),['OK'])
        finally:
            sim.stop.set();thread.join(3)


if __name__ == '__main__': unittest.main(verbosity=2)

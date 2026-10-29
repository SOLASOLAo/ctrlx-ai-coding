"""INNTAI RS232 codec. No Modbus. See specs/protocol.md for source offsets."""
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
from functools import reduce
from operator import xor


def frame(text: str) -> bytes:
    body = text.encode('ascii')
    if not body or any(c < 32 or c > 126 for c in body) or len(body) > 250:
        raise ValueError('invalid ASCII payload')
    wire = b'\x02' + body + b'\x03'
    return wire + bytes([reduce(xor, wire)])


class Stream:
    def __init__(self, allow_zero=False):
        self.buf = bytearray()
        self.allow_zero = allow_zero
        self.errors = 0

    def feed(self, chunk):
        out = []
        for c in chunk:
            # BCC is binary and may itself equal STX/ETX.
            if self.buf and self.buf[-1] == 3 and len(self.buf) > 2:
                wire = bytes(self.buf)
                if c == reduce(xor, wire) or (c == 0 and self.allow_zero):
                    out.append(wire[1:-1].decode('ascii'))
                else:
                    self.errors += 1
                self.buf.clear()
            elif c == 2:
                if self.buf:
                    self.errors += 1
                self.buf[:] = b'\x02'
            elif self.buf:
                if (c == 3 and len(self.buf) > 1) or 32 <= c <= 126:
                    self.buf.append(c)
                    if len(self.buf) > 252:
                        self.errors += 1
                        self.buf.clear()
                else:
                    self.errors += 1
                    self.buf.clear()
        return out


def number(text, signed=False):
    import re
    if not re.fullmatch(r'[+-]?\d+(?:\.\d+)?' if signed else r'\d+(?:\.\d+)?', text):
        raise ValueError('invalid numeric field')
    return Decimal(text)


def result78(text):
    if len(text) != 75 or not text.startswith('CS'):
        raise ValueError('expected 78-byte CS wire frame')
    p = text[2:]
    if not p[:22].isdigit() or p[52] not in '01' or p[59] not in '01234' or p[60] not in '12345678':
        raise ValueError('invalid result fields')
    if not p[61:63].isdigit() or int(p[61:63]) > 31 or p[63] not in '01+-' or p[71] not in '01':
        raise ValueError('invalid channel, sign or workstation')
    return dict(record=p[:5], timestamp=p[5:19], worker=p[19:22], part=p[22:52].rstrip(),
                leak=float(number(p[53:59]) * (-1 if p[52] == '1' else 1)),
                unit=int(p[59]), code=int(p[60]), channel=int(p[61:63]),
                pressure=float(number(p[64:71]) * (-1 if p[63] in '1-' else 1)),
                workstation=int(p[71]), reserved=p[72], ok=p[60] == '1')


PARAM_FIELDS = [
    ('Channel', 2, 0), ('Delay1', 4, 0), ('Delay2', 4, 0), ('Delay3', 4, 0),
    ('Inflate', 4, 0), ('Release', 4, 1), ('Balance1', 4, 0), ('Balance2', 4, 0),
    ('Test', 4, 0), ('Blow', 4, 0), ('Exhaust', 4, 0), ('Delay4', 4, 0),
    ('Delay5', 4, 0), ('Delay6', 4, 0), ('LeakUpper', 8, 3), ('LeakLower', 8, 3),
    ('LeakUnit', 1, 0), ('PressureUnit', 1, 0), ('PartVolume', 7, 1),
    ('ReferenceVolume', 7, 1), ('Pressure', 7, 1), ('PressureUpper', 7, 1), ('PressureLower', 7, 1)]


def encode_parameters(values):
    fields = []
    for name, width, digits in PARAM_FIELDS:
        v = Decimal(str(values.get(name, 0)))
        if not v.is_finite():
            raise ValueError(name)
        if name not in ('LeakUpper', 'LeakLower', 'Pressure', 'PressureUpper', 'PressureLower') and v < 0:
            raise ValueError(name)
        if name in ('Channel', 'LeakUnit', 'PressureUnit') and (v != int(v) or v > dict(Channel=31, LeakUnit=3, PressureUnit=7)[name]):
            raise ValueError(name)
        if digits == 0 and v != int(v):
            raise ValueError(name)
        s = format(v.quantize(Decimal(10) ** -digits, rounding=ROUND_HALF_UP), f'0{width}.{digits}f')
        if len(s) != width:
            raise ValueError(name)
        fields.append(s)
    if values.get('LeakLower', 0) > values.get('LeakUpper', 0) or values.get('PressureLower', 0) > values.get('PressureUpper', 0):
        raise ValueError('limits reversed')
    return ''.join(fields)


def decode_parameters(text):
    if len(text) == 109 and text[:2] in ('WP', 'RP'):
        text = text[2:]
    if len(text) != 107:
        raise ValueError('parameter length')
    pos, values = 0, {}
    for name, width, digits in PARAM_FIELDS:
        values[name] = float(number(text[pos:pos + width], signed=True))
        pos += width
    encode_parameters(values)  # range and consistency validation
    return values


def make_result(record=1, channel=1, leak='12.34', pressure='120.5', code=1):
    leak, pressure = Decimal(leak), Decimal(pressure)
    text = ('CS' + f'{record % 100000:05}' + '20260928120000' + '001' + 'SIM-PART'.ljust(30)
            + ('1' if leak < 0 else '0') + f'{abs(leak):06.2f}' + '0' + str(code)
            + f'{channel:02}' + ('1' if pressure < 0 else '0') + f'{abs(pressure):07.1f}' + '0' + '0')
    result78(text)
    return frame(text)

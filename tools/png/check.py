"""Checks the Swift-written PNG fixtures (FormatoPNG) with Pillow and zlib, and the oracle's.

  FORMATO_PNG_FIXTURE_DIR=$PWD/Tests/FormatoCoreTests/Fixtures/png swift test -c release --jobs 4 --filter PNGTests
  References/venv/bin/python -I -B tools/png/check.py

For each swift-*.png and for mactem-inserted.png (the first consumer's own insertion, tools/png/oracle.sh):
  crc_valid       every chunk's CRC-32 equals zlib.crc32 of its type and body; the signature and IEND are there.
  pixels_equal    Pillow decodes the file to exactly the pixels the test generated (the formulas below, repeated from PNGTests.swift).
  idat_equal      zlib.decompress of the IDAT data (its Adler-32 checked by zlib) is the filtered scanlines: filter byte 0, then the
                  pixels, 16-bit samples big-endian.
  text_equal      the text chunks in the file (read here by hand, in file order, before the first IDAT) are the entries the test gave,
                  and Pillow's `.text` shows the same keys and values; the entries with printable ASCII values are tEXt chunks,
                  the others uncompressed UTF-8 iTXt.
Writes check-result.json, which the Swift tests pin together with each file's SHA-256.
"""
import hashlib, json, pathlib, struct, sys, zlib
import numpy as np
from PIL import Image

FIX = pathlib.Path(__file__).resolve().parents[2] / 'Tests/FormatoCoreTests/Fixtures/png'
ASCII = lambda v: all(0x20 <= ord(c) < 0x7F for c in v)

def b8(x, y, c): return (x * 37 + y * 91 + c * 53 + 7) % 256
def g16(x, y): return (x * 2579 + y * 7919 + 13) % 65536
def hashed(i): return ((i * 0x9E3779B97F4A7C15) % (1 << 64)) >> 56

# name: (width, height, channels, depth, pixel function, text entries)
TEXT = [('Title', 'kit title'), ('Description', '{"unit":"nm","scale":0.25}')]
CASES = {
    'swift-gray8.png': (5, 4, 1, 8, lambda x, y, c: b8(x, y, 0), TEXT),
    'swift-gray16.png': (6, 3, 1, 16, lambda x, y, c: g16(x, y), []),
    'swift-rgb8.png': (4, 3, 3, 8, b8, TEXT + [('Comment', 'café µm ✓')]),
    'swift-rgba8.png': (3, 2, 4, 8, b8, [('Software', 'FormatoKit test')]),
    'swift-rgb8-hashed.png': (64, 48, 3, 8, lambda x, y, c: hashed((y * 64 + x) * 3 + c), []),
    'swift-rgb8-stored.png': (64, 48, 3, 8, lambda x, y, c: hashed((y * 64 + x) * 3 + c), [('Title', 'stored blocks')]),
    'swift-rgb8-large.png': (700, 300, 3, 8, lambda x, y, c: b8(x // 3, y // 3, c), []),
    'mactem-inserted.png': (4, 3, 3, 8, b8, [('Title', 'oracle title'), ('Software', 'macTEM oracle 1.0'),
                                            ('Description', '{"width":4,"height":3,"unit":"nm"}'),
                                            ('Comment', 'café µm ✓'), ('Empty', '')]),
}

def chunks(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, out = 8, []
    while pos < len(data):
        n, = struct.unpack('>I', data[pos:pos + 4]); typ = data[pos + 4:pos + 8].decode('latin-1')
        body = data[pos + 8:pos + 8 + n]; crc, = struct.unpack('>I', data[pos + 8 + n:pos + 12 + n])
        out.append((typ, body, crc, zlib.crc32(data[pos + 4:pos + 8 + n]) & 0xFFFFFFFF)); pos += 12 + n
    return out

def text_of(typ, body):
    if typ == 'tEXt':
        k, v = body.split(b'\0', 1); return k.decode('latin-1'), v.decode('latin-1')
    k, rest = body.split(b'\0', 1)
    assert rest[:2] == b'\0\0'                                       # uncompressed, method 0
    lang, rest = rest[2:].split(b'\0', 1); trans, text = rest.split(b'\0', 1)
    assert lang == b'' and trans == b''
    return k.decode('latin-1'), text.decode('utf-8')

result = dict(pillow_version=__import__('PIL').__version__, files={})
failures = []
for name, (w, h, ch, depth, fn, text) in CASES.items():
    data = (FIX / name).read_bytes()
    cs = chunks(data)
    checks = {}
    checks['crc_valid'] = all(c[2] == c[3] for c in cs) and cs[-1][0] == 'IEND' and cs[0][0] == 'IHDR'
    ihdr = struct.unpack('>IIBBBBB', cs[0][1])
    ctype = {1: 0, 3: 2, 4: 6}[ch]
    checks['ihdr_equal'] = ihdr == (w, h, depth, ctype, 0, 0, 0)
    expected = np.array([[[fn(x, y, c) for c in range(ch)] for x in range(w)] for y in range(h)], dtype='>u2' if depth == 16 else np.uint8)
    im = Image.open(FIX / name); im.load()
    got = np.array(im)
    checks['pixels_equal'] = np.array_equal(got.reshape(expected.shape), expected.astype(got.dtype) if depth == 16 else expected)
    idat = b''.join(c[1] for c in cs if c[0] == 'IDAT')
    raw = zlib.decompress(idat)
    rows = b''.join(b'\0' + expected[y].astype('>u2' if depth == 16 else np.uint8).tobytes() for y in range(h))
    # Our own files use filter 0 on every row, so the stream is exactly the rows; Pillow's input uses adaptive filters, so for the
    # inserted file only the decompressed size is compared (its pixels are checked through Pillow above).
    checks['idat_equal'] = raw == rows if name.startswith('swift-') else len(raw) == len(rows)
    types = [c[0] for c in cs]
    first_idat = types.index('IDAT')
    entries = [text_of(c[0], c[1]) for c in cs if c[0] in ('tEXt', 'iTXt')]
    kinds = [c[0] for c in cs if c[0] in ('tEXt', 'iTXt')]
    checks['text_equal'] = (entries == text and all(t in ('tEXt', 'iTXt') for t in kinds[:first_idat]) and
                            all(i < first_idat for i, t in enumerate(types) if t in ('tEXt', 'iTXt')) and
                            kinds == ['tEXt' if ASCII(v) else 'iTXt' for _, v in text] and
                            dict(im.text) == dict(text) if text else entries == [])
    result['files'][name] = dict(sha256=hashlib.sha256(data).hexdigest(), checks={k: bool(v) for k, v in checks.items()})
    failures += [name + ':' + k for k, v in checks.items() if not v]
(FIX / 'check-result.json').write_text(json.dumps(result, indent=1, sort_keys=True) + '\n')
print(json.dumps(result, indent=1, sort_keys=True))
sys.exit(1 if failures else 0)

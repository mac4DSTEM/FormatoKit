#!/usr/bin/env python3
"""Re-emit a DM4 file as DM3 (32-bit lengths, no tag-length field): the planted DM3 fixtures for DM4Datacube.

usage: make_dm3.py in.dm4 out.dm3 (rsciio reads the result byte-equal to the DM4).
"""
import struct, sys

def r(b, o, fmt):
    n = struct.calcsize(fmt); return struct.unpack_from(fmt, b, o)[0], o + n

SIZE = {2: 2, 3: 4, 4: 2, 5: 4, 6: 4, 7: 8, 8: 1, 9: 1, 10: 1, 11: 8, 12: 8}

def payload(info):
    if info[0] in SIZE: return SIZE[info[0]]
    if info[0] == 18: return info[1]
    if info[0] == 20 and info[1] in SIZE: return SIZE[info[1]] * info[2]
    raise SystemExit("unsupported tag info %r" % (info,))

def group(b, o, out):
    out += b[o:o+2]; o += 2                               # sorted, open
    n, o = r(b, o, ">Q"); out += struct.pack(">I", n)
    for _ in range(n):
        t = b[o]; o += 1; out.append(t)
        ll, o = r(b, o, ">H"); out += struct.pack(">H", ll); out += b[o:o+ll]; o += ll
        tl, o = r(b, o, ">Q")                              # DM4 tag length: dropped (the generator writes 0, so sizes come from info)
        if t == 20: o = group(b, o, out)
        else:
            out += b[o:o+4]; o += 4
            ni, o = r(b, o, ">Q"); out += struct.pack(">I", ni)
            info = []
            for _ in range(ni):
                v, o = r(b, o, ">Q"); info.append(v); out += struct.pack(">I", v)
            n = payload(info)
            out += b[o:o+n]; o += n
    return o

def main():
    src, dst = sys.argv[1], sys.argv[2]
    b = open(src, "rb").read()
    assert struct.unpack_from(">I", b, 0)[0] == 4
    body = bytearray()
    o = 4 + 8 + 4
    o = group(b, o, body)
    out = bytearray(struct.pack(">III", 3, len(body) + 4 + 4, 1)) + body + b"\0\0\0\0"
    open(dst, "wb").write(out)

main()

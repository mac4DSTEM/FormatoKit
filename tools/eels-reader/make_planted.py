#!/usr/bin/env python3
"""Writes the planted DM4 files that FormatoDMTests/DM4EELSSpectrumImageTests.swift and DMSignalsPlantedTests.swift read:
`eels-planted.dm4` and the four `eels-refused-*.dm4`. From SpectroKit 0.3.0 (tools/eels-reader/make_planted.py), where these
fixtures were first written; only the output folder differs.

    make_planted.py [--out DIR]     DIR defaults to Tests/FormatoDMTests/Fixtures

Why it exists. RosettaSciIO 049e7d70's public `EELS_SI.dm4` is 2 x 2 x 2048 float32: square (an nx/ny swap cannot show),
one data type, every tag present. This file plants what that one cannot: a NON-SQUARE cube (nx = 3, ny = 2, 5 channels),
every integer and float type the reader converts, absent tags (nil), the stack-builder tag group, and each refusal.
It is written with the standard library only, from the DM4 grammar the walker in FormatoDM's DM4Experiment.swift reads (and
RosettaSciIO's `DigitalMicrographReader` reads the same bytes: `truth.py` reads this file with it and writes the truth).

Layout (DM4, little-endian data, big-endian headers): header = version 4, root length, byte order 1; a tag is
`type(1) | label length(2) | label | size(8) | content`; a data tag's content is `%%%%`, the info array (count, then the
entries, 8 bytes each) and the value; a group's content is `sorted(1) open(1) ntags(8)` and its tags. Strings are uint16
arrays (as GMS writes them). Objects in `ImageList` are unlabelled groups, so `ImageList.N` is the one-based position.

Objects 2-9 are one type each, 10 the stack-builder tags, 11 one row, 12-17 the refusals, 18 an object that is EELS by
`Meta Data.Signal` alone, 19 a keV energy axis (refused), 20 stack-builder tags that are only a string, 21 a cube whose pixel block is
the last thing in the file (so a copy cut inside the block still walks, and only the read notices).
Voxel rule (the Swift test repeats it as literals): for the 3 x 2 x 5 objects, with x in 0..2, y in 0..1, c in 0..4,
    b = 37 c + 11 y + 3 x                (0 .. 165, every voxel different)
and the stored value is, by type: float32 `b/4 - 10`; float64 `b/7 + 1e-9` (not a float32); int16 `100 b - 8000`;
uint16 `300 b`; uint8 `b`; int8 `b - 83`; int32 `1000003 b - 80000000`; uint32 `4000000000 + 1000003 b`. The memory order
is the one GMS writes for a spectrum image: x fastest, then y, energy slowest (`[c][y][x]`).
The energy axis of every cube: origin -40, scale 0.25, "eV" (channel c at 10 + 0.25 c eV); x: origin 1.5, scale 2.5 nm;
y: origin 0, scale 3.5 nm; `Calibrations.Brightness` Scale 0.5 "e-" (which the reader must NOT apply).

Run it with any Python 3, isolated (only the standard library): `python3 -I -B tools/eels-reader/make_planted.py`. Two runs write byte-identical files."""
import argparse
import hashlib
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_NAME = "eels-planted.dm4"

NX, NY, NCH = 3, 2, 5

# DM data type -> (tag element type, struct code, bytes)
DM_TYPES = {
    1: (2, "h", 2),    # int16
    2: (6, "f", 4),    # float32
    6: (8, "B", 1),    # uint8
    7: (3, "i", 4),    # int32
    9: (9, "b", 1),    # int8
    10: (4, "H", 2),   # uint16
    11: (5, "I", 4),   # uint32
    12: (7, "d", 8),   # float64
    14: (8, "B", 1),   # bool (not supported by the reader)
}
# scalar tag element types
SCALAR = {2: "h", 3: "i", 4: "H", 5: "I", 6: "f", 7: "d", 8: "B"}


def tag(kind, label, content):
    lab = label.encode("latin-1")
    return bytes([kind]) + struct.pack(">H", len(lab)) + lab + struct.pack(">Q", len(content)) + content


def data_tag(label, info, payload):
    content = b"%%%%" + struct.pack(">Q", len(info)) + b"".join(struct.pack(">Q", i) for i in info) + payload
    return tag(21, label, content)


def scalar(label, etype, value):
    return data_tag(label, [etype], struct.pack("<" + SCALAR[etype], value))


def string(label, text):
    units = text.encode("utf-16-le")
    return data_tag(label, [20, 4, len(text)], units)


def group(label, entries):
    content = bytes([0, 0]) + struct.pack(">Q", len(entries)) + b"".join(entries)
    return tag(20, label, content)


def b_of(x, y, c):
    return 37 * c + 11 * y + 3 * x


VALUE = {
    2: lambda b: b / 4 - 10,
    12: lambda b: b / 7 + 1e-9,
    1: lambda b: 100 * b - 8000,
    10: lambda b: 300 * b,
    6: lambda b: b,
    9: lambda b: b - 83,
    7: lambda b: 1000003 * b - 80000000,
    11: lambda b: 4000000000 + 1000003 * b,
}


def cube_bytes(dm_type, nx, ny, nch):
    """[c][y][x], x fastest: the memory order GMS writes for a spectrum image."""
    code = DM_TYPES[dm_type][1]
    out = bytearray()
    for c in range(nch):
        for y in range(ny):
            for x in range(nx):
                v = VALUE.get(dm_type, lambda b: b % 2)(b_of(x, y, c))
                out += struct.pack("<" + code, v)
    return bytes(out)


def calibration(origin, scale, units):
    return group("", [scalar("Origin", 7, origin), scalar("Scale", 7, scale), string("Units", units)])


def image(name, dm_type, dims, *, label="EELS", cal=None, tags=(), swapped=None, payload=None, brightness=True,
          stack_tags=None, data_last=False, signal=None):
    """One ImageList entry. `dims` fastest first; `cal` a list of (origin, scale, units) per dimension.
    `data_last`: the pixel block is the LAST tag of the entry (ImageTags and Name come first, `Data` last in ImageData),
    so that when it is the last entry of the file a copy cut inside the block still walks (the reader's walk seeks past
    blocks and reads none): only the read of the block can then notice the cut."""
    etype = DM_TYPES[dm_type][0]
    if payload is None:
        payload = cube_bytes(dm_type, *dims) if len(dims) == 3 else bytes(DM_TYPES[dm_type][2] * dims[0] * dims[1])
    count = len(payload) // DM_TYPES[dm_type][2]
    calib = [calibration(*c) for c in (cal or [])]
    block = data_tag("Data", [20, etype, count], payload)
    image_data = [
        scalar("DataType", 3, dm_type),
        group("Dimensions", [scalar("", 5, d) for d in dims]),
        scalar("PixelDepth", 3, DM_TYPES[dm_type][2]),
        group("Calibrations", [
            group("Brightness", [scalar("Origin", 7, 0.0), scalar("Scale", 7, 0.5), string("Units", "e-")]) if brightness
            else group("Brightness", [scalar("Origin", 7, 0.0), scalar("Scale", 7, 1.0), string("Units", "")]),
            group("Dimension", calib),
        ]),
    ]
    image_data = image_data + [block] if data_last else [block] + image_data
    meta = [
        string("Format", "Spectrum image" if len(dims) == 3 else "Image"),
        string("Signal", signal if signal is not None else ("EELS" if label == "EELS" else "")),
        group("Experiment keywords", [
            group("", [string("Label", "Spectrum Imaging"), string("Experiment ID", "planted")]),
            group("", [string("Label", label)]),
        ]),
    ]
    if swapped is not None:
        meta.append(scalar("Data Order Swapped", 3, swapped))
    image_tags = [group("Meta Data", meta)] + list(tags)
    if stack_tags is not None:
        image_tags.append(group("source", [group("Tags at creation", list(stack_tags))]))
    if data_last:
        return group("", [group("ImageTags", image_tags), string("Name", name), group("ImageData", image_data)])
    return group("", [group("ImageData", image_data), group("ImageTags", image_tags), string("Name", name)])


def microscope(voltage):
    return group("Microscope Info", [scalar("Voltage", 6, voltage),
                                     string("Illumination Mode", "STEM NANOPROBE")])


def conditions(conv=None, coll=None):
    entries = []
    if coll is not None:
        entries.append(scalar("Collection semi-angle (mrad)", 6, coll))
    if conv is not None:
        entries.append(scalar("Convergence semi-angle (mrad)", 6, conv))
    return group("EELS", [group("Experimental Conditions", entries)])


EAXIS = [(1.5, 2.5, "nm"), (0.0, 3.5, "nm"), (-40.0, 0.25, "eV")]
CUBE = [NX, NY, NCH]


def objects():
    return [
        # 1: a survey image, not an EELS object
        image("Planted survey", 2, [4, 3], label="Survey", cal=[(0.0, 1.0, "nm"), (0.0, 1.0, "nm")]),
        # 2: float32, every tag present: E0 80 kV, convergence 17.5, collection 33.25
        image("EELS float32", 2, CUBE, cal=EAXIS, tags=[microscope(80000.0), conditions(17.5, 33.25)]),
        # 3: int16, only the voltage (300 kV)
        image("EELS int16", 1, CUBE, cal=EAXIS, tags=[microscope(300000.0)]),
        # 4: uint16, only the convergence angle
        image("EELS uint16", 10, CUBE, cal=EAXIS, tags=[conditions(conv=10.0)]),
        # 5: uint8, only the collection angle
        image("EELS uint8", 6, CUBE, cal=EAXIS, tags=[conditions(coll=20.0)]),
        # 6: int8, no tags at all
        image("EELS int8", 9, CUBE, cal=EAXIS),
        # 7: int32 and 8: uint32 (values beyond 2^24: rounded to the nearest Float32), 9: float64
        image("EELS int32", 7, CUBE, cal=EAXIS, tags=[microscope(200000.0)]),
        image("EELS uint32", 11, CUBE, cal=EAXIS, tags=[microscope(200000.0)]),
        image("EELS float64", 12, CUBE, cal=EAXIS, tags=[microscope(200000.0)]),
        # 10: tags only under source.Tags at creation (stack builder); the top-level ones are a decoy
        image("EELS stack builder", 2, CUBE, cal=EAXIS,
              tags=[microscope(60000.0), conditions(1.0, 2.0)],
              stack_tags=[microscope(120000.0), conditions(25.0, 45.0)]),
        # 11: 4 x 1 x 3: a single row (ny = 1)
        image("EELS one row", 2, [4, 1, 3], cal=[(0.0, 2.0, "nm"), (0.0, 2.0, "nm"), (-5.0, 0.5, "eV")]),
        # refusals
        image("EELS energy in nm", 2, CUBE, cal=[(1.5, 2.5, "nm"), (0.0, 3.5, "nm"), (-40.0, 0.25, "nm")]),
        image("EELS data order swapped", 2, CUBE, cal=EAXIS, swapped=1),
        image("EELS two dimensions", 2, [4, 3], cal=[(0.0, 1.0, "nm"), (0.0, 1.0, "nm")]),
        image("EELS no energy calibration", 2, CUBE, cal=EAXIS[:2]),
        image("EELS unsupported type", 14, CUBE, cal=EAXIS),
        # 16: a mislabelled-by-role object: an EDS spectrum image is not an EELS one
        image("EDS spectrum image", 2, CUBE, label="EDS", cal=[(1.5, 2.5, "nm"), (0.0, 3.5, "nm"), (0.0, 0.01, "keV")]),
        # 18: `Meta Data.Signal` = "EELS" and nothing else says EELS: the Label keyword is unknown and the name has no "eels".
        #     RosettaSciIO calls an object EELS from that tag alone (signal_type), so the reader must too (role .eels, by signalTag)
        image("Spectrum cube by signal tag", 2, CUBE, label="Planted unlabelled", signal="EELS", cal=EAXIS,
              tags=[microscope(100000.0), conditions(9.0, 11.0)]),
        # 19: an EELS object whose third axis is in keV (the reader reads eV only, as documented, and refuses)
        image("EELS energy in keV", 2, CUBE, cal=[(1.5, 2.5, "nm"), (0.0, 3.5, "nm"), (-0.04, 0.00025, "keV")]),
        # 20: the stack builder's `source.Tags at creation` group exists but holds only a STRING tag: RosettaSciIO then reads the
        #     tags from that group (it finds no voltage and no angles), so the top-level 60 kV / 1 / 2 mrad are a decoy again
        image("EELS stack builder, strings only", 2, CUBE, cal=EAXIS, tags=[microscope(60000.0), conditions(1.0, 2.0)],
              stack_tags=[string("Note", "stacked")]),
        # 21: the last entry of the file with its pixel block last of all: a copy cut inside the block still walks
        image("EELS last block", 2, CUBE, cal=EAXIS, tags=[microscope(100000.0), conditions(5.0, 6.0)], data_last=True),
    ]


# Data tags whose declared length is not the cube's: RosettaSciIO RAISES on each (so each is its own one-object file, and
# truth.py records the raise instead of a reading). The reader must throw `truncated`, never decode bytes after the tag.
# `Data` declares 0, 29 and 31 elements for dims [3, 2, 5] (30 voxels); the tags that follow the Data tag in the file
# (ImageTags, Name) are the bytes a reader that trusted a zero length would decode as pixels.
REFUSED = {
    "eels-refused-zero.dm4": ("EELS zero-length Data tag", b""),
    "eels-refused-short.dm4": ("EELS short Data tag", cube_bytes(2, NX, NY, NCH)[:-4]),
    "eels-refused-long.dm4": ("EELS long Data tag", cube_bytes(2, NX, NY, NCH) + bytes(4)),
}
# A cube with a zero dimension ([3, 0, 5], an empty Data tag that agrees with it): the reader refuses it (cannotOpen), whatever
# RosettaSciIO does with it (truth.py records its reading or its raise).
ZERO_DIM = "eels-refused-zerodim.dm4"


def wrap(entries):
    image_list = group("ImageList", entries)
    body = bytes([0, 0]) + struct.pack(">Q", 1) + image_list + struct.pack(">Q", 0)
    header = struct.pack(">I", 4) + struct.pack(">Q", len(body)) + struct.pack(">I", 1)
    return header + body


def build_zero_dim():
    return wrap([image("EELS zero dimension", 2, [NX, 0, NCH], cal=EAXIS, tags=[microscope(100000.0)], payload=b"")])


def build_refused(name):
    title, payload = REFUSED[name]
    return wrap([image(title, 2, CUBE, cal=EAXIS, tags=[microscope(100000.0)], payload=payload)])


def build():
    return wrap(objects())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "Tests" / "FormatoDMTests" / "Fixtures"))
    args = ap.parse_args()
    data = build()
    path = Path(args.out) / OUT_NAME
    path.write_bytes(data)
    print(f"{path.name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
    for name in REFUSED:
        data = build_refused(name)
        (Path(args.out) / name).write_bytes(data)
        print(f"{name}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
    data = build_zero_dim()
    (Path(args.out) / ZERO_DIM).write_bytes(data)
    print(f"{ZERO_DIM}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()

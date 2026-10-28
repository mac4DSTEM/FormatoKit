#!/usr/bin/env python3
"""Planted TIFFs for FormatoKit step 2.

    References/rsciio-venv/bin/python -I -B tools/step-2/make_planted.py [--out DIR]

Writes small TIFFs with known content into Tests/FormatoTIFFTests/Fixtures/planted/ with Python's `struct` only, byte by byte
(not tifffile's writer, not RosettaSciIO's), and `planted-truth.json` next to them: for each file the literal values the Swift
tests assert (shape, dtype, the pixel values, the tags as stored, the axes and metadata RosettaSciIO should give, or the
refusal expected). Truth is written here by hand, from the bytes this script lays down; then every file is read with
tifffile and with RosettaSciIO (the reading goes into the same JSON as `reading`, the record `pins.py` builds for a file), and
the hand-written expectations are compared with that reading: a difference is listed under `disagreements` and printed, never
adjusted away. The output is byte-reproducible (built twice in the process, the two outputs compared; sorted keys, indent 1, no
times, no absolute paths).
"""
import argparse
import hashlib
import importlib.util
import json
import logging
import struct
import sys
import warnings
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests" / "FormatoTIFFTests" / "Fixtures"
PLANTED = FIXTURES / "planted"

# TIFF datatypes: code -> (struct format per item, bytes per item)
T_BYTE, T_ASCII, T_SHORT, T_LONG, T_RATIONAL, T_SBYTE, T_UNDEF, T_SSHORT, T_SLONG, T_SRATIONAL = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
T_FLOAT, T_DOUBLE, T_LONG8, T_SLONG8, T_IFD8 = 11, 12, 16, 17, 18
FMT = {T_BYTE: ("B", 1), T_SHORT: ("H", 2), T_LONG: ("I", 4), T_SBYTE: ("b", 1), T_SSHORT: ("h", 2), T_SLONG: ("i", 4),
       T_FLOAT: ("f", 4), T_DOUBLE: ("d", 8), T_LONG8: ("Q", 8), T_SLONG8: ("q", 8), T_IFD8: ("Q", 8)}
SIZE = {T_ASCII: 1, T_UNDEF: 1, T_RATIONAL: 8, T_SRATIONAL: 8, **{k: v[1] for k, v in FMT.items()}}
NAMES = {256: "ImageWidth", 257: "ImageLength", 258: "BitsPerSample", 259: "Compression", 262: "PhotometricInterpretation",
         270: "ImageDescription", 273: "StripOffsets", 277: "SamplesPerPixel", 278: "RowsPerStrip", 279: "StripByteCounts",
         282: "XResolution", 283: "YResolution", 284: "PlanarConfiguration", 296: "ResolutionUnit", 305: "Software",
         306: "DateTime", 322: "TileWidth", 323: "TileLength", 324: "TileOffsets", 325: "TileByteCounts", 338: "ExtraSamples",
         339: "SampleFormat", 34682: "FEI_HELIOS"}


def die(msg):
    sys.exit("make_planted.py: " + msg)


# ------------------------------------------------------------------------------------------------------------ the writer

def encode_values(bo, typ, values):
    """-> (count, bytes) of a tag's value in byte order bo ('<' or '>')."""
    if typ in (T_ASCII, T_UNDEF):
        if not isinstance(values, (bytes, bytearray)):
            raise TypeError("ASCII/UNDEFINED values are bytes")
        return len(values), bytes(values)
    if typ in (T_RATIONAL, T_SRATIONAL):
        code = "I" if typ == T_RATIONAL else "i"
        flat = [x for pair in values for x in pair]
        return len(values), struct.pack(f"{bo}{len(flat)}{code}", *flat)
    if typ == 99:   # an unknown type, kept as bytes
        return len(values), bytes(values)
    code = FMT[typ][0]
    return len(values), struct.pack(f"{bo}{len(values)}{code}", *values)


def build_tiff(bo, bigtiff, pages, contiguous=False):
    """pages: list of dicts {tags: [(code, type, values)], strips: [bytes], offsets_code, counts_code, fake_offsets, trailing}.
    contiguous: every page's strips (and `trailing` bytes) are written right after the header, before any IFD.
    Returns (file bytes, [per page: {strip_offsets, strip_counts, ifd_offset, entries: [(code, type, count, raw bytes)]}])."""
    off_size = 8 if bigtiff else 4
    inline = off_size
    buf = bytearray()
    if bigtiff:
        buf += (b"II" if bo == "<" else b"MM") + struct.pack(f"{bo}HHHQ", 43, 8, 0, 0)
    else:
        buf += (b"II" if bo == "<" else b"MM") + struct.pack(f"{bo}HI", 42, 0)
    first_ifd_at = 8 if bigtiff else 4   # where the offset of the first IFD sits in the header
    patch_next = first_ifd_at            # position to patch with the next IFD's offset
    layout = []

    def put_offset(pos, value):
        buf[pos:pos + off_size] = struct.pack(f"{bo}{'Q' if bigtiff else 'I'}", value)

    def write_strips(page):
        if len(buf) % 2:
            buf.extend(b"\0")
        offs, cnts = [], []
        for s in page["strips"]:
            offs.append(len(buf))
            cnts.append(len(s))
            buf.extend(s)
        buf.extend(page.get("trailing", b""))
        if len(buf) % 2:
            buf.extend(b"\0")
        return offs, cnts

    placed = [write_strips(p) for p in pages] if contiguous else None
    for k, page in enumerate(pages):
        offs, cnts = placed[k] if contiguous else write_strips(page)
        tags = list(page["tags"])
        oc, cc = page.get("offsets_code", 273), page.get("counts_code", 279)
        fake = page.get("fake_offsets")
        if page["strips"]:
            otype = T_LONG8 if bigtiff else T_LONG
            tags.append((oc, otype, fake if fake is not None else offs))
            tags.append((cc, T_LONG, cnts))
        tags.sort(key=lambda t: t[0])
        entries, blobs = [], []
        for code, typ, values in tags:
            count, raw = encode_values(bo, typ, values)
            entries.append((code, typ, count, raw))
        # external blobs first (word aligned), then the IFD
        ext = {}
        for i, (code, typ, count, raw) in enumerate(entries):
            if len(raw) > inline:
                if len(buf) % 2:
                    buf += b"\0"
                ext[i] = len(buf)
                buf += raw
        if len(buf) % 2:
            buf += b"\0"
        ifd_at = len(buf)
        put_offset(patch_next, ifd_at)
        if bigtiff:
            buf += struct.pack(f"{bo}Q", len(entries))
        else:
            buf += struct.pack(f"{bo}H", len(entries))
        for i, (code, typ, count, raw) in enumerate(entries):
            if bigtiff:
                buf += struct.pack(f"{bo}HHQ", code, typ, count)
            else:
                buf += struct.pack(f"{bo}HHI", code, typ, count)
            if i in ext:
                buf += struct.pack(f"{bo}{'Q' if bigtiff else 'I'}", ext[i])
            else:
                buf += raw + b"\0" * (inline - len(raw))
        patch_next = len(buf)
        buf += b"\0" * off_size   # next IFD offset: 0 until a following page patches it
        layout.append({"strip_offsets": offs, "strip_counts": cnts, "ifd_offset": ifd_at, "entries": entries})
    return bytes(buf), layout


def pack(bo, code, flat):
    return struct.pack(f"{bo}{len(flat)}{code}", *flat)


def rows_to_strips(bo, code, rows, rows_per_strip):
    """rows: list of flat per-row sample lists -> list of strip bytes."""
    strips = []
    for i in range(0, len(rows), rows_per_strip):
        flat = [v for r in rows[i:i + rows_per_strip] for v in r]
        strips.append(pack(bo, code, flat))
    return strips


# ------------------------------------------------------------------------------------------------------------ truth helpers

def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def f32_bits(x):
    return struct.pack(">f", x).hex()


def f64_bits(x):
    return struct.pack(">d", x).hex()


def decode_tag_truth(bo, code, typ, count, raw):
    """The literal a Swift test asserts for a tag: the value as a person reads it from the bytes (ASCII cut at the first NUL,
    RATIONAL as [num, den] pairs, bytes as hex). Floats come with their bit patterns."""
    t = {"code": code, "type": typ, "count": count, "raw_hex": raw.hex()}
    if code in NAMES:
        t["name"] = NAMES[code]
    if typ == T_ASCII:
        end = raw.find(b"\0")
        cut = raw if end < 0 else raw[:end]
        try:
            t["value"] = cut.decode("utf-8")
        except UnicodeDecodeError:
            t["value"] = cut.decode("cp1252")   # tifffile's bytes2str: UTF-8, else cp1252
    elif typ in (T_BYTE, T_UNDEF, 99):
        t["value"] = None   # kept as bytes: raw_hex is the value
    elif typ in (T_RATIONAL, T_SRATIONAL):
        c = "I" if typ == T_RATIONAL else "i"
        n = struct.unpack(f"{bo}{count * 2}{c}", raw)
        t["value"] = [[n[2 * i], n[2 * i + 1]] for i in range(count)]
    elif typ in (T_FLOAT, T_DOUBLE):
        c = "f" if typ == T_FLOAT else "d"
        v = struct.unpack(f"{bo}{count}{c}", raw)
        t["value"] = list(v)
        t["value_bits"] = [(f32_bits(x) if typ == T_FLOAT else f64_bits(x)) for x in v]
    else:
        v = struct.unpack(f"{bo}{count}{FMT[typ][0]}", raw)
        t["value"] = list(v)
    return t


def ax(name, size, scale=1.0, offset=0.0, units=None, navigate=False):
    return {"name": name, "size": size, "scale": scale, "scale_bits": f64_bits(scale), "offset": offset,
            "offset_bits": f64_bits(offset), "units": units, "navigate": navigate}


def md(key, value, source=None):
    e = {"key": key, "value": value}
    if isinstance(value, float):
        e["value_bits"] = f64_bits(value)
    if source is not None:
        e["source"] = source
    return e


YX = lambda h, w, sy=1.0, sx=1.0, oy=0.0, ox=0.0, uy=None, ux=None: [ax("height", h, sy, oy, uy), ax("width", w, sx, ox, ux)]


def common_tags(bo, w, h, bits, photometric=1, samples=1, rps=None, sample_format=None, extra_samples=None, planar=True):
    tags = [(256, T_SHORT, [w]), (257, T_SHORT, [h]), (258, T_SHORT, [bits] * samples), (259, T_SHORT, [1]),
            (262, T_SHORT, [photometric]), (277, T_SHORT, [samples]), (278, T_SHORT, [rps if rps else h])]
    if planar:
        tags.append((284, T_SHORT, [1]))
    if sample_format is not None:
        tags.append((339, T_SHORT, [sample_format] * samples))
    if extra_samples is not None:
        tags.append((338, T_SHORT, [extra_samples]))
    return tags


def asc(s):
    return s.encode("utf-8") + b"\0"


# ------------------------------------------------------------------------------------------------------------ the files

def make_files():
    """-> list of dicts {name, bytes, layout, bo, bigtiff, truth (hand-written expectations)}."""
    out = []

    def add(name, bo, bigtiff, pages, truth, contiguous=False):
        data, layout = build_tiff(bo, bigtiff, pages, contiguous)
        out.append({"name": name, "bytes": data, "layout": layout, "bo": bo, "bigtiff": bigtiff, "truth": truth})

    # --- 1. u16 3 x 5, three strips, II and MM -------------------------------------------------------------------
    rows16 = [[1000 * r + c for c in range(5)] for r in range(3)]
    for name, bo, dt_text, sw in (("be-u16-3strips.tif", ">", b"2026:10:14 22:11:33\0", b"planted\0junk\0"),
                                  ("le-u16-3strips.tif", "<", b"2026/10/14 22:11\0", None)):
        tags = common_tags(bo, 5, 3, 16, rps=1)
        tags += [(282, T_RATIONAL, [(300, 7)]), (283, T_RATIONAL, [(72, 1)]), (296, T_SHORT, [2]), (306, T_ASCII, dt_text)]
        if sw:
            tags.append((305, T_ASCII, sw))
        if bo == "<":
            tags.append((254, T_LONG, [0]))
        date_md = [md("General.date", "2026-10-14", "DateTime"),
                   md("General.time", "22:11:33" if bo == ">" else "22:11:00", "DateTime")]
        add(name, bo, False, [{"tags": tags, "strips": rows_to_strips(bo, "H", rows16, 1)}], {
            "kind": "read", "in_scope": True,
            "pages": 1, "series": [{
                "tifffile_axes": "YX", "shape": [3, 5], "dtype": "uint16",
                "pixels": rows16, "axes": YX(3, 5),
                "metadata": [md("General.original_filename", name)] + date_md + [md("Signal.signal_type", "")]}],
            "note": "RowsPerStrip 1: three strips. 306 DateTime in the "
                    + ("'%Y:%m:%d %H:%M:%S'" if bo == ">" else "'%Y/%m/%d %H:%M'") + " form."
                    + (" 305 Software holds 'planted', a NUL, 'junk', a NUL: a reader cuts at the first NUL." if sw else "")})

    # --- 2. BigTIFF float32 2 x 3 --------------------------------------------------------------------------------
    f_rows = [[-0.0, f32(1e-38), 3.5], [f32(0.1), -2.5, f32(3.4028234663852886e38)]]
    bo = "<"
    tags = common_tags(bo, 3, 2, 32, sample_format=3)
    tags += [(65100, T_LONG8, [2 ** 40 + 5, 7]), (65101, T_SLONG8, [-(2 ** 40) - 3]), (65102, T_SHORT, [1, 2, 3])]
    add("bigtiff-f32.tif", bo, True, [{"tags": tags, "strips": rows_to_strips(bo, "f", f_rows, 2)}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YX", "shape": [2, 3], "dtype": "float32", "pixels": f_rows,
                    "pixel_bits_f32": [[f32_bits(v) for v in r] for r in f_rows], "axes": YX(2, 3),
                    "metadata": [md("General.original_filename", "bigtiff-f32.tif"), md("Signal.signal_type", "")]}],
        "note": "-0.0, 1e-38 (a float32 subnormal), 3.5, float32(0.1), -2.5, float32 max. 65100 LONG8 and 65101 SLONG8 are "
                "private tags; 65102 is three SHORTs (6 bytes: inline in a BigTIFF IFD entry, external in a classic one)."})

    # --- 3. RGB8 2 x 2 --------------------------------------------------------------------------------------------
    rgb = [[(1, 2, 3), (4, 5, 6)], [(7, 8, 9), (250, 251, 252)]]
    bo = ">"
    tags = common_tags(bo, 2, 2, 8, photometric=2, samples=3, sample_format=1)
    strips = [bytes(v for px in row for v in px) for row in rgb]
    tags = [t if t[0] != 278 else (278, T_SHORT, [1]) for t in tags]
    add("rgb8.tif", bo, False, [{"tags": tags, "strips": strips}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YXS", "shape": [2, 2], "dtype": "rgb8", "dtype_rsciio": "[('R', 'u1'), ('G', 'u1'), ('B', 'u1')]",
                    "samples": 3, "pixels": [[list(p) for p in row] for row in rgb], "axes": YX(2, 2),
                    "metadata": [md("General.original_filename", "rgb8.tif"), md("Signal.signal_type", "")]}],
        "note": "Photometric 2, 3 samples; shape and axes drop the sample axis (RosettaSciIO's structured RGB)."})

    # --- 4. RGBA16 2 x 2, ExtraSamples 2 -------------------------------------------------------------------------
    rgba = [[(1, 256, 4660, 65535), (2, 512, 9320, 0)], [(3, 768, 13980, 32768), (4, 1024, 18640, 40000)]]
    bo = "<"
    tags = common_tags(bo, 2, 2, 16, photometric=2, samples=4, sample_format=1, extra_samples=2)
    strips = [pack(bo, "H", [v for px in row for v in px]) for row in rgba]
    tags = [t if t[0] != 278 else (278, T_SHORT, [1]) for t in tags]
    add("rgba16.tif", bo, False, [{"tags": tags, "strips": strips}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YXS", "shape": [2, 2], "dtype": "rgba16",
                    "dtype_rsciio": "[('R', '<u2'), ('G', '<u2'), ('B', '<u2'), ('A', '<u2')]",
                    "samples": 4, "pixels": [[list(p) for p in row] for row in rgba], "axes": YX(2, 2),
                    "metadata": [md("General.original_filename", "rgba16.tif"), md("Signal.signal_type", "")]}],
        "note": "Photometric 2, 4 samples, ExtraSamples 2 (unassociated alpha)."})

    # --- 5. two pages int16 2 x 3 ---------------------------------------------------------------------------------
    st = [[[-1, 2, -32768], [32767, -300, 0]], [[5, -6, 7], [-8, 9, -10]]]
    bo = "<"
    pages = []
    for p in st:
        tags = common_tags(bo, 3, 2, 16, sample_format=2)
        pages.append({"tags": tags, "strips": rows_to_strips(bo, "h", p, 2)})
    add("stack-i16.tif", bo, False, pages, {
        "kind": "read", "in_scope": True, "pages": 2,
        "series": [{"tifffile_axes": "IYX", "shape": [2, 2, 3], "dtype": "int16", "pixels": st,
                    "axes": [ax("image series", 2, navigate=True)] + YX(2, 3),
                    "metadata": [md("General.original_filename", "stack-i16.tif"), md("Signal.signal_type", "")]}],
        "note": "Two pages of the same shape and type: tifffile's generic series IYX."})

    # --- 6. ImageJ, micron, 2 pages 2 x 2 uint8 (square pixels) and an asymmetric one -----------------------------
    bo = ">"
    ij = [[[1, 2], [3, 4]], [[5, 6], [7, 250]]]
    desc = b"ImageJ=1.54f\nimages=2\nslices=2\nunit=micron\nspacing=0.5\n\0"
    ij_tags = [(270, T_ASCII, desc), (282, T_RATIONAL, [(4, 1)]), (283, T_RATIONAL, [(4, 1)]), (296, T_SHORT, [1])]
    ij_series = {"tifffile_axes": "ZYX", "tifffile_kind": "imagej", "shape": [2, 2, 2], "dtype": "uint8", "pixels": ij,
                 "axes": [ax("depth", 2, 0.5, 0.0, None, True)] + YX(2, 2, 0.25, 0.25, 0.0, 0.0, "\u00b5m", "\u00b5m")}
    # two IFDs; the planes are stored back to back before the first IFD, as ImageJ writes them (tifffile reads a stack whose
    # data are contiguous from the first page's offset; with the second plane stored after the first IFD it would read garbage)
    pages = []
    for k, p in enumerate(ij):
        tags = common_tags(bo, 2, 2, 8, sample_format=1) + (ij_tags if k == 0 else [])
        pages.append({"tags": tags, "strips": [bytes(v for r in p for v in r)]})
    add("imagej-micron.tif", bo, False, pages, {
        "kind": "read", "in_scope": True, "pages": 2,
        "series": [{**ij_series, "metadata": [md("General.original_filename", "imagej-micron.tif"), md("Signal.signal_type", "")]}],
        "note": "ImageJ description with images=2 slices=2 unit=micron spacing=0.5; X/YResolution 4/1: 0.25 um. Two IFDs (the "
                "second without a description), the planes stored contiguously before the first IFD. Big-endian."},
        contiguous=True)

    # the same stack as ImageJ writes a hyperstack: one IFD, the second plane follows the first plane's strip
    tags = common_tags(bo, 2, 2, 8, sample_format=1) + ij_tags
    add("imagej-virtual.tif", bo, False,
        [{"tags": tags, "strips": [bytes(v for r in ij[0] for v in r)], "trailing": bytes(v for r in ij[1] for v in r)}], {
            "kind": "read", "in_scope": True, "pages": 1,
            "series": [{**ij_series, "metadata": [md("General.original_filename", "imagej-virtual.tif"), md("Signal.signal_type", "")]}],
            "note": "One IFD only, images=2: the plane after the first plane's strip belongs to the series (tifffile's ImageJ "
                    "'virtual' rule: page 0 holds all the metadata and the data follow it contiguously). len(pages) is 1 but the series "
                    "has 2 planes."})

    ij2 = [[[1, 2, 3], [4, 5, 6]]]
    desc2 = b"ImageJ=1.54f\nunit=micron\n\0"
    tags = common_tags(bo, 3, 2, 8, sample_format=1)
    tags += [(270, T_ASCII, desc2), (282, T_RATIONAL, [(4, 1)]), (283, T_RATIONAL, [(2, 1)]), (296, T_SHORT, [1])]
    add("imagej-micron-asym.tif", bo, False, [{"tags": tags, "strips": [bytes(v for r in ij2[0] for v in r)]}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YX", "tifffile_kind": "imagej", "shape": [2, 3], "dtype": "uint8", "pixels": ij2[0],
                    "axes": YX(2, 3, 0.5, 0.25, 0.0, 0.0, "µm", "µm"),
                    "metadata": [md("General.original_filename", "imagej-micron-asym.tif"), md("Signal.signal_type", "")]}],
        "note": "XResolution 4/1, YResolution 2/1: height (Y) gets 1/2 = 0.5 um, width (X) gets 1/4 = 0.25 um."})

    # --- 7. DM tags ---------------------------------------------------------------------------------------------
    bo = "<"
    dm = [[1.0, 2.0], [3.0, 4.0]]
    tags = common_tags(bo, 2, 2, 32, sample_format=3)
    tags += [(65003, T_ASCII, asc("nm")), (65004, T_ASCII, asc("nm")), (65009, T_DOUBLE, [2.5]), (65010, T_DOUBLE, [2.5]),
             (65006, T_DOUBLE, [-1.5]), (65007, T_DOUBLE, [0.0])]
    add("dm-tags.tif", bo, False, [{"tags": tags, "strips": rows_to_strips(bo, "f", dm, 2)}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YX", "shape": [2, 2], "dtype": "float32", "pixels": dm,
                    "axes": YX(2, 2, 2.5, 2.5, 0.0, -1.5, "nm", "nm"),
                    "metadata": [md("General.original_filename", "dm-tags.tif"), md("Signal.signal_type", "")]}],
        "note": "As a DM-saved TIFF stores them (public test_loading_image_saved_with_DM.tif): 65003/65004 ASCII, "
                "65006/65007/65009/65010 DOUBLE. RosettaSciIO: 65003 units y (the width axis), 65004 units x (height); "
                "65009 scale y (width), 65010 scale x (height); 65006 offset y (width), 65007 offset x (height). "
                "Scales and units are equal here, the offsets differ: dm-tags-stack.tif tells the scales apart."})

    dms = [[[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], [[7.0, 8.0, 9.0], [10.0, 11.0, 12.0]]]
    pages = []
    for k, p in enumerate(dms):
        tags = common_tags(bo, 3, 2, 32, sample_format=3)
        if k == 0:
            tags += [(65003, T_ASCII, b"nm\0"), (65004, T_ASCII, b"\xb5m\0"), (65005, T_ASCII, asc("s")),
                     (65006, T_DOUBLE, [-1.5]), (65007, T_DOUBLE, [0.25]), (65008, T_DOUBLE, [1.0]),
                     (65009, T_DOUBLE, [2.5]), (65010, T_DOUBLE, [4.0]), (65011, T_DOUBLE, [0.125]),
                     (65022, T_ASCII, asc("counts")), (65024, T_DOUBLE, [3.0]), (65025, T_DOUBLE, [0.5])]
        pages.append({"tags": tags, "strips": rows_to_strips(bo, "f", p, 2)})
    add("dm-tags-stack.tif", bo, False, pages, {
        "kind": "read", "in_scope": True, "pages": 2,
        "series": [{"tifffile_axes": "IYX", "shape": [2, 2, 3], "dtype": "float32", "pixels": dms,
                    "axes": [ax("image series", 2, 0.125, 1.0, "s", True)] + YX(2, 3, 4.0, 2.5, 0.25, -1.5, "µm", "nm"),
                    "metadata": [md("General.original_filename", "dm-tags-stack.tif"), md("Signal.signal_type", ""),
                                 md("Signal.quantity", "counts", "65022"),
                                 md("Signal.Noise_properties.Variance_linear_model.gain_factor", 0.5, "65025"),
                                 md("Signal.Noise_properties.Variance_linear_model.gain_offset", 3.0, "65024")]}],
        "note": "All the DM tags: units 65003 (width) nm, 65004 (height) a latin-1 micro sign + m (byte 0xB5, not UTF-8: tifffile "
                "falls back to cp1252), 65005 z unit s; offsets 65006 -1.5 (width), 65007 0.25 (height), 65008 1.0 (z); scales "
                "65009 2.5 (width), 65010 4.0 (height), 65011 0.125 (z); 65022 intensity units, 65024 intensity offset 3.0 "
                "(gain_offset), 65025 intensity scale 0.5 (gain_factor). Only page 0 carries them."})

    # --- 8. FEI Helios ---------------------------------------------------------------------------------------------
    bo = "<"
    ini = ("[User]\nDate=10/14/2026\nTime=11:22:33 PM\nUser=planted\n[Beam]\nHV=200000\n[Scan]\nPixelWidth=1.5e-09\n"
           "PixelHeight=1.5e-09\n[Stage]\nWorkingDistance=0.004\n")
    fei_md = [md("General.original_filename", "fei-helios.tif"), md("Signal.signal_type", ""),
              md("Acquisition_instrument.SEM.beam_energy", 200.0, "fei_metadata.Beam.HV"),
              md("Acquisition_instrument.SEM.working_distance", 4.0, "fei_metadata.Stage.WorkingDistance"),
              md("General.date", "2026-10-14", "fei_metadata.User.Date"), md("General.time", "23:22:33", "fei_metadata.User.Time"),
              md("General.authors", "planted", "fei_metadata.User.User")]
    fei_px = [[1, 2], [3, 255]]
    tags = common_tags(bo, 2, 2, 8, sample_format=1) + [(34682, T_ASCII, asc(ini))]
    add("fei-helios.tif", bo, False, [{"tags": tags, "strips": [bytes(v for r in fei_px for v in r)]}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YX", "shape": [2, 2], "dtype": "uint8", "pixels": fei_px,
                    "axes": YX(2, 2, 1.5e-09, 1.5e-09, 0.0, 0.0, "m", "m"), "metadata": fei_md}],
        "note": "34682 is the FEI INI. Beam.HV 200000 -> 200.0 (* 1e-3), WorkingDistance 0.004 -> 4.0 (* 1e3), "
                "User.Date and User.Time through dateutil: 2026-10-14 and 23:22:33. Scan.PixelWidth = PixelHeight."})

    ini2 = ("[User]\nDate=10/14/2026\nTime=11:22:33 AM\nUser=planted2\n[System]\nSystemType=Planted SEM\n[Beam]\nHV=30000\n"
            "[EBeam]\nBeamCurrent=2e-10\n[Scan]\nPixelWidth=1.5e-09\nPixelHeight=2.5e-09\nDwelltime=1e-05\n"
            "[Stage]\nStageX=0.001\nStageY=-0.002\nStageZ=0.003\nStageR=0.5\nStageT=-1.25\nWorkingDistance=0.0042\n")
    px = [[1, 2, 3], [4, 5, 6]]
    tags = common_tags(bo, 3, 2, 8, sample_format=1) + [(34682, T_ASCII, asc(ini2))]
    add("fei-helios-asym.tif", bo, False, [{"tags": tags, "strips": [bytes(v for r in px for v in r)]}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YX", "shape": [2, 3], "dtype": "uint8", "pixels": px,
                    "axes": YX(2, 3, 1.5e-09, 2.5e-09, 0.0, 0.0, "m", "m"),
                    "metadata": [md("General.original_filename", "fei-helios-asym.tif"), md("Signal.signal_type", ""),
                                 md("Acquisition_instrument.SEM.beam_energy", 30.0, "fei_metadata.Beam.HV"),
                                 md("Acquisition_instrument.SEM.Stage.x", 0.001, "fei_metadata.Stage.StageX"),
                                 md("Acquisition_instrument.SEM.Stage.y", -0.002, "fei_metadata.Stage.StageY"),
                                 md("Acquisition_instrument.SEM.Stage.z", 0.003, "fei_metadata.Stage.StageZ"),
                                 md("Acquisition_instrument.SEM.Stage.rotation", 0.5, "fei_metadata.Stage.StageR"),
                                 md("Acquisition_instrument.SEM.Stage.tilt", -1.25, "fei_metadata.Stage.StageT"),
                                 md("Acquisition_instrument.SEM.working_distance", 4.2, "fei_metadata.Stage.WorkingDistance"),
                                 md("Acquisition_instrument.SEM.dwell_time", 1e-05, "fei_metadata.Scan.Dwelltime"),
                                 md("Acquisition_instrument.SEM.beam_current", 0.2, "fei_metadata.EBeam.BeamCurrent"),
                                 md("Acquisition_instrument.SEM.microscope", "Planted SEM", "fei_metadata.System.SystemType"),
                                 md("General.date", "2026-10-14", "fei_metadata.User.Date"),
                                 md("General.time", "11:22:33", "fei_metadata.User.Time"),
                                 md("General.authors", "planted2", "fei_metadata.User.User")]}],
        "note": "Every key of RosettaSciIO's mapping_fei, and PixelWidth != PixelHeight: the height axis takes PixelWidth "
                "(1.5e-09, the 'x' entry), the width axis takes PixelHeight (2.5e-09): the _order_axes_by_name cross-over."})

    ini3 = "[IRBeam]\nHFW=3e-05\nVFW=6e-05\n[Image]\nResolutionX=3\nResolutionY=2\n"
    tags = common_tags(bo, 3, 2, 8, sample_format=1) + [(34682, T_ASCII, asc(ini3))]
    add("fei-irbeam.tif", bo, False, [{"tags": tags, "strips": [bytes(v for r in px for v in r)]}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YX", "shape": [2, 3], "dtype": "uint8", "pixels": px,
                    "axes": YX(2, 3, 1e-05, 3e-05, 0.0, 0.0, "m", "m"),
                    "metadata": [md("General.original_filename", "fei-irbeam.tif"), md("Signal.signal_type", "")]}],
        "note": "No [Scan]: x = IRBeam.HFW / Image.ResolutionX = 1e-05, y = VFW / ResolutionY = 3e-05; the height axis takes x "
                "(1e-05), the width axis y (3e-05)."})

    # --- 9. a tag zoo (classic, big-endian) -------------------------------------------------------------------------
    bo = ">"
    tags = common_tags(bo, 2, 2, 8, sample_format=1)
    tags += [(65100, T_BYTE, [1, 2, 255]), (65101, T_SBYTE, [-1, 2]), (65102, T_SSHORT, [-2, 300]), (65103, T_SLONG, [-70000]),
             (65104, T_SRATIONAL, [(-3, 4), (5, -6)]), (65105, T_FLOAT, [0.5, -0.0]), (65106, T_UNDEF, b"\x00\xff\x10"),
             (65107, T_SHORT, [1, 2, 3]), (65108, T_RATIONAL, [(1, 3)]), (65109, T_DOUBLE, [1.25, -2.5]),
             (65110, T_ASCII, b"ab\0cd\0"), (65111, T_LONG, [4000000000]), (65112, T_ASCII, b"abc")]
    add("tag-zoo.tif", bo, False, [{"tags": tags, "strips": [bytes([1, 2, 3, 4])]}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YX", "shape": [2, 2], "dtype": "uint8", "pixels": [[1, 2], [3, 4]], "axes": YX(2, 2),
                    "metadata": [md("General.original_filename", "tag-zoo.tif"), md("Signal.signal_type", "")]}],
        "note": "One private tag per classic TIFF datatype (65100-65112): the tag walker's types. 65110 is 'ab', NUL, 'cd', NUL; "
                "65112 is 'abc' with no terminating NUL."})

    # --- 9b. two behaviours of tifffile / RosettaSciIO that are easy to miss ------------------------------------------------
    bo = "<"
    tags = common_tags(bo, 2, 2, 8, sample_format=1) + [(270, T_ASCII, asc("hello")), (306, T_ASCII, asc("2026/10/14 22:11"))]
    add("datetime-slash-description.tif", bo, False, [{"tags": tags, "strips": [bytes([1, 2, 3, 4])]}], {
        "kind": "read", "in_scope": True, "pages": 1,
        "series": [{"tifffile_axes": "YX", "shape": [2, 2], "dtype": "uint8", "pixels": [[1, 2], [3, 4]], "axes": YX(2, 2),
                    "metadata": [md("General.original_filename", "datetime-slash-description.tif"), md("Signal.signal_type", "")]}],
        "note": "DateTime in the '%Y/%m/%d %H:%M' form AND an ImageDescription: RosettaSciIO's fallback for a failed first format "
                "reads op['ImageDescription']['DateTime'] (the JEOL SightX branch) before it tries the slash format, a str "
                "indexed by a str raises, and the slash format is never tried: no General.date or General.time. "
                "le-u16-3strips.tif (no ImageDescription) does get them."})

    tags = common_tags(bo, 2, 2, 8, sample_format=1) + [(65200, 99, b"abcd")]
    add("unknown-tag-type.tif", bo, False, [{"tags": tags, "strips": [bytes([1, 2, 3, 4])]}], {
        "kind": "read", "in_scope": True, "pages": 1, "tifffile_ignores_tags": [65200],
        "series": [{"tifffile_axes": "YX", "shape": [2, 2], "dtype": "uint8", "pixels": [[1, 2], [3, 4]], "axes": YX(2, 2),
                    "metadata": [md("General.original_filename", "unknown-tag-type.tif"), md("Signal.signal_type", "")]}],
        "note": "Tag 65200 has datatype 99 (4 bytes). tifffile logs 'invalid data type 99' and drops the tag from the page: it is "
                "absent from the pins; the pixels read normally. A walker that keeps unknown types as bytes "
                "has one more tag than tifffile; the test asserts it and states why."})

    # --- 10. refusals -------------------------------------------------------------------------------------------------
    bo = "<"
    tags = common_tags(bo, 2, 2, 8, sample_format=1)
    tags = [t if t[0] != 259 else (259, T_SHORT, [5]) for t in tags]
    add("lzw.tif", bo, False, [{"tags": tags, "strips": [b"\x80\x00\x80\x01"]}], {
        "kind": "refusal", "in_scope": False, "pages": 1,
        "refusal": {"reason": "compression", "tag": 259, "value": 5, "message_names": ["Compression", "5"]},
        "note": "Compression 5 (LZW): the strips are not LZW data; the reader refuses before decoding."})

    tags = common_tags(bo, 2, 2, 8, sample_format=1)
    tags = [t for t in tags if t[0] not in (278,)]
    tags += [(322, T_SHORT, [16]), (323, T_SHORT, [16])]
    add("tiled.tif", bo, False, [{"tags": tags, "strips": [bytes(256)], "offsets_code": 324, "counts_code": 325}], {
        "kind": "refusal", "in_scope": False, "pages": 1,
        "refusal": {"reason": "tiled", "tag": 322, "value": 16, "message_names": ["TileWidth", "322"]},
        "note": "TileWidth and TileLength 16, TileOffsets and TileByteCounts, no StripOffsets."})

    tags = common_tags(bo, 2, 2, 8, sample_format=1)
    add("strip-past-end.tif", bo, False,
        [{"tags": tags, "strips": [bytes([1, 2, 3, 4])], "fake_offsets": [100000]}], {
            "kind": "refusal", "in_scope": True, "pages": 1,
            "refusal": {"reason": "strip outside the file", "tag": 273, "value": 100000, "message_names": ["StripOffsets"]},
            "note": "One strip of 4 bytes whose StripOffsets (100000) lies beyond the end of the file (the file is a few hundred bytes)."})
    return out


# ------------------------------------------------------------------------------------------------------------ the reading

def load_pins():
    """tools/step-2/pins.py as a module (a script directory is not on sys.path under -I)."""
    spec = importlib.util.spec_from_file_location("step2_pins", Path(__file__).with_name("pins.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def compare(truth_series, reading):
    """Hand-written expectations against the oracle's reading of the same bytes. Returns a list of difference strings."""
    diffs = []
    got = reading["series"]
    if len(got) != len(truth_series):
        return [f"series: expected {len(truth_series)}, RosettaSciIO returned {len(got)}"]
    for i, (t, g) in enumerate(zip(truth_series, got)):
        p = f"series[{i}]"
        if t["tifffile_axes"] != g["tifffile_axes"]:
            diffs.append(f"{p}.tifffile_axes: expected {t['tifffile_axes']}, got {g['tifffile_axes']}")
        if t.get("tifffile_kind") and t["tifffile_kind"] != g["tifffile_kind"]:
            diffs.append(f"{p}.tifffile_kind: expected {t['tifffile_kind']}, got {g['tifffile_kind']}")
        if t["shape"] != g["shape"]:
            diffs.append(f"{p}.shape: expected {t['shape']}, got {g['shape']}")
        if t["dtype"].startswith("rgb"):
            if g["dtype_as_returned"].replace(">", "<") != t["dtype_rsciio"]:
                diffs.append(f"{p}.dtype: expected {t['dtype_rsciio']}, got {g['dtype_as_returned']}")
        elif t["dtype"] != g["dtype"]:
            diffs.append(f"{p}.dtype: expected {t['dtype']}, got {g['dtype']}")
        if t["axes"] != g["axes"]:
            diffs.append(f"{p}.axes: expected {json.dumps(t['axes'])}, got {json.dumps(g['axes'])}")
        # the metadata: expected entries must be present, with these values, in this order; extra ones are listed
        exp = [(e["key"], e["value"], e.get("value_bits"), e.get("source")) for e in t["metadata"]]
        have = [(e["key"], e["value"], e.get("value_bits"), e.get("source")) for e in g["metadata"]]
        if exp != have:
            diffs.append(f"{p}.metadata: expected {json.dumps(exp)}, got {json.dumps(have)}")
    return diffs


def expected_data_sha(t):
    """sha256 of the planted pixels as little-endian bytes, to compare with the oracle's data_sha256."""
    dt = t["dtype"]
    fmt = {"uint8": "B", "uint16": "H", "int16": "h", "float32": "f", "rgb8": "B", "rgba16": "H"}[dt]
    flat = []

    def walk(x):
        if isinstance(x, list):
            for y in x:
                walk(y)
        else:
            flat.append(x)
    walk(t["pixels"])
    return hashlib.sha256(struct.pack(f"<{len(flat)}{fmt}", *flat)).hexdigest()


def build(pins, R, np, directory):
    """Writes the files into `directory` (existing) and returns (files {name: bytes}, truth json text)."""
    files = make_files()
    for f in files:
        (directory / f["name"]).write_bytes(f["bytes"])
    records = {}
    for f in files:
        name = f["name"]
        t = f["truth"]
        entry = {
            "file": name, "sha256": hashlib.sha256(f["bytes"]).hexdigest(), "bytes": len(f["bytes"]),
            "bigtiff": f["bigtiff"], "byteorder": f["bo"], "kind": t["kind"], "in_scope": t["in_scope"],
            "pages": t["pages"], "note": t["note"],
            "tags": [[decode_tag_truth(f["bo"], c, ty, n, raw) for (c, ty, n, raw) in pg["entries"]] for pg in f["layout"]],
            "strip_offsets": [pg["strip_offsets"] for pg in f["layout"]],
            "strip_counts": [pg["strip_counts"] for pg in f["layout"]],
        }
        reading = pins.file_record(directory / name, "planted/" + name, "planted", R)
        entry["reading"] = reading
        diffs = []
        if t["kind"] == "read":
            entry["series"] = t["series"]
            entry["tifffile_ignores_tags"] = t.get("tifffile_ignores_tags", [])
            for s in entry["series"]:
                s["data_sha256"] = expected_data_sha(s)
                s["navigate"] = [a["navigate"] for a in s["axes"]]
            diffs += compare(t["series"], reading)
            for i, (s, g) in enumerate(zip(t["series"], reading["series"])):
                if s["data_sha256"] != g["data_sha256"]:
                    diffs.append(f"series[{i}].data_sha256: expected {s['data_sha256']}, got {g['data_sha256']}")
            if reading["raises"] is not None:
                diffs.append("RosettaSciIO raised " + json.dumps(reading["raises"]))
            if reading["in_scope"] is not True:
                diffs.append("pins.py says out of scope: " + str(reading["out_of_scope"]))
            # the stored tags as tifffile reads them: code, type, count must equal what was written
            ignored = set(t.get("tifffile_ignores_tags", []))
            wrote = {(c, ty, n) for (c, ty, n, raw) in f["layout"][0]["entries"] if c not in ignored}
            read = {(g["code"], g["type"], g["count"]) for g in reading["tags"]}
            if wrote != read:
                diffs.append(f"page-0 tags written but not read or read but not written: {sorted(wrote ^ read)}")
            for g in reading["tags"]:
                raw = next(r for (c, ty, n, r) in f["layout"][0]["entries"] if c == g["code"])
                if hashlib.sha256(raw).hexdigest() != g["raw_sha256"]:
                    diffs.append(f"tag {g['code']}: raw_sha256 differs from the bytes written")
        else:
            entry["refusal"] = t["refusal"]
            if reading["in_scope"] is not t["in_scope"]:
                diffs.append(f"pins.py in_scope is {reading['in_scope']}, expected {t['in_scope']} ({reading['out_of_scope']})")
            if reading["raises"] is None and not reading["out_of_scope"]:
                diffs.append("RosettaSciIO read a refusal file without raising and pins.py's rule does not exclude it")
        entry["disagreements"] = diffs
        records[name] = entry
    out = {
        "generator": "tools/step-2/make_planted.py",
        "reference": f"RosettaSciIO {pins.PIN}, tifffile {pins.TIFFFILE_VERSION} (the readings; the truth is written by hand)",
        "versions": pins.versions(np),
        "files": [records[f["name"]] for f in files],
    }
    return {f["name"]: f["bytes"] for f in files}, pins.dump(out)


def main():
    warnings.simplefilter("ignore")
    logging.disable(logging.CRITICAL)   # tifffile's and RosettaSciIO's notes on deliberately odd files
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", metavar="DIR", help="write into DIR instead of Tests/FormatoTIFFTests/Fixtures/planted")
    a = ap.parse_args()
    out_dir = Path(a.out) if a.out else PLANTED
    pins = load_pins()
    R = pins.load_oracle()
    import numpy as np
    out_dir.mkdir(parents=True, exist_ok=True)
    first = build(pins, R, np, out_dir)
    second = build(pins, R, np, out_dir)
    if first != second:
        die("two builds differ: not byte-reproducible")
    (out_dir / "planted-truth.json").write_text(first[1], encoding="utf-8")
    truth = json.loads(first[1])
    bad = 0
    for rec in truth["files"]:
        status = "ok" if not rec["disagreements"] else f"{len(rec['disagreements'])} DISAGREEMENT(S)"
        print(f"{rec['file']}: {rec['bytes']} bytes, sha256 {rec['sha256'][:16]}, {status}")
        for d in rec["disagreements"]:
            print("   -", d)
            bad += 1
    print(f"planted-truth.json: {len(first[1].encode('utf-8'))} bytes, sha256 {hashlib.sha256(first[1].encode('utf-8')).hexdigest()}")
    print(f"{len(truth['files'])} files, {bad} disagreement(s) between the hand-written truth and the oracle")


if __name__ == "__main__":
    main()

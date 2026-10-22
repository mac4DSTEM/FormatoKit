#!/usr/bin/env python3
"""Pins RosettaSciIO's reading of tifffile-written TIFFs with tifffile's shaped description (FormatoKit 0.11.0).

    References/rsciio-venv/bin/python -I -B tools/shaped-tiff/pins.py
        writes Tests/FormatoTIFFTests/Fixtures/shaped/*.tif   (small files, tifffile's own writer, seeded content)
        and   Tests/FormatoTIFFTests/Fixtures/shaped-pins.json

tifffile's default `imwrite(array)` stores `{"shape": [...]}` in the ImageDescription ("shaped"); `TiffFile.series` then uses
`series_shaped`, which `TIFFShapedSeries.swift` ports. Each file is read with `rsciio.tiff.file_reader` and recorded in the
format of tools/step-2/pins.py (that script's `file_record`, imported here): tifffile's series (kind, axes, shape), then for
each signal the data's sha256, shape, element type, every axis field with its bits, and the metadata. A file RosettaSciIO
raises on is recorded with "raises" (FormatoKit refuses it). The same checks as step-2 run first (versions, pin, install).
Everything is built twice in the process, in two fresh directories, and the script stops if the files or the JSON differ.
"""
import importlib.util
import json
import sys
import tempfile
import warnings
import logging
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests" / "FormatoTIFFTests" / "Fixtures"
OUT = FIXTURES / "shaped"

spec = importlib.util.spec_from_file_location("step2_pins", ROOT / "tools" / "step-2" / "pins.py")
S2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(S2)


def content(np, shape, dtype, seed):
    """Deterministic content: distinct values everywhere so a wrong page, row or order shows."""
    rng = np.random.default_rng(seed)
    dt = np.dtype(dtype)
    if dt.kind == "f":
        return rng.uniform(-100, 100, shape).astype(dt)
    info = np.iinfo(dt)
    return rng.integers(max(info.min, -30000), min(info.max, 60000) + 1, shape).astype(dt)


# name -> (shape, dtype, imwrite kwargs); kwargs are what makes the file
CASES = {
    "2d_u2": ((7, 9), "<u2", {}),
    "2d_f4_be": ((7, 9), ">f4", {"byteorder": ">"}),
    "2d_i1": ((6, 5), "<i1", {}),
    "stack_u1": ((6, 7, 9), "<u1", {}),
    "stack_i2": ((5, 7, 9), "<i2", {}),
    "stack_u2_be": ((5, 7, 9), ">u2", {"byteorder": ">"}),
    "stack_i4": ((5, 5, 6), "<i4", {}),
    "stack_u4_be": ((5, 5, 6), ">u4", {"byteorder": ">"}),
    "stack_f4": ((5, 7, 9), "<f4", {}),
    "stack_f8": ((2, 5, 6), "<f8", {}),
    "stack_i8": ((2, 5, 6), "<i8", {}),
    "stack_u8_be": ((2, 5, 6), ">u8", {"byteorder": ">"}),
    "planar_rgb": ((3, 7, 9), "<u1", {}),
    "stack_bigtiff": ((5, 7, 9), "<u2", {"bigtiff": True}),
    "stack_bigtiff_be": ((5, 7, 9), ">i2", {"bigtiff": True, "byteorder": ">"}),
    "stack_rowsperstrip": ((5, 7, 9), "<u2", {"rowsperstrip": 2}),
    "stack_truncated": ((5, 7, 9), "<u2", {"truncate": True}),
    "multi4d_i2": ((2, 5, 7, 9), "<i2", {}),
    "multi4d_u1_be": ((2, 5, 7, 9), "u1", {"byteorder": ">"}),
    "multi5d_u2": ((2, 3, 5, 6, 8), "<u2", {}),
    "single_frame": ((1, 7, 9), "<u1", {}),
    "singleton_second": ((5, 1, 7, 9), "<u2", {}),
    "tail1": ((7, 9, 1), "<u1", {}),
    "tail1_stack": ((5, 7, 9, 1), "<u2", {}),
    "rgb8": ((7, 9, 3), "u1", {}),
    "rgb8_stack": ((2, 7, 9, 3), "u1", {}),
    "rgba16": ((7, 9, 4), "<u2", {"photometric": "rgb"}),
    "axes_tyx": ((5, 7, 9), "<u2", {"metadata": {"axes": "TYX"}}),
    "axes_tzyx_extra": ((2, 5, 7, 9), "<u2", {"metadata": {"axes": "TZYX", "foo": "bar", "name": "scan"}}),
    "axes_zyx_truncated": ((5, 7, 9), "<i2", {"truncate": True, "metadata": {"axes": "ZYX"}}),
    "axes_unknown_code": ((5, 7, 9), "<u2", {"metadata": {"axes": "MYX"}}),
    "axes_wrong_length": ((5, 7, 9), "<u2", {"metadata": {"axes": "YX"}}),
    "date_resolution": ((2, 7, 9), "<u2", {"datetime": datetime(2026, 10, 22, 12, 34, 56), "resolution": (100, 200), "resolutionunit": "CENTIMETER"}),
    "old_description": ((5, 7, 9), "<u2", {"description": "shape=(5, 7, 9)", "metadata": None}),
    "old_description_bad": ((5, 7, 9), "<u2", {"description": "shape=(5, 7,)", "metadata": None}),
    "description_not_multiple": ((5, 7, 9), "<u2", {"description": '{"shape": [5, 6, 9]}', "metadata": None}),
    "description_bad_json": ((5, 7, 9), "<u2", {"description": '{"shape": [5, 7, 9}', "metadata": None}),
    "description_shape_text": ((5, 7, 9), "<u2", {"description": '{"shape": "5x7x9"}', "metadata": None}),
    "description_reshape_page": ((5, 7, 9), "<u2", {"description": '{"shape": [5, 63]}', "metadata": None}),
    "description_reshape_split": ((6, 7, 9), "<u2", {"description": '{"shape": [2, 3, 7, 9]}', "metadata": None}),
    "description_reshape_split_rows": ((5, 8, 9), "<u2", {"description": '{"shape": [5, 2, 4, 9]}', "metadata": None}),
    "description_bigger_than_pages": ((2, 7, 9), "<u2", {"description": '{"shape": [5, 7, 9]}', "metadata": None}),
    "description_reshape_underflow": ((1, 1), "<u2", {"description": '{"shape": [1, 1, 1, 1, 1]}', "metadata": None}),
    "description_rank0": ((1, 1), "<u2", {"description": '{"shape": []}', "metadata": None}),
}


def write_case(np, tifffile, path, name):
    shape, dtype, kw = CASES[name]
    seed = sum(name.encode())
    a = content(np, shape, dtype, seed)
    kw = dict(kw)
    if kw.get("byteorder") == ">" or dtype.startswith(">"):
        kw["byteorder"] = ">"
    if "description" in kw or "metadata" in kw:
        pass
    tifffile.imwrite(path, a, **kw)


def write_special(np, tifffile, out):
    """Files that need the writer API: several shaped series, a pyramid, pages with strips of their own."""
    def series(path, parts, **kw):
        with tifffile.TiffWriter(path, **kw) as tw:
            for i, (shape, dtype, wkw) in enumerate(parts):
                tw.write(content(np, shape, dtype, 1000 + i + len(shape)), **wkw)
    series(out / "series_two.tif", [((2, 7, 9), "<u2", {}), ((7, 9), "<f4", {})])
    series(out / "series_three_be.tif", [((2, 5, 6), ">i2", {}), ((5, 5, 6), ">u1", {}), ((1, 5, 6), ">i2", {})], byteorder=">")
    series(out / "series_pyramid.tif", [((16, 16), "<u2", {}), ((8, 8), "<u2", {"subfiletype": 1}), ((4, 4), "<u2", {"subfiletype": 1})])
    series(out / "series_reduced_not_pyramid.tif", [((16, 16), "<u2", {}), ((8, 10), "<u2", {"subfiletype": 1})])
    series(out / "series_noncontiguous.tif", [((5, 7, 9), "<u2", {"contiguous": False}), ((5, 7, 9), "<u2", {"contiguous": False})])
    series(out / "series_append_bigtiff.tif", [((2, 5, 6), "<f4", {}), ((2, 5, 6), "<f4", {})], bigtiff=True)


def build(out):
    R = S2.load_oracle()
    np, tifffile = R["np"], R["tifffile"]
    out.mkdir(parents=True, exist_ok=True)
    for name in CASES:
        write_case(np, tifffile, out / (name + ".tif"), name)
    write_special(np, tifffile, out)
    files = []
    for p in sorted(out.glob("*.tif")):
        files.append(S2.file_record(p, "shaped/" + p.name, "shaped", R))
    doc = {"generator": "tools/shaped-tiff/pins.py",
           "reference": f"RosettaSciIO {S2.PIN} (rsciio.tiff.file_reader, defaults); tifffile {S2.TIFFFILE_VERSION}",
           "versions": S2.versions(np), "files": files}
    return S2.dump(doc), files


def main():
    warnings.simplefilter("ignore")
    logging.disable(logging.CRITICAL)
    with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
        a, files = build(Path(t1) / "shaped")
        b, _ = build(Path(t2) / "shaped")
        if a != b:
            sys.exit("pins.py: two builds differ: not byte-reproducible")
        for p in sorted((Path(t1) / "shaped").glob("*.tif")):
            if p.read_bytes() != (Path(t2) / "shaped" / p.name).read_bytes():
                sys.exit(f"pins.py: {p.name} differs between two builds")
        OUT.mkdir(parents=True, exist_ok=True)
        for old in OUT.glob("*.tif"):
            old.unlink()
        for p in sorted((Path(t1) / "shaped").glob("*.tif")):
            (OUT / p.name).write_bytes(p.read_bytes())
    (FIXTURES / "shaped-pins.json").write_text(a, encoding="utf-8")
    print(f"shaped-pins.json: {len(a.encode())} bytes, {len(files)} files")
    for f in files:
        ser = [(s["tifffile_kind"], s["tifffile_axes"], s["shape"]) for s in f["series"]]
        print(f["path"], f["bytes"], "RAISES " + f["raises"]["type"] + ": " + f["raises"]["message"][:70] if f["raises"] else ser)


if __name__ == "__main__":
    main()

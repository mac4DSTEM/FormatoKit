#!/usr/bin/env python3
"""Writes the truth files that FormatoDMTests/DM4EELSSpectrumImageTests.swift compares `readEELSSpectrumImage` with.
From SpectroKit 0.3.0 (tools/eels-reader/truth.py), where these fixtures were first written; only the fixture folder and
the pinned checkout's folder name differ, so the files it writes are the committed ones byte for byte:

    truth.py [--references DIR] [--out DIR]

    Tests/FormatoDMTests/Fixtures/rsciio-EELS_SI.truth.json   <- rsciio-EELS_SI.dm4 (RosettaSciIO 049e7d70's public
                                                                  digitalmicrograph/3D/EELS_SI.dm4, sha256 checked)
    Tests/FormatoDMTests/Fixtures/eels-planted.truth.json     <- eels-planted.dm4 (tools/eels-reader/make_planted.py)
    Tests/FormatoDMTests/Fixtures/eels-refused-{zero,short,long}.truth.json  <- the three one-object files whose Data tag
                                                                  length is wrong: rsciio raises; the exception is recorded
    Tests/FormatoDMTests/Fixtures/eels-refused-zerodim.truth.json  <- a [3, 0, 5] cube: rsciio's reading (or raise) as it is

The reference is RosettaSciIO 049e7d70's `rsciio.digitalmicrograph.file_reader`, from the PINNED checkout
(`<references>/rosettasciio-049e7d70`, put first on sys.path; the script stops if `rsciio.__file__` is not inside it: the venv
carries its own 0.14.0 and this must not be that one). Agreement with RosettaSciIO is agreement with an independent reading
of the same bytes; what the planted file holds is also written out as literals in the Swift test.

Run it with the RosettaSciIO venv's interpreter, isolated (tools/README.md):
    References/rsciio-venv/bin/python -I -B tools/eels-reader/truth.py [--references DIR]
Only the standard library and NumPy are used besides rsciio. The output is byte-reproducible (sorted keys, no times, no
absolute paths); the script runs the reading twice and stops if the two outputs differ.

What is written, per object that rsciio returns (the thumbnail is excluded by rsciio, as `Thumbnails.N.ImageIndex`):
  index          the ONE-BASED position in `ImageList` (SpectroKit's `DM4ImageObject.index`; rsciio's `TagGroup<k>` is k = index - 1)
  rsciio_shape   the array shape rsciio returns, (channels, ny, nx) for a spectrum image: rsciio reverses DM's
                 `Dimensions` (x, y, energy; fastest first) and reshapes in C order, so it IS the file's memory order
  rsciio_axes    rsciio's axes dicts, in rsciio's order (name, size, index_in_array, scale, offset, units), offset = -origin * scale
  data_offset, data_bytes   where the pixel block starts in the file and its length, from rsciio's parser (the block is checked
                 to be exactly the bytes of the array rsciio returns)
  nx, ny, channels, order   SpectroKit's names; counts as SpectroKit returns them: `(y, x, channel)` C order, which is
                 rsciio's array transposed with `.transpose(1, 2, 0)` (axes 0,1,2 = channel,y,x -> y,x,channel)
  counts_sha256  sha256 of those counts as float32 little-endian bytes (the `astype('<f4')` of rsciio's integer or float
                 array: round-to-nearest-even, the conversion Swift's Float(x) does)
  samples        exact values at fixed (y, x, channel), as the float32 value written as a double (exact)
  beam_energy_keV, convergence_angle_mrad, collection_angle_mrad
                 the metadata values rsciio's mapping gives (`file_reader`'s `mapping`, applied the way HyperSpy applies
                 it: value at the original_metadata path, passed through the mapping function), null when the tag is
                 absent; `beam_energy_key` says whether rsciio put E0 under TEM or SEM
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = "Tests/FormatoDMTests/Fixtures"
REAL = "rsciio-EELS_SI.dm4"
REAL_SHA256 = "f9b8203f384cc355437594b649d4ea3a12cddeb231ebb65508a841a379fa171a"   # rsciio/tests/registry.txt
PLANTED = "eels-planted.dm4"
# make_planted.py's one-object files whose Data tag declares 0, 29 and 31 elements for a 3 x 2 x 5 cube: rsciio RAISES on each
REFUSED = ("eels-refused-zero.dm4", "eels-refused-short.dm4", "eels-refused-long.dm4")
ZERO_DIM = "eels-refused-zerodim.dm4"      # [3, 0, 5] with an empty Data tag: the reader refuses it; rsciio's behaviour is recorded as it is
RSCIIO_COMMIT = "049e7d7070e84779b499adaf3295beee9facb004"

TARGETS = {
    "beam_energy_keV": ("Acquisition_instrument.TEM.beam_energy", "Acquisition_instrument.SEM.beam_energy"),
    "convergence_angle_mrad": ("Acquisition_instrument.TEM.convergence_angle",),
    "collection_angle_mrad": ("Acquisition_instrument.TEM.Detector.EELS.collection_angle",),
}


def load_rsciio(references):
    pinned = (Path(references) / "rosettasciio-049e7d70").resolve()
    sys.path.insert(0, str(pinned))
    import rsciio
    where = Path(rsciio.__file__).resolve()
    if pinned not in where.parents:
        sys.exit(f"rsciio imported from {where}, not from the pinned checkout {pinned}")
    from rsciio.digitalmicrograph import file_reader
    from rsciio.digitalmicrograph._api import DigitalMicrographReader
    return file_reader, DigitalMicrographReader, pinned


def lookup(tree, dotted):
    node = tree
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def mapped_metadata(signal):
    """Apply rsciio's returned `mapping` to the signal's original_metadata, as HyperSpy does for each entry that has a value."""
    md = {}
    for source, (target, func) in signal["mapping"].items():
        value = lookup(signal["original_metadata"], source)
        if value is None:
            continue
        md[target] = func(value) if func else value
    return md


def one_file(path, references, np, file_reader, DigitalMicrographReader):
    raw = path.read_bytes()
    with open(path, "rb") as f:
        dm = DigitalMicrographReader(f)
        dm.parse_file()
        thumbs = [t["ImageIndex"] for t in dm.tags_dict["Thumbnails"].values()] if "Thumbnails" in dm.tags_dict else []
        groups = [k for k in dm.tags_dict["ImageList"] if int(k.replace("TagGroup", "")) not in thumbs]
        blocks = {k: dm.tags_dict["ImageList"][k]["ImageData"]["Data"] for k in groups}
    signals = file_reader(str(path))
    assert len(signals) == len(groups), (len(signals), groups)
    objects = []
    for key, sig in zip(groups, signals):
        data = np.asarray(sig["data"])
        entry = {
            "index": int(key.replace("TagGroup", "")) + 1,
            "name": sig["original_metadata"]["ImageList"]["TagGroup0"]["Name"],
            "rsciio_dtype": str(data.dtype),
            "rsciio_shape": list(data.shape),
            "rsciio_axes": [
                {"name": a["name"], "size": int(a["size"]), "index_in_array": int(a["index_in_array"]),
                 "scale": float(a["scale"]), "offset": float(a["offset"]), "units": a["units"]}
                for a in sig["axes"]],
            "signal_type": sig["metadata"]["Signal"]["signal_type"],
        }
        block = blocks[key]
        start, length = int(block["offset"]), int(block["size_bytes"])
        assert raw[start:start + length] == data.tobytes(), "rsciio's data block is not the array it returns"
        entry["data_offset"], entry["data_bytes"] = start, length
        md = mapped_metadata(sig)
        for field, keys in TARGETS.items():
            hit = [k for k in keys if k in md]
            entry[field] = float(md[hit[0]]) if hit else None
            if field == "beam_energy_keV":
                entry["beam_energy_key"] = hit[0] if hit else None
        if data.ndim == 3 and entry["signal_type"] == "EELS":
            ch, ny, nx = data.shape
            yxc = np.ascontiguousarray(data.transpose(1, 2, 0)).astype("<f4")
            entry.update({
                "nx": nx, "ny": ny, "channels": ch,
                "order": "counts[(y*nx + x)*channels + c] = rsciio_array[c, y, x] (array.transpose(1, 2, 0)), float32 little-endian",
                "counts_sha256": hashlib.sha256(yxc.tobytes()).hexdigest(),
                "samples": [
                    {"y": y, "x": x, "c": c, "value": float(yxc[y, x, c])}
                    for (y, x, c) in sorted({(0, 0, 0), (0, nx - 1, 0), (ny - 1, 0, 0), (ny - 1, nx - 1, ch - 1),
                                             (0, nx - 1, ch - 1), (ny - 1, 0, ch // 2), (ny // 2, nx // 2, ch // 3),
                                             (0, 1 % nx, 1 % ch)})],
            })
        objects.append(entry)
    return {"file": path.name, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw), "objects": objects}


def refused_file(path, file_reader):
    """rsciio's reading of a file it must refuse: the exception type and message (no signal is returned)."""
    raw = path.read_bytes()
    try:
        file_reader(str(path))
    except Exception as e:      # whatever rsciio raises is the record
        return {"file": path.name, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw),
                "rsciio_raises": True, "rsciio_exception": type(e).__name__, "rsciio_message": str(e)}
    if path.name != ZERO_DIM:
        sys.exit(f"{path.name}: rsciio read it; the file was meant to be refused")
    sig = file_reader(str(path))
    return {"file": path.name, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw), "rsciio_raises": False,
            "rsciio_shapes": [list(s["data"].shape) for s in sig]}


def build(fixtures, references):
    file_reader, DigitalMicrographReader, pinned = load_rsciio(references)
    import numpy as np
    real = fixtures / REAL
    got = hashlib.sha256(real.read_bytes()).hexdigest()
    if got != REAL_SHA256:
        sys.exit(f"{REAL} sha256 {got} is not rsciio's registry value {REAL_SHA256}")
    head = {
        "generator": "tools/eels-reader/truth.py",
        "reference": f"RosettaSciIO {RSCIIO_COMMIT} (rsciio.digitalmicrograph.file_reader), numpy {np.__version__}",
        "rsciio_checkout": "References/rosettasciio",
    }
    out = {}
    for name in (REAL, PLANTED):
        t = dict(head)
        t.update(one_file(fixtures / name, references, np, file_reader, DigitalMicrographReader))
        out[name.replace(".dm4", ".truth.json")] = json.dumps(t, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    for name in REFUSED + (ZERO_DIM,):
        t = dict(head)
        t.update(refused_file(fixtures / name, file_reader))
        out[name.replace(".dm4", ".truth.json")] = json.dumps(t, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--references", default=str(ROOT / "References"))
    ap.add_argument("--out", default=str(ROOT / FIXTURES))
    args = ap.parse_args()
    fixtures = Path(args.out)
    first = build(fixtures, args.references)
    second = build(fixtures, args.references)
    if first != second:
        sys.exit("two readings differ: not byte-reproducible")
    for name, text in first.items():
        (fixtures / name).write_text(text, encoding="utf-8")
        print(f"{name}: {len(text.encode('utf-8'))} bytes, sha256 {hashlib.sha256(text.encode('utf-8')).hexdigest()}")


if __name__ == "__main__":
    main()

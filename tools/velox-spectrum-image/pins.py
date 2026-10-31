#!/usr/bin/env python3
"""Pins RosettaSciIO's reading of Velox spectrum images.

    References/rsciio-venv/bin/python -I -B tools/velox-spectrum-image/pins.py [--work DIR]
        writes Tests/FormatoCoreTests/Fixtures/step-4-pins.json
    References/rsciio-venv/bin/python -I -B tools/velox-spectrum-image/pins.py --owner FILE --out PATH [--options O1,O4,...]
        writes the same records for the owner's file to PATH (scratch, never committed; the file recorded by basename)

Every record is `rsciio.emd.file_reader(path, select_type="spectrum_image", lazy=False, **options)` for one file and one option
set (O1-O10): RosettaSciIO's exception, or per returned dictionary in order its dtype, shape, data_sha256
(little-endian C-order bytes), axes in list order (scale and offset as bits; HyperSpy keeps list order),
title, signal type and step 1's metadata entries. Needs `sparse` and `numba` in the venv: the script stops
without them, so the stream path is RosettaSciIO's real, jitted one.

Files: the public Velox files with a spectrum stream or an EELS spectrum image (step 1's zips, unzipped into a fresh
directory), the planted files (tools/velox-spectrum-image/make_velox_si.py, regenerated here first and checked byte-equal to the committed
ones), and the copies of SpectroKit's planted streams. For every planted file and option set RosettaSciIO's arrays must
equal the planted truth (`make_velox_si.expected`), or the script stops.

Kernel pins: RosettaSciIO's `stream_to_array` on synthetic streams given as runs [[value, repeat], ...].
Outputs are byte-reproducible (sorted keys, no times, no absolute paths); two builds in the process must agree.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Tests" / "FormatoCoreTests" / "Fixtures" / "step-4-pins.json"
PLANTED = ROOT / "Tests" / "FormatoEMDTests" / "Fixtures" / "step4"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


step1 = module("step1_pins", ROOT / "tools" / "dm-velox-pins" / "pins.py")
truth = module("make_velox_si", ROOT / "tools" / "velox-spectrum-image" / "make_velox_si.py")
die = step1.die


def sha(b):
    return hashlib.sha256(b).hexdigest()


def le_sha(data, np):
    """sha256 of the array's little-endian C-order bytes, as step 1's `le_bytes`, without copying an array that is already
    little-endian and contiguous (the owner's SI is 1.6 GB; a copy took the oracle past an 8 GB cap)."""
    a = np.ascontiguousarray(data)
    if a.dtype.byteorder == ">" or (a.dtype.byteorder == "=" and sys.byteorder == "big"):
        a = a.astype(a.dtype.newbyteorder("<"))
    return hashlib.sha256(memoryview(a).cast("B")).hexdigest()


def axis_record(a):
    def num(v):
        if isinstance(v, bool) or not isinstance(v, (int, float)) and not hasattr(v, "dtype"):
            return None, None
        return step1.jfloat(v), step1.bits(v)
    scale, scale_bits = num(a.get("scale"))
    offset, offset_bits = num(a.get("offset"))
    units = a.get("units")
    return {"name": a["name"], "size": int(a["size"]), "scale": scale, "scale_bits": scale_bits, "offset": offset,
            "offset_bits": offset_bits, "units": units if isinstance(units, str) or units is None else repr(units),
            "navigate": bool(a["navigate"])}


def signal_record(sig, np):
    data = np.asarray(sig["data"])
    md = sig["metadata"]
    axes = [axis_record(a) for a in sig["axes"]]
    rec = {
        "title": md.get("General", {}).get("title"),
        "signal_type": md.get("Signal", {}).get("signal_type"),
        "dtype": step1.dtype_name(data.dtype),
        "shape": list(data.shape),
        "data_sha256": le_sha(data, np),
        "axes": axes,
        "axes_sizes_match_shape": [a["size"] for a in axes] == list(data.shape),
        "axes_numeric": all(a["scale_bits"] is not None and a["offset_bits"] is not None for a in axes),
    }
    mdl = []
    if "title" in md.get("General", {}):
        mdl.append(step1.md_entry("General.title", md["General"]["title"]))
    original = md["General"]["original_filename"]
    rec["original_filename_is_path"] = os.path.basename(original) != original
    mdl.append(step1.md_entry("General.original_filename", os.path.basename(original)))
    if "mapping" in sig:
        got = step1.apply_mapping(sig, step1.BEAM_TARGETS)
        for t in step1.BEAM_TARGETS:
            if t in got:
                mdl.append(step1.md_entry(t, got[t][0], got[t][1]))
    rec["metadata"] = mdl
    return rec, data


def run(R, np, path, label, options, check=None):
    try:
        sigs = R["emd"].file_reader(str(path), lazy=False, select_type="spectrum_image", **options)
    except Exception as e:
        return {"options": options, "raises": step1.exception_record(e, path, Path(path).parent), "signals": []}
    recs = []
    arrays = []
    for s in sigs:
        r, a = signal_record(s, np)
        recs.append(r)
        arrays.append(a)
    if check is not None:
        check(arrays)
    return {"options": options, "raises": None, "signals": recs}


def file_record(R, np, path, label, set_name, option_sets, check_for=None):
    raw = Path(path).read_bytes()
    rec = {"set": set_name, "path": label, "sha256": sha(raw), "bytes": len(raw), "runs": {}}
    for key, opts in option_sets.items():
        check = check_for(key, opts) if check_for else None
        rec["runs"][key] = run(R, np, path, label, opts, check)
    return rec


def public_files(work, h5py):
    """The public Velox files with Data/SpectrumStream or Data/EelsSpectrumImage, in step 1's plan order."""
    unzipped = step1.unzip_all(work)
    out = []
    for path, label, kind in step1.public_plan(unzipped):
        if kind != "emd":
            continue
        with h5py.File(path, "r") as f:
            if "Version" not in f:
                continue
            if json.loads(f["Version"][0]).get("format") != "Velox":
                continue
            d = f.get("Data")
            if d is None or ("SpectrumStream" not in d and "EelsSpectrumImage" not in d):
                continue
        out.append((path, label))
    return out


def number_of_frames(path, h5py):
    """endFramePosition as RosettaSciIO reads it, or None (for O10)."""
    try:
        with h5py.File(path, "r") as f:
            sig = f["Data"]["SpectrumImage"]
            return int(json.loads(sig[next(iter(sig))]["SpectrumImageSettings"][0])["endFramePosition"])
    except Exception:
        return None


def option_sets_for(path, h5py, planted_pl=None):
    out = {}
    for key, opts in truth.OPTIONS.items():
        if opts is not None:
            out[key] = dict(opts)
        else:
            n = number_of_frames(path, h5py)
            if n is None:
                n = planted_pl.number_of_frames if planted_pl is not None else 1
            out[key] = {"last_frame": n + 1}
    return out

# ------------------------------------------------------------------------------------------------- kernel pins

KERNEL = [
    # name, grid (ny, nx), channels, first, last, rebin, sum_frames, dtype, runs [[value, repeat], ...]
    ("float32-past-2^24", (1, 1), 4, 0, 1, 1, True, "float32", [[2, (1 << 24) + 5], [1, 3]]),
    ("float64-small", (1, 2), 4, 0, 1, 1, True, "float64", [[3, 7], [65535, 1], [0, 2]]),
    ("uint8-wraps", (1, 2), 4, 0, 1, 1, True, "uint8", [[1, 300], [65535, 1], [1, 10], [3, 256]]),
    ("int8-wraps", (1, 1), 4, 0, 1, 1, True, "int8", [[2, 200], [0, 128], [1, 127]]),
    ("int16-wraps", (1, 1), 2, 0, 1, 1, True, "int16", [[1, 40000]]),
    ("uint16-wraps", (1, 1), 2, 0, 1, 1, True, "uint16", [[0, 70000], [1, 65535]]),
    ("uint32-int32-int64-uint64", (1, 1), 2, 0, 1, 1, True, "uint64", [[1, 9]]),
    ("int32", (1, 1), 2, 0, 1, 1, True, "int32", [[1, 9]]),
    ("int64", (1, 1), 2, 0, 1, 1, True, "int64", [[0, 4]]),
    ("uint32", (1, 1), 2, 0, 1, 1, True, "uint32", [[1, 5]]),
    ("last-frame-0-sums-all", (1, 2), 4, 0, 0, 1, True, "uint16",
     [[1, 2], [65535, 1], [2, 1], [65535, 1], [3, 4], [65535, 1], [1, 1], [65535, 1], [0, 5]]),
    ("partial-last-frame", (2, 2), 4, 0, 3, 1, True, "uint16",
     [[1, 1], [65535, 1], [2, 1], [65535, 1], [3, 1], [65535, 1], [0, 1], [65535, 1], [1, 2], [65535, 1], [2, 2]]),
    ("unterminated-4d", (2, 2), 4, 0, 2, 1, False, "uint16",
     [[1, 1], [65535, 1], [2, 1], [65535, 1], [3, 1], [65535, 1], [0, 1], [65535, 1], [1, 2], [65535, 1], [2, 2], [65535, 1], [3, 3], [65535, 1], [0, 4]]),
    ("first-frame-past-stream", (1, 2), 4, 5, 9, 1, True, "uint16", [[1, 3], [65535, 1], [2, 3], [65535, 1], [3, 1]]),
    ("frames-1-to-3-rebin-2-4d", (1, 3), 8, 1, 3, 2, False, "uint16",
     [[7, 1], [65535, 1], [6, 2], [65535, 1], [5, 3], [65535, 1], [4, 1], [65535, 1], [3, 2], [65535, 1], [2, 3], [65535, 1],
      [1, 1], [65535, 1], [0, 2], [65535, 1], [7, 3], [65535, 1], [6, 6], [65535, 1], [5, 5], [65535, 1], [4, 4]]),
    ("negative-first-summed", (1, 1), 2, -2, 2, 1, True, "uint16", [[1, 1], [65535, 1], [0, 2], [65535, 1], [1, 3]]),
    ("negative-first-4d", (1, 1), 2, -2, 2, 1, False, "uint16", [[1, 1], [65535, 1], [0, 2], [65535, 1], [1, 3]]),
    ("rebin-4-summed", (2, 1), 8, 0, 1, 4, True, "uint16", [[0, 1], [3, 2], [4, 3], [7, 4], [65535, 1], [5, 5]]),
    ("marker-only", (1, 2), 2, 0, 2, 1, True, "uint16", [[65535, 5]]),
    ("empty-stream", (1, 2), 2, 0, 1, 1, True, "uint16", []),
]


def kernel_pins(np):
    import rsciio.utils._fei_stream_readers as sr
    out = []
    for name, grid, channels, first, last, rebin, summed, dtype, runs in KERNEL:
        stream = np.concatenate([np.full(n, v, dtype=np.uint16) for v, n in runs]) if runs else np.zeros(0, dtype=np.uint16)
        a = sr.stream_to_array(stream=stream, spatial_shape=grid, channels=channels, last_frame=last, first_frame=first,
                               rebin_energy=rebin, sum_frames=summed, dtype=dtype)
        out.append({"name": name, "ny": grid[0], "nx": grid[1], "channels": channels, "first_frame": first,
                    "last_frame": last, "rebin_energy": rebin, "sum_frames": summed, "dtype": dtype, "runs": runs,
                    "shape": list(a.shape), "data_sha256": sha(step1.le_bytes(a))})
    return out

# ------------------------------------------------------------------------------------------------- build

def require_stream_libraries():
    import rsciio
    rel = "utils/_fei_stream_readers.py"
    if (Path(rsciio.__file__).parent / rel).read_bytes() != (step1.CLONE / "rsciio" / rel).read_bytes():
        die(f"installed rsciio/{rel} differs from the pinned clone's")
    for name in ("sparse", "numba"):
        if importlib.util.find_spec(name) is None:
            die(f"{name} is not installed in the venv")
    import numba
    import sparse
    return {"numba": numba.__version__, "sparse": sparse.__version__}


def check_planted(name, made, np):
    def for_options(key, opts):
        def check(arrays):
            if name in truth.DEVIATIONS and truth.DEVIATIONS[name][0] == "all":
                pass   # RosettaSciIO's own reading is still checked against the planted counts below
            want = truth.expected(made, name, opts)
            if len(want) != len(arrays):
                die(f"{name} {key}: RosettaSciIO returned {len(arrays)} signals, the planted truth {len(want)}")
            for i, (w, g) in enumerate(zip(want, arrays)):
                g = np.asarray(g)
                if w.dtype != g.dtype or w.shape != g.shape or step1.le_bytes(w) != step1.le_bytes(g):
                    die(f"{name} {key} signal {i}: RosettaSciIO {g.dtype}{g.shape} differs from the planted truth {w.dtype}{w.shape}")
        return check
    return for_options


def build(R, np, h5py, pint, work, made):
    files = []
    for path, label in public_files(work, h5py):
        files.append(file_record(R, np, path, label, "public", option_sets_for(path, h5py)))
    for name in sorted(made):
        pl, _ = made[name]
        path = PLANTED / name
        files.append(file_record(R, np, path, name, "planted", option_sets_for(path, h5py, pl), check_planted(name, made, np)))
    for case in truth.SK_CASES:
        name = f"spectrokit/velox-stream-{case}.emd"
        path = PLANTED / name
        files.append(file_record(R, np, path, name, "spectrokit-copy", {"O1": {}}))
    out = step1.header(np, h5py, pint, "step-4")
    out["generator"] = "tools/velox-spectrum-image/pins.py"
    out["reference"] = f"RosettaSciIO {step1.PIN} (rsciio.emd.file_reader, select_type='spectrum_image', lazy=False)"
    out["versions"].update(require_stream_libraries())
    out["option_sets"] = {k: v for k, v in truth.OPTIONS.items() if v is not None}
    out["deviations"] = {k: list(v) for k, v in truth.DEVIATIONS.items()}
    out["files"] = files
    out["kernel"] = kernel_pins(np)
    return step1.dump(out)


def regenerate_planted():
    """make_velox_si.py into a scratch directory; the committed files must be byte-equal (the truth is the generator's)."""
    scratch = Path(tempfile.mkdtemp(prefix="spectrum-image-planted-"))
    shutil.copytree(PLANTED / "spectrokit", scratch / "spectrokit")
    made = truth.build(str(scratch))
    for name in made:
        if (scratch / name).read_bytes() != (PLANTED / name).read_bytes():
            die(f"{name}: the committed planted file differs from make_velox_si.py's output (run it)")
    shutil.rmtree(scratch)
    return made


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=None)
    ap.add_argument("--owner", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--options", default="O1,O4,O11")
    a = ap.parse_args()
    import h5py
    import numpy as np
    import pint
    R = step1.load_rsciio()
    require_stream_libraries()
    if a.owner:
        if not a.out:
            die("--owner needs --out")
        sets = {"O1": {}, "O4": {"rebin_energy": 4}, "O11": {"first_frame": 100, "last_frame": 200}}
        sets.update({k: v for k, v in truth.OPTIONS.items() if v is not None})
        chosen = {k: sets[k] for k in a.options.split(",")}
        rec = file_record(R, np, Path(a.owner), os.path.basename(a.owner), "owner", chosen)
        out = step1.header(np, h5py, pint, "owner")
        out["versions"].update(require_stream_libraries())
        out["files"] = [rec]
        Path(a.out).write_text(step1.dump(out))
        print(f"owner pins: {len(chosen)} option sets -> {a.out}")
        return
    made = regenerate_planted()
    work = Path(a.work or tempfile.mkdtemp(prefix="spectrum-image-pins-"))
    first = build(R, np, h5py, pint, Path(tempfile.mkdtemp(prefix="a-", dir=work)), made)
    second = build(R, np, h5py, pint, Path(tempfile.mkdtemp(prefix="b-", dir=work)), made)
    if first != second:
        die("two builds differ")
    OUT.write_text(first)
    doc = json.loads(first)
    runs = [r for f in doc["files"] for r in f["runs"].values()]
    print(f"spectrum-image pins: {len(doc['files'])} files, {len(runs)} runs ({sum(1 for r in runs if r['raises'])} raise), "
          f"{sum(len(r['signals']) for r in runs)} signals, {len(doc['kernel'])} kernel cases; planted truth equal -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    sys.exit(main())

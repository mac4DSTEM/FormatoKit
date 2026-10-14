#!/usr/bin/env python3
"""Pins RosettaSciIO's readings for FormatoKit step 1 (docs/registration-step-1.md, sections 2, 3.1-3.3 and 4).

    References/rsciio-venv/bin/python -I -B tools/step-1/pins.py [--work DIR]
        writes Tests/FormatoCoreTests/Fixtures/step-1-pins.json   (the public DM and Velox files of the pinned clone)
               Tests/FormatoCoreTests/Fixtures/units-pins.json    (RosettaSciIO's own unit functions, called, not retyped)
    References/rsciio-venv/bin/python -I -B tools/step-1/pins.py --owner FILE [FILE ...] --out PATH [--work DIR]
        writes the same per-file records for files given on the command line to PATH (scratch, never committed; the path
        of each file is recorded as its basename only)

The script stops unless `rsciio.__file__` is inside References/rsciio-venv, the clone's HEAD is the pin, and the installed
`rsciio` sources used here are byte-equal to the clone's. Outputs are byte-reproducible (sorted keys, indent 1, no times,
no absolute paths); every build runs twice in the process and the script stops if the two outputs differ.
Public files are checked against the clone's `rsciio/tests/registry.txt`; zips are unzipped (member by member, names
checked) into a fresh empty directory made under --work (default: the system temp dir), never into the clone.
See tools/step-1/README.md for the fields.
"""
import argparse
import hashlib
import json
import math
import os
import struct
import sys
import tempfile
import warnings
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLONE = ROOT / "References" / "rosettasciio-049e7d70"
VENV = ROOT / "References" / "rsciio-venv"
PIN = "049e7d7070e84779b499adaf3295beee9facb004"
FIXTURES = ROOT / "Tests" / "FormatoCoreTests" / "Fixtures"
DATA = CLONE / "rsciio" / "tests" / "data"
ZIPS = ("fei_emd_files.zip", "velox_EELS_EDS.zip", "velox_emd_v11_elementSelection.zip", "velox_emd_version11.zip")
SEED = 20261015
BEAM_TARGETS = ("Acquisition_instrument.TEM.beam_energy", "Acquisition_instrument.SEM.beam_energy")
MAX_UNZIPPED = 1 << 30   # refuse a zip that would unpack to more than 1 GiB


def die(msg):
    sys.exit("pins.py: " + msg)


def head_of_clone():
    git = CLONE / ".git"
    if git.is_file():       # worktree/submodule pointer: not expected
        die("the clone's .git is a file")
    head = (git / "HEAD").read_text().strip()
    if head.startswith("ref: "):
        ref = git / head[5:]
        if ref.exists():
            return ref.read_text().strip()
        for line in (git / "packed-refs").read_text().splitlines():
            if line.endswith(" " + head[5:]):
                return line.split()[0]
        die("cannot resolve " + head)
    return head


def load_rsciio():
    import rsciio
    where = Path(rsciio.__file__).resolve()
    if VENV.resolve() not in where.parents:
        die(f"rsciio imported from {where}, not from {VENV}")
    head = head_of_clone()
    if head != PIN:
        die(f"the clone's HEAD is {head}, not the pin {PIN}")
    for rel in ("digitalmicrograph/_api.py", "emd/_emd_velox.py", "emd/_api.py", "utils/_units.py", "utils/hdf5.py"):
        a = (where.parent / rel).read_bytes()
        b = (CLONE / "rsciio" / rel).read_bytes()
        if a != b:
            die(f"installed rsciio/{rel} differs from the pinned clone's")
    import rsciio.digitalmicrograph as dm_mod
    import rsciio.emd as emd_mod
    import rsciio.emd._emd_velox as velox_mod
    import rsciio.utils._units as units_mod
    from rsciio.digitalmicrograph._api import DigitalMicrographReader
    return {"dm": dm_mod, "emd": emd_mod, "velox": velox_mod, "units": units_mod, "DMReader": DigitalMicrographReader}


# ---------------------------------------------------------------------------------------------------------------- helpers

def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def bits(x):
    return struct.pack(">d", float(x)).hex()


def jfloat(x):
    """A float for JSON: the value itself, or null when it is not finite (the bits carry it)."""
    x = float(x)
    return x if math.isfinite(x) else None


def registry():
    reg = {}
    for line in (CLONE / "rsciio" / "tests" / "registry.txt").read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        name, digest = line.rsplit(" ", 1)
        reg[name.strip("'")] = digest
    return reg


def dtype_name(dt):
    return str(dt) if dt.names is not None else dt.name


def le_bytes(data):
    import numpy as np
    arr = np.ascontiguousarray(data)
    return arr.astype(arr.dtype.newbyteorder("<")).tobytes()


def lookup(tree, dotted):
    node = tree
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def apply_mapping(signal, targets):
    """rsciio's returned `mapping` applied to the original_metadata the way HyperSpy does: for each entry whose source path
    holds a value, the value (through the function, if any) is stored at the target. Returns {target: (value, source)}."""
    out = {}
    for source, (target, func) in signal["mapping"].items():
        if target not in targets:
            continue
        value = lookup(signal["original_metadata"], source)
        if value is None:
            continue
        out[target] = (func(value) if func else value, source)
    return out


def md_entry(key, value, source=None):
    if isinstance(value, bool):
        raise ValueError(f"{key}: unexpected bool")
    if isinstance(value, (int, float)) or hasattr(value, "dtype"):
        e = {"key": key, "kind": "number", "value": jfloat(value), "value_bits": bits(value)}
    elif isinstance(value, str):
        e = {"key": key, "kind": "string", "value": value}
    else:
        raise ValueError(f"{key}: unexpected value type {type(value).__name__}")
    if source is not None:
        e["source"] = source
    return e


def axes_records(axes, data):
    out = []
    for i, a in enumerate(axes):
        if a["index_in_array"] != i:
            raise AssertionError(f"axis {i} has index_in_array {a['index_in_array']}")
        out.append({
            "name": a["name"],
            "size": int(a["size"]),
            "scale": jfloat(a["scale"]), "scale_bits": bits(a["scale"]),
            "offset": jfloat(a["offset"]), "offset_bits": bits(a["offset"]),
            "units": a["units"],
            "navigate": bool(a["navigate"]),
        })
    if len(axes) != data.ndim:
        raise AssertionError(f"{len(axes)} axes for rank {data.ndim}")
    return out


def exception_record(e, path, work):
    msg = str(e)
    for p in {str(path), str(Path(path).parent), str(work), str(ROOT)}:
        if p and p != "/":
            msg = msg.replace(p, "<path>")
    if "/Users/" in msg or "/private/" in msg or "/var/" in msg:
        raise AssertionError("absolute path left in exception message: " + msg)
    return {"type": type(e).__name__, "message": msg}


def f32_exact(data):
    import numpy as np
    kind = data.dtype.kind
    if kind == "c":
        return None
    f32 = data.astype("<f4")
    if kind in "iu":
        if data.dtype.itemsize <= 4:
            return bool(np.array_equal(f32.astype(np.float64), data.astype(np.float64)))
        return all(int(np.float32(v)) == int(v) for v in np.unique(data))
    if kind == "b":
        return True
    with np.errstate(all="ignore"):
        back = np.ascontiguousarray(f32.astype(data.dtype))
    return back.tobytes() == np.ascontiguousarray(data).tobytes()


# ---------------------------------------------------------------------------------------------------------------- DM

def dm_file(path, label, set_name, R, np):
    raw = Path(path).read_bytes()
    rec = {"set": set_name, "path": label, "format": "dm", "sha256": sha256_bytes(raw), "bytes": len(raw),
           "raises": None, "signals": []}
    try:
        signals = R["dm"].file_reader(str(path), lazy=False)
    except Exception as e:
        rec["raises"] = exception_record(e, path, Path(path).parent)
        return rec
    with open(path, "rb") as f:
        dm = R["DMReader"](f)
        dm.parse_file()
        thumbs = [t["ImageIndex"] for t in dm.tags_dict["Thumbnails"].values()] if "Thumbnails" in dm.tags_dict else []
        groups = [k for k in dm.tags_dict["ImageList"] if int(k.replace("TagGroup", "")) not in thumbs]
        blocks = {k: dm.tags_dict["ImageList"][k]["ImageData"]["Data"] for k in groups}
    if len(signals) != len(groups):
        raise AssertionError(f"{label}: rsciio returned {len(signals)} signals for {len(groups)} image groups")
    for key, sig in zip(groups, signals):
        data = np.asarray(sig["data"])
        md = sig["metadata"]
        block = blocks[key]
        s = {
            "dm_index": int(key.replace("TagGroup", "")) + 1,
            "title": md["General"]["title"],
            "signal_type": md["Signal"]["signal_type"],
            "dtype": dtype_name(data.dtype),
            "dtype_str": data.dtype.str if data.dtype.names is None else None,
            "shape": list(data.shape),
            "data_sha256": sha256_bytes(le_bytes(data)),
            "axes": axes_records(sig["axes"], data),
            "axes_sizes_match_shape": [int(a["size"]) for a in sig["axes"]] == list(data.shape),
        }
        off, size = block.get("offset"), block.get("size_bytes")
        s["data_offset"], s["data_size"] = (int(off), int(size)) if off is not None and size is not None else (None, None)
        s["data_bytes_equal_file"] = (bool(raw[off:off + size] == le_bytes(data)) if s["data_offset"] is not None else None)
        mdl = [md_entry("General.title", md["General"]["title"]),
               md_entry("General.original_filename", md["General"]["original_filename"]),
               md_entry("Signal.signal_type", md["Signal"]["signal_type"])]
        got = apply_mapping(sig, BEAM_TARGETS)
        for t in BEAM_TARGETS:
            if t in got:
                mdl.append(md_entry(t, got[t][0], got[t][1]))
        s["metadata"] = mdl
        rec["signals"].append(s)
    return rec


# ---------------------------------------------------------------------------------------------------------------- Velox

class sparse_stub:
    """The venv has no `sparse` (an optional dependency, for the EDS spectrum stream). rsciio's `_read_data` reads the images of
    a SpectrumStream file first and only then raises ModuleNotFoundError before `_read_spectrum_stream()`, so with the
    library absent `file_reader` raises on every such file even for select_type="images". Inside this block the single
    `find_spec("sparse")` check reports 'present' and `_read_spectrum_stream` does nothing; the image path runs unchanged.
    A no-op when `sparse` is importable."""
    def __init__(self, R):
        self.R = R

    def __enter__(self):
        import importlib.util as iu
        self.iu, self.orig_find = iu, iu.find_spec
        self.active = self.orig_find("sparse") is None
        if self.active:
            orig, Reader = self.orig_find, self.R["velox"].FeiEMDReader
            self.orig_stream = Reader.__dict__["_read_spectrum_stream"]
            iu.find_spec = lambda name, *a, **k: object() if name == "sparse" else orig(name, *a, **k)
            Reader._read_spectrum_stream = lambda slf: None
        return self

    def __exit__(self, *a):
        if self.active:
            self.iu.find_spec = self.orig_find
            self.R["velox"].FeiEMDReader._read_spectrum_stream = self.orig_stream


def _sparse_missing():
    import importlib.util as iu
    return iu.find_spec("sparse") is None


def has_spectrum_stream(path, h5py):
    with h5py.File(path, "r") as f:
        d = f.get("Data")
        return d is not None and "Image" in d and "SpectrumImage" in d

def is_velox(path, h5py, json_):
    with h5py.File(path, "r") as f:
        if "Version" not in list(f.keys()):
            return None
        v = json_.loads(f.get("Version")[0].decode("utf-8"))
        return v.get("format")


def velox_ids(path, h5py):
    ids = []
    with h5py.File(path, "r") as f:
        grp = f.get("Data")
        grp = grp.get("Image") if grp is not None else None
        if grp is None:
            return ids
        for gid in grp:
            g = grp[gid]
            d, m = g.get("Data"), g.get("Metadata")
            if isinstance(d, h5py.Dataset) and isinstance(m, h5py.Dataset) and len(d.shape) == 3:
                ids.append(gid)
    return ids


def velox_file(path, label, set_name, R, np, h5py, recorder=None):
    raw = Path(path).read_bytes()
    rec = {"set": set_name, "path": label, "format": "velox", "sha256": sha256_bytes(raw), "bytes": len(raw),
           "raises": None, "signals": []}
    try:
        with sparse_stub(R):
            signals = R["emd"].file_reader(str(path), lazy=False, select_type="images")
    except Exception as e:
        rec["raises"] = exception_record(e, path, Path(path).parent)
        return rec
    rec["spectrum_stream_not_read"] = bool(has_spectrum_stream(path, h5py)) and _sparse_missing()
    ids = velox_ids(path, h5py)
    if len(ids) != len(signals):
        raise AssertionError(f"{label}: rsciio returned {len(signals)} image signals, h5py lists {len(ids)} ({ids})")
    for gid, sig in zip(ids, signals):
        data = np.asarray(sig["data"])
        md = sig["metadata"]
        s = {
            "velox_image_id": gid,
            "title": md.get("General", {}).get("title"),
            "signal_type": md.get("Signal", {}).get("signal_type"),
            "dtype": dtype_name(data.dtype),
            "dtype_str": data.dtype.str if data.dtype.names is None else None,
            "shape": list(data.shape),
            "data_sha256": sha256_bytes(le_bytes(data)),
            "axes": axes_records(sig["axes"], data),
            "axes_sizes_match_shape": [int(a["size"]) for a in sig["axes"]] == list(data.shape),
        }
        if data.dtype.kind == "c":
            s["data_f32_sha256"], s["float32_exact"] = None, None
        else:
            s["data_f32_sha256"] = sha256_bytes(np.ascontiguousarray(data).astype("<f4").tobytes())
            s["float32_exact"] = f32_exact(data)
        mdl = []
        if "title" in md.get("General", {}):
            mdl.append(md_entry("General.title", md["General"]["title"]))
        mdl.append(md_entry("General.original_filename", md["General"]["original_filename"]))
        got = apply_mapping(sig, BEAM_TARGETS)
        for t in BEAM_TARGETS:
            if t in got:
                mdl.append(md_entry(t, got[t][0], got[t][1]))
        s["metadata"] = mdl
        rec["signals"].append(s)
    return rec


# ---------------------------------------------------------------------------------------------------------------- the file sets

def unzip_member_names(zpath):
    with zipfile.ZipFile(zpath) as z:
        total = sum(i.file_size for i in z.infolist())
        if total > MAX_UNZIPPED:
            die(f"{zpath.name} would unpack to {total} bytes")
        names = []
        for i in z.infolist():
            n = i.filename
            if i.is_dir():
                continue
            if n.startswith("/") or ".." in Path(n).parts or "\\" in n:
                die(f"{zpath.name}: unsafe member name {n!r}")
            names.append(n)
        return names


def unzip_all(work):
    """Unzip each registry-checked zip into its own fresh directory; returns {zip name: (dir, [member names])}."""
    reg = registry()
    out = {}
    for zname in ZIPS:
        zpath = DATA / "emd" / zname
        got = sha256_file(zpath)
        if got != reg["emd/" + zname]:
            die(f"{zname} sha256 {got} is not the registry value")
        d = Path(tempfile.mkdtemp(prefix=zname.replace(".zip", "") + "-", dir=work))
        if any(d.iterdir()):
            die(f"{d} is not empty")
        names = unzip_member_names(zpath)
        with zipfile.ZipFile(zpath) as z:
            for n in names:
                target = d / n
                target.parent.mkdir(parents=True, exist_ok=True)
                with z.open(n) as src, open(target, "wb") as dst:
                    dst.write(src.read())
        out[zname] = (d, names)
    return out


def public_plan(unzipped):
    """[(abs path, label, format-guess)] in a fixed order; velox-ness of .emd is decided later by the Version dataset."""
    reg = registry()
    plan = []
    dm_root = DATA / "digitalmicrograph"
    for p in sorted(dm_root.rglob("*")):
        if p.suffix.lower() in (".dm3", ".dm4"):
            rel = p.relative_to(DATA).as_posix()
            got = sha256_file(p)
            if got != reg.get(rel):
                die(f"{rel} sha256 {got} is not the registry value {reg.get(rel)}")
            plan.append((p, rel, "dm"))
    for p in sorted((DATA / "emd").glob("*.emd")):
        rel = p.relative_to(DATA).as_posix()
        got = sha256_file(p)
        if got != reg.get(rel):
            die(f"{rel} sha256 {got} is not the registry value {reg.get(rel)}")
        plan.append((p, rel, "emd"))
    for zname in ZIPS:
        d, names = unzipped[zname]
        for n in sorted(names):
            if n.lower().endswith(".emd"):
                plan.append((d / n, f"emd/{zname}/{n}", "emd"))
    return plan


def header(np, h5py, pint, set_name):
    import sys as _s
    return {
        "generator": "tools/step-1/pins.py",
        "reference": f"RosettaSciIO {PIN} (rsciio.digitalmicrograph.file_reader; rsciio.emd.file_reader, select_type='images')",
        "versions": {"python": _s.version.split()[0], "numpy": np.__version__, "h5py": h5py.__version__, "pint": pint.__version__},
        "set": set_name,
    }


def build_files(plan, R, np, h5py, set_name):
    import json as json_
    files, skipped = [], []
    for path, label, kind in plan:
        if kind == "dm":
            files.append(dm_file(path, label, set_name, R, np))
            continue
        fmt = is_velox(path, h5py, json_)
        if fmt != "Velox":
            skipped.append({"path": label, "version_format": fmt})
            continue
        files.append(velox_file(path, label, set_name, R, np, h5py))
    return files, skipped


def dump(obj):
    return json.dumps(obj, indent=1, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"


def dump_records(obj):
    """The units pins: one record per line (17 000 records; indent 1 made the file 4 MB)."""
    head = {k: v for k, v in obj.items() if k != "records"}
    lines = [json.dumps(r, sort_keys=True, ensure_ascii=False, allow_nan=False, separators=(",", ":")) for r in obj["records"]]
    text = json.dumps(head, sort_keys=True, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
    return text[:-1] + ',"records":[\n' + ",\n".join(lines) + "\n]}\n"


# ---------------------------------------------------------------------------------------------------------------- units

class _Recorder:
    """Records the arguments the Velox image path hands to the two unit functions (the real functions still run)."""
    def __init__(self, R):
        self.R = R
        self.scale_calls, self.conv_calls = [], []

    def __enter__(self):
        Reader = self.R["velox"].FeiEMDReader
        self.Reader, self.orig_scale = Reader, Reader.__dict__["_convert_scale_units"]
        self.orig_conv = self.R["velox"].convert_units
        rec = self

        def scale(slf, value, units, factor=1):
            rec.scale_calls.append((value, units, factor))
            return rec.orig_scale(slf, value, units, factor)

        def conv(value, units, to_units):
            rec.conv_calls.append((value, units, to_units))
            return rec.orig_conv(value, units, to_units)

        Reader._convert_scale_units = scale
        self.R["velox"].convert_units = conv
        return self

    def __exit__(self, *a):
        self.Reader._convert_scale_units = self.orig_scale
        self.R["velox"].convert_units = self.orig_conv


def public_unit_calls(velox_paths, R):
    with _Recorder(R) as rec, sparse_stub(R):
        for p in velox_paths:
            R["emd"].file_reader(str(p), lazy=False, select_type="images")
    return rec.scale_calls, rec.conv_calls


def scale_record(R, value, units, factor, case, raw_text=None):
    slf = object()
    fn = R["velox"].FeiEMDReader._convert_scale_units
    rec = {"fn": "convert_scale_units", "case": case, "value_bits": bits(value), "value": jfloat(value), "units": units,
           "factor": factor}
    if raw_text is not None:
        rec["value_text"] = raw_text
    try:
        out, out_units = fn(slf, value, units, factor)
        rec.update({"out_bits": bits(out), "out": jfloat(out), "out_units": out_units})
    except Exception as e:
        rec["raises"] = {"type": type(e).__name__, "message": str(e)}
    return rec


def conv_record(R, value, units, to_units, case, raw_text=None):
    rec = {"fn": "convert_units", "case": case, "value_bits": bits(value), "value": jfloat(value), "units": units,
           "to_units": to_units}
    if raw_text is not None:
        rec["value_text"] = raw_text
    try:
        out = R["units"].convert_units(value, units, to_units)
        rec.update({"out_bits": bits(out), "out": jfloat(out), "out_units": to_units})
    except Exception as e:
        rec["raises"] = {"type": type(e).__name__, "message": str(e)}
    return rec


def build_units(velox_paths, R, np, pint):
    records = []
    seen = set()

    def add(r):
        k = json.dumps({x: r.get(x) for x in ("fn", "value_bits", "units", "factor", "to_units")}, sort_keys=True)
        if k in seen:
            return
        seen.add(k)
        records.append(r)

    # (a) what the public Velox image path calls
    scale_calls, conv_calls = public_unit_calls(velox_paths, R)
    for value, units, factor in scale_calls:
        raw = value if isinstance(value, str) else None
        v = value if units is None else value   # the function takes float(value) itself; pass what rsciio passed
        try:
            fv = float(v)
        except Exception:
            fv = None
        rec_value = fv if fv is not None else float("nan")
        r = scale_record(R, v, units, factor, "public-velox", raw)
        r["value_bits"], r["value"] = bits(rec_value), jfloat(rec_value)
        add(r)
    for value, units, to_units in conv_calls:
        add(conv_record(R, value, units, to_units, "public-velox"))
    # (b) the seeded sweep
    rng = np.random.default_rng(SEED)
    vals_m = 10.0 ** rng.uniform(-13.0, 4.0, 400)
    fac_m = rng.integers(1, 8193, 400)
    vals_s = 10.0 ** rng.uniform(-13.0, 4.0, 200)
    fac_s = rng.integers(1, 8193, 200)
    for v, f in zip(vals_m, fac_m):
        add(scale_record(R, float(v), "m", int(f), "sweep"))
    for v, f in zip(vals_s, fac_s):
        add(scale_record(R, float(v), "s", int(f), "sweep"))
    for v in vals_m:
        for to in ("m", "mm", "µm", "nm", "pm"):
            add(conv_record(R, float(v), "m", to, "sweep"))
    for v in vals_s:
        for to in ("s", "ms", "µs", "ns"):
            add(conv_record(R, float(v), "s", to, "sweep"))
    # (c) the planted cases of registration section 4
    planted_scale = [(1.5e-9, "m", 100), (2.5e-7, "m", 1000), (0.5, "s", 2 * 20), (0.0, "m", 100), (float("nan"), "m", 100),
                     (3.0, "", 10), (2.0, "1/nm", 10), (1.5e-9, None, 100), (0.0, "m", 1), (1.0, "m", 1), (1.0, "s", 2)]
    for v, u, f in planted_scale:
        add(scale_record(R, v, u, f, "planted"))
    planted_conv = [(1.5e-9, "m", "nm"), (2.5e-7, "m", "µm"), (0.0, "m", "nm"), (float("nan"), "m", "nm"),
                    (0.5, "s", "ms"), (2.0, "1/nm", "1/nm"), (3.0, "", ""), (-1.5e-9, "m", "nm"), (-0.0, "m", "nm")]
    for v, u, to in planted_conv:
        add(conv_record(R, v, u, to, "planted"))
    return {
        "generator": "tools/step-1/pins.py",
        "reference": f"RosettaSciIO {PIN}: rsciio.emd._emd_velox.FeiEMDReader._convert_scale_units, rsciio.utils._units.convert_units",
        "versions": {"python": sys.version.split()[0], "numpy": np.__version__, "pint": pint.__version__},
        "sweep": {"seed": SEED, "rng": "numpy.random.default_rng(seed)",
                  "draw order": "10**uniform(-13,4,400); integers(1,8193,400); 10**uniform(-13,4,200); integers(1,8193,200)"},
        "records": records,
    }


# ---------------------------------------------------------------------------------------------------------------- main

def run_default(work):
    import h5py
    import numpy as np
    import pint
    R = load_rsciio()
    unzipped = unzip_all(work)
    plan = public_plan(unzipped)
    files, skipped = build_files(plan, R, np, h5py, "public")
    out = header(np, h5py, pint, "public")
    out["files"] = files
    out["skipped_non_velox_emd"] = skipped
    velox_paths = [p for p, label, k in plan if k == "emd" and label in {f["path"] for f in files if f["format"] == "velox"}]
    units = build_units(velox_paths, R, np, pint)
    return dump(out), dump_records(units), files, skipped


def run_owner(paths, work):
    import h5py
    import json as json_
    import numpy as np
    import pint
    R = load_rsciio()
    files, skipped = [], []
    for p in paths:
        p = Path(p)
        if p.suffix.lower() in (".dm3", ".dm4"):
            kind = "dm"
        elif p.suffix.lower() == ".emd":
            kind = "emd"
        else:
            skipped.append({"path": p.name, "reason": "extension"})
            continue
        try:
            if kind == "dm":
                files.append(dm_file(p, p.name, "owner", R, np))
            else:
                fmt = is_velox(p, h5py, json_)
                if fmt != "Velox":
                    skipped.append({"path": p.name, "version_format": fmt})
                    continue
                files.append(velox_file(p, p.name, "owner", R, np, h5py))
        except AssertionError as e:
            files.append({"set": "owner", "path": p.name, "format": "dm" if kind == "dm" else "velox",
                          "sha256": sha256_file(p), "bytes": p.stat().st_size, "raises": None, "signals": [],
                          "oracle_check_failed": str(e).replace(str(p), p.name)})
    out = header(np, h5py, pint, "owner")
    out["files"] = files
    out["skipped"] = skipped
    return dump(out), files, skipped


def summarize(files):
    n = {"dm": [0, 0, 0], "velox": [0, 0, 0]}
    dtypes = set()
    for f in files:
        c = n[f["format"]]
        c[0] += 1
        c[1] += len(f["signals"])
        c[2] += 1 if f["raises"] else 0
        for s in f["signals"]:
            dtypes.add(s["dtype"])
    return n, sorted(dtypes)


def main():
    warnings.simplefilter("ignore")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--owner", nargs="+", metavar="FILE")
    ap.add_argument("--out", metavar="PATH")
    ap.add_argument("--work", metavar="DIR", help="existing directory for the unzipped public zips (default: system temp)")
    a = ap.parse_args()
    if bool(a.owner) != bool(a.out):
        die("--owner and --out go together")
    work = Path(a.work) if a.work else Path(tempfile.gettempdir())
    if not work.is_dir():
        die(f"--work {work} is not a directory")
    if a.owner:
        first = run_owner(a.owner, work)
        second = run_owner(a.owner, work)
        if first[0] != second[0]:
            die("two readings differ: not byte-reproducible")
        Path(a.out).write_text(first[0], encoding="utf-8")
        n, dtypes = summarize(first[1])
        print(f"{a.out}: {len(first[0].encode())} bytes; files {n}; skipped {len(first[2])}; dtypes {dtypes}")
        return
    first = run_default(work)
    second = run_default(work)
    if first[0] != second[0] or first[1] != second[1]:
        die("two builds differ: not byte-reproducible")
    FIXTURES.mkdir(parents=True, exist_ok=True)
    for name, text in (("step-1-pins.json", first[0]), ("units-pins.json", first[1])):
        (FIXTURES / name).write_text(text, encoding="utf-8")
        print(f"{name}: {len(text.encode('utf-8'))} bytes, sha256 {sha256_bytes(text.encode('utf-8'))}")
    n, dtypes = summarize(first[2])
    print("files/signals/raises  dm:", n["dm"], " velox:", n["velox"])
    print("dtypes:", dtypes)
    print("skipped non-Velox emd:", len(first[3]))


if __name__ == "__main__":
    main()

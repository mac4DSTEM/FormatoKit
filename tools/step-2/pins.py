#!/usr/bin/env python3
"""Pins RosettaSciIO's and tifffile's readings of TIFF files for FormatoKit step 2.

    References/rsciio-venv/bin/python -I -B tools/step-2/pins.py [--work DIR]
        writes Tests/FormatoTIFFTests/Fixtures/step-2-pins.json   (every TIFF of the pinned clone's tests/data/tiff, and the
                                                                   planted files of Fixtures/planted/, run make_planted.py first)
    References/rsciio-venv/bin/python -I -B tools/step-2/pins.py --owner FILE [FILE ...] --out PATH [--work DIR]
        writes the same per-file records for the files named on the command line to PATH (scratch, never committed; the path of
        each file is recorded as its basename only, "set" is "owner")

The script stops unless `rsciio.__file__` and `tifffile.__file__` are inside References/rsciio-venv, the clone's HEAD is the pin,
tifffile is 2026.9.20 and NumPy 2.5.4, python-dateutil is importable, and the installed `rsciio/tiff/_api.py` and
`rsciio/utils/rgb.py` equal the clone's, byte for byte. Public files are checked against `rsciio/tests/registry.txt`
(loose files, `.gz` files and zips; a zip member is checked through its zip). Zips and gz files are unpacked (member by member,
names checked, sizes bounded) into a fresh empty directory made under --work (default: the system temp dir), never into the clone.
Everything is built twice in the process and the script stops if the two outputs differ. Output: sorted keys, indent 1, UTF-8,
no times, no absolute paths, non-finite numbers as null (the *_bits fields carry them).
See tools/step-2/README.md for the fields.
"""
import argparse
import gzip
import hashlib
import json
import logging
import math
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
TIFFFILE_VERSION = "2026.9.20"
NUMPY_VERSION = "2.5.4"
FIXTURES = ROOT / "Tests" / "FormatoTIFFTests" / "Fixtures"
PLANTED = FIXTURES / "planted"
DATA = CLONE / "rsciio" / "tests" / "data"
TIFF_DIR = DATA / "tiff"
MAX_UNPACKED = 1 << 30   # refuse a zip or gz that would unpack to more than 1 GiB

# TIFF datatype -> bytes per item
TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4, 16: 8, 17: 8, 18: 8}
# the reasons a file is out of step 2's scope, in the order the first one is reported
FILE_FLAG_REASONS = (("sem", "flag:sem"), ("tvips", "flag:tvips"), ("sis", "flag:sis"), ("streak", "flag:streak"))
METADATA_KEYS = ("General.original_filename", "General.date", "General.time", "Signal.signal_type", "Signal.quantity",
                 "Signal.Noise_properties.Variance_linear_model.gain_factor",
                 "Signal.Noise_properties.Variance_linear_model.gain_offset")


def die(msg):
    sys.exit("pins.py: " + msg)


def head_of_clone():
    git = CLONE / ".git"
    if git.is_file():
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


def load_oracle():
    """Checks the versions and the install; returns {'tiff': rsciio.tiff, 'tifffile': tifffile, 'np': numpy}."""
    import numpy as np
    if np.__version__ != NUMPY_VERSION:
        die(f"NumPy {np.__version__}, not {NUMPY_VERSION}")
    import tifffile
    if tifffile.__version__ != TIFFFILE_VERSION:
        die(f"tifffile {tifffile.__version__}, not {TIFFFILE_VERSION}")
    if VENV.resolve() not in Path(tifffile.__file__).resolve().parents:
        die(f"tifffile imported from {tifffile.__file__}, not from {VENV}")
    import dateutil   # noqa: F401  (rsciio's FEI mapping uses dateutil.parser)
    import rsciio
    where = Path(rsciio.__file__).resolve()
    if VENV.resolve() not in where.parents:
        die(f"rsciio imported from {where}, not from {VENV}")
    head = head_of_clone()
    if head != PIN:
        die(f"the clone's HEAD is {head}, not the pin {PIN}")
    for rel in ("tiff/_api.py", "utils/rgb.py", "utils/_date_time.py"):
        if (where.parent / rel).read_bytes() != (CLONE / "rsciio" / rel).read_bytes():
            die(f"installed rsciio/{rel} differs from the pinned clone's")
    import rsciio.tiff as tiff_mod
    return {"tiff": tiff_mod, "tifffile": tifffile, "np": np}


def versions(np):
    import dateutil
    import tifffile
    return {"python": sys.version.split()[0], "numpy": np.__version__, "tifffile": tifffile.__version__,
            "dateutil": dateutil.__version__}


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
    return str(dt.newbyteorder("<")) if dt.names is not None else dt.name


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


def exception_record(e, path, work):
    msg = str(e)
    for p in sorted({str(path), str(Path(path).parent), str(work), str(ROOT)}, key=len, reverse=True):
        if p and p != "/":
            msg = msg.replace(p, "<path>")
    if "/Users/" in msg or "/private/" in msg or "/var/" in msg:
        raise AssertionError("absolute path left in exception message: " + msg)
    return {"type": type(e).__name__, "message": msg}


class Unrepresentable(Exception):
    pass


def encode_value(v, np):
    """tifffile's decoded value -> (json value, bits). Ints (IntEnum members included), floats (with bits), strs, and
    tuples/lists of those (nested, bits in the same shape; null for non-floats). Raises Unrepresentable for the rest."""
    if isinstance(v, (bool, np.bool_)):
        raise Unrepresentable("bool")
    if isinstance(v, (int, np.integer)):
        return int(v), None
    if isinstance(v, (float, np.floating)):
        f = float(v)
        return jfloat(f), bits(f)
    if isinstance(v, str):
        return v, None
    if isinstance(v, (tuple, list)):
        parts = [encode_value(x, np) for x in v]
        return [p[0] for p in parts], [p[1] for p in parts]
    raise Unrepresentable(type(v).__name__)


def scalar_record(v, np):
    """{kind, value[, value_bits]} for the INI and ImageJ dictionaries: bool is its own kind here (astype tries asbool)."""
    if isinstance(v, (bool, np.bool_)):
        return {"kind": "bool", "value": bool(v)}
    if isinstance(v, (int, np.integer)):
        return {"kind": "int", "value": int(v)}
    if isinstance(v, (float, np.floating)):
        return {"kind": "float", "value": jfloat(v), "value_bits": bits(v)}
    if isinstance(v, str):
        return {"kind": "str", "value": v}
    return {"kind": "other", "type": type(v).__name__}


# ---------------------------------------------------------------------------------------------------------------- tags

def tag_records(page, raw, np):
    out = []
    for tag in page.tags.values():
        typ = int(tag.dtype)
        rec = {"code": int(tag.code), "name": tag.name, "type": typ, "count": int(tag.count)}
        size = TYPE_SIZE.get(typ)
        raw_sha = None
        if size is not None:
            start, n = int(tag.valueoffset), size * int(tag.count)
            if start < 0 or start + n > len(raw):
                raise AssertionError(f"tag {tag.code}: value bytes {start}+{n} outside the file")
            raw_sha = sha256_bytes(raw[start:start + n])
        rec["raw_sha256"] = raw_sha
        try:
            value = tag.value
        except Exception as e:   # a tag tifffile cannot decode
            rec.update({"value": None, "value_bits": None, "value_kind": "unreadable", "value_error": type(e).__name__})
            out.append(rec)
            continue
        try:
            v, b = encode_value(value, np)
            rec["value"], rec["value_bits"] = v, b
            rec["value_kind"] = ("list" if isinstance(v, list) else "float" if b is not None else "int" if isinstance(v, int) else "str")
        except Unrepresentable:
            rec["value"], rec["value_bits"], rec["value_kind"] = None, None, "none"
            rec["value_type"] = type(value).__name__   # what tifffile gave: bytes, dict, ndarray, ...
        out.append(rec)
    return out


# ---------------------------------------------------------------------------------------------------------------- scope

def scope_reasons(t, series_info, p0):
    """The reasons a file is outside step 2, in a fixed order."""
    reasons = []
    flags = set(t.flags)
    page_flags = set()
    for s in t.series:
        for pg in s.pages:
            page_flags |= set(getattr(pg, "keyframe", pg).flags)
    for flag, reason in FILE_FLAG_REASONS:
        if flag in flags or flag in page_flags:
            reasons.append(reason)
    make = p0.tags.valueof(271) if p0 is not None else None
    if make == "JEOL Ltd.":
        reasons.append("make:JEOL Ltd.")
    compressed = tiled = planar2 = False
    for s in t.series:
        for pg in s.pages:
            kf = getattr(pg, "keyframe", pg)
            if int(kf.compression) != 1:
                compressed = True
            if kf.is_tiled:
                tiled = True
            if int(kf.planarconfig) == 2:
                planar2 = True
    if compressed:
        reasons.append("compressed")
    if tiled:
        reasons.append("tiled")
    if planar2:
        reasons.append("planar-config-2")
    for si in series_info:
        ok = si["kind"] in ("imagej", "generic", "uniform") or (si["kind"] == "shaped" and si["pages"] == 1)
        if not ok:
            reasons.append("series-kind:" + si["kind"])
    return reasons


# ---------------------------------------------------------------------------------------------------------------- metadata

def md_entry(key, value, source=None):
    if isinstance(value, bool):
        e = {"key": key, "kind": "bool", "value": value}
    elif isinstance(value, (int, float)) or hasattr(value, "dtype"):
        e = {"key": key, "kind": "number", "value": jfloat(value), "value_bits": bits(value)}
    elif isinstance(value, str):
        e = {"key": key, "kind": "string", "value": value}
    else:
        e = {"key": key, "kind": "other", "value": repr(value)}
    e["source"] = source
    return e


def metadata_entries(d):
    """The metadata of one signal: the fixed keys from the returned `metadata` (present only when set), then every target of
    the returned `mapping` applied to `original_metadata` as HyperSpy does. A mapping target that equals a fixed key (General.date,
    General.time with FEI files) is listed again after it: the later entry is the one HyperSpy keeps."""
    md = d["metadata"]
    om = d["original_metadata"]
    out = []

    def get(dotted):
        return lookup(md, dotted)
    fixed_sources = {"General.date": "DateTime", "General.time": "DateTime", "Signal.quantity": "65022",
                     "Signal.Noise_properties.Variance_linear_model.gain_factor": "65025",
                     "Signal.Noise_properties.Variance_linear_model.gain_offset": "65024"}
    for key in METADATA_KEYS:
        v = get(key)
        if v is None:
            continue
        out.append(md_entry(key, v, fixed_sources.get(key)))
    for source, (target, func) in d["mapping"].items():
        value = lookup(om, source)
        if value is None:
            continue
        v = func(value) if func else value
        if v is None:
            continue
        out.append(md_entry(target, v, source))
    return out


def axes_records(axes, data):
    out = []
    for a in axes:
        scale = a.get("scale", 1.0)
        offset = a.get("offset", 0.0)
        out.append({
            "name": a.get("name"),
            "size": int(a["size"]) if a.get("size") is not None else None,
            "scale": jfloat(scale), "scale_bits": bits(scale),
            "offset": jfloat(offset), "offset_bits": bits(offset),
            "units": a.get("units"),
            "navigate": bool(a.get("navigate", False)),
        })
    if len(axes) != data.ndim:
        raise AssertionError(f"{len(axes)} axes for rank {data.ndim}")
    return out


def ordered_scalars(d, np):
    return [dict(key=k, **scalar_record(v, np)) for k, v in d.items()]


# ---------------------------------------------------------------------------------------------------------------- one file

def file_record(path, label, set_name, R, container=None):
    """The record of one TIFF file (fields in tools/step-2/README.md)."""
    np = R["np"]
    tifffile = R["tifffile"]
    path = Path(path)
    raw = path.read_bytes()
    rec = {"set": set_name, "path": label, "sha256": sha256_bytes(raw), "bytes": len(raw), "container": container,
           "bigtiff": None, "byteorder": None, "pages": None, "flags": [], "page0_flags": [],
           "in_scope": False, "out_of_scope": None, "out_of_scope_reasons": [], "raises": None, "tifffile_raises": None,
           "tags": [], "tifffile_series": [], "series": [], "fei_metadata": None, "imagej_metadata": None}
    series_info = []
    try:
        with tifffile.TiffFile(path) as t:
            rec["bigtiff"] = bool(t.is_bigtiff)
            rec["byteorder"] = t.byteorder
            rec["pages"] = len(t.pages)
            rec["flags"] = sorted(t.flags)
            p0 = t.pages.first
            rec["page0_flags"] = sorted(p0.flags)
            rec["tags"] = tag_records(p0, raw, np)
            for s in t.series:
                series_info.append({"axes": s.axes, "kind": s.kind, "shape": list(s.shape), "dtype": s.dtype.name,
                                    "pages": len(s.pages)})
            rec["tifffile_series"] = series_info
            if "fei" in t.flags:
                rec["fei_metadata"] = [{"section": sec, **item}
                                       for sec, body in t.fei_metadata.items()
                                       for item in ordered_scalars(body, np)]
            if "imagej" in t.flags:
                ij = t.imagej_metadata or {}
                rec["imagej_metadata"] = [dict(key=k, **scalar_record(v, np)) for k, v in ij.items()
                                          if not isinstance(v, (bytes, list, tuple, dict)) or isinstance(v, str)]
            reasons = scope_reasons(t, series_info, p0)
    except Exception as e:
        rec["tifffile_raises"] = exception_record(e, path, path.parent)
        reasons = ["tifffile-cannot-open"]
    rec["out_of_scope_reasons"] = reasons
    rec["out_of_scope"] = reasons[0] if reasons else None
    rec["in_scope"] = not reasons
    # RosettaSciIO
    try:
        signals = R["tiff"].file_reader(str(path), lazy=False)
    except Exception as e:
        rec["raises"] = exception_record(e, path, path.parent)
        return rec
    if rec["tifffile_raises"] is None and len(signals) != len(series_info):
        raise AssertionError(f"{label}: rsciio returned {len(signals)} signals for {len(series_info)} tifffile series")
    # HyperSpy applies the returned mapping when it builds the signal; a mapping function that raises (dateutil on a date
    # the calendar does not hold) makes the load raise: recorded as RosettaSciIO raising, where "mapping".
    for d in signals:
        try:
            metadata_entries(d)
        except Exception as e:
            rec["raises"] = dict(exception_record(e, path, path.parent), where="mapping")
            rec["series"] = []
            return rec
    for i, d in enumerate(signals):
        data = np.asarray(d["data"])
        info = series_info[i] if i < len(series_info) else {"axes": None, "kind": None}
        rec["series"].append({
            "tifffile_axes": info["axes"], "tifffile_kind": info["kind"],
            "dtype": dtype_name(data.dtype), "dtype_as_returned": str(data.dtype), "shape": list(data.shape),
            "data_sha256": sha256_bytes(le_bytes(data)),
            "axes": axes_records(d["axes"], data),
            "metadata": metadata_entries(d),
        })
    return rec


# ---------------------------------------------------------------------------------------------------------------- file sets

def safe_member(name, zname):
    if name.startswith("/") or ".." in Path(name).parts or "\\" in name:
        die(f"{zname}: unsafe member name {name!r}")


def public_plan(work):
    """[(abs path, label, container)]: loose files, gz files, zip members, each group sorted; and the non-TIFF names skipped.
    Every loose file, gz and zip is checked against registry.txt first and unpacked into a fresh directory under `work`."""
    reg = registry()
    plan, skipped = [], []

    def check(p):
        rel = p.relative_to(DATA).as_posix()
        got = sha256_file(p)
        if got != reg.get(rel):
            die(f"{rel} sha256 {got} is not the registry value {reg.get(rel)}")
        return rel, got

    def fresh(prefix):
        d = Path(tempfile.mkdtemp(prefix=prefix + "-", dir=work))
        if any(d.iterdir()):
            die(f"{d} is not empty")
        return d

    names = sorted(p for p in TIFF_DIR.iterdir() if p.is_file())
    for p in names:
        low = p.name.lower()
        if low.endswith((".tif", ".tiff")):
            rel, _ = check(p)
            plan.append((p, rel, None))
        elif low.endswith((".tif.gz", ".tiff.gz")):
            rel, digest = check(p)
            d = fresh(p.name.replace(".", "_"))
            target = d / p.name[:-3]
            n = 0
            with gzip.open(p, "rb") as src, open(target, "wb") as dst:
                for chunk in iter(lambda: src.read(1 << 20), b""):
                    n += len(chunk)
                    if n > MAX_UNPACKED:
                        die(f"{p.name} unpacks to more than {MAX_UNPACKED} bytes")
                    dst.write(chunk)
            plan.append((target, rel, {"kind": "gzip", "name": p.name, "sha256": digest}))
        elif low.endswith(".zip"):
            rel, digest = check(p)
            with zipfile.ZipFile(p) as z:
                infos = [i for i in z.infolist() if not i.is_dir()]
                if sum(i.file_size for i in infos) > MAX_UNPACKED:
                    die(f"{p.name} would unpack to more than {MAX_UNPACKED} bytes")
                d = fresh(p.name.replace(".", "_"))
                for i in sorted(infos, key=lambda i: i.filename):
                    safe_member(i.filename, p.name)
                    if not i.filename.lower().endswith((".tif", ".tiff")):
                        skipped.append({"path": f"tiff/{p.name}/{i.filename}", "reason": "not a TIFF by extension"})
                        continue
                    target = d / i.filename
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(i) as src, open(target, "wb") as dst:
                        dst.write(src.read())
                    plan.append((target, f"tiff/{p.name}/{i.filename}", {"kind": "zip", "name": p.name, "sha256": digest}))
        else:
            skipped.append({"path": p.relative_to(DATA).as_posix(), "reason": "not a TIFF by extension"})
    # order: loose files, then gz, then zip members, each by path
    rank = {None: 0, "gzip": 1, "zip": 2}
    plan.sort(key=lambda x: (rank[x[2]["kind"] if x[2] else None], x[1]))
    return plan, skipped


def planted_plan():
    truth_path = PLANTED / "planted-truth.json"
    if not truth_path.is_file():
        die(f"{truth_path} does not exist: run tools/step-2/make_planted.py first")
    truth = json.loads(truth_path.read_text(encoding="utf-8"))
    plan = []
    for f in truth["files"]:
        p = PLANTED / f["file"]
        if not p.is_file() or sha256_file(p) != f["sha256"]:
            die(f"{p} is missing or differs from planted-truth.json: run tools/step-2/make_planted.py")
        plan.append((p, "planted/" + f["file"], None))
    return plan


def dump(obj):
    return json.dumps(obj, indent=1, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"


def summarize(files):
    scope = {}
    kinds, axes_codes, dtypes = set(), set(), set()
    for f in files:
        key = f["out_of_scope"] or "in scope"
        scope[key] = scope.get(key, 0) + 1
        for s in f["series"]:
            dtypes.add(s["dtype"])
            if f["in_scope"]:
                kinds.add(s["tifffile_kind"])
                axes_codes.add(s["tifffile_axes"])
    return {"files": len(files), "series": sum(len(f["series"]) for f in files), "scope": scope,
            "dtypes": sorted(dtypes), "in_scope_kinds": sorted(kinds), "in_scope_axes": sorted(axes_codes),
            "raises": sorted(f["path"] for f in files if f["raises"])}


def build_default(work):
    R = load_oracle()
    plan, skipped = public_plan(work)
    files = [file_record(p, label, "public", R, container) for p, label, container in plan]
    files += [file_record(p, label, "planted", R, container) for p, label, container in planted_plan()]
    out = {"generator": "tools/step-2/pins.py",
           "reference": f"RosettaSciIO {PIN} (rsciio.tiff.file_reader, defaults); tifffile {TIFFFILE_VERSION}",
           "versions": versions(R["np"]), "files": files, "skipped_non_tiff": skipped}
    return dump(out), files


def build_owner(paths, work):
    R = load_oracle()
    files = [file_record(Path(p), Path(p).name, "owner", R) for p in paths]
    out = {"generator": "tools/step-2/pins.py --owner",
           "reference": f"RosettaSciIO {PIN} (rsciio.tiff.file_reader, defaults); tifffile {TIFFFILE_VERSION}",
           "versions": versions(R["np"]), "files": files}
    return dump(out), files


def main():
    warnings.simplefilter("ignore")
    logging.disable(logging.CRITICAL)   # tifffile's and RosettaSciIO's notes on deliberately odd files
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--owner", nargs="+", metavar="FILE")
    ap.add_argument("--out", metavar="PATH")
    ap.add_argument("--work", metavar="DIR", help="existing directory for the unpacked zips and gz files (default: system temp)")
    a = ap.parse_args()
    if bool(a.owner) != bool(a.out):
        die("--owner and --out go together")
    work = Path(a.work) if a.work else Path(tempfile.gettempdir())
    if not work.is_dir():
        die(f"--work {work} is not a directory")
    if a.owner:
        first = build_owner(a.owner, work)
        second = build_owner(a.owner, work)
        if first[0] != second[0]:
            die("two readings differ: not byte-reproducible")
        Path(a.out).write_text(first[0], encoding="utf-8")
        print(f"{a.out}: {len(first[0].encode())} bytes; {json.dumps(summarize(first[1]), sort_keys=True)}")
        return
    first = build_default(work)
    second = build_default(work)
    if first[0] != second[0]:
        die("two builds differ: not byte-reproducible")
    FIXTURES.mkdir(parents=True, exist_ok=True)
    (FIXTURES / "step-2-pins.json").write_text(first[0], encoding="utf-8")
    print(f"step-2-pins.json: {len(first[0].encode('utf-8'))} bytes, sha256 {sha256_bytes(first[0].encode('utf-8'))}")
    print(json.dumps(summarize(first[1]), sort_keys=True, indent=1))


if __name__ == "__main__":
    main()

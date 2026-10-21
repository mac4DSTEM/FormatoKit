#!/usr/bin/env python3
"""FormatoKit vs RosettaSciIO benchmark driver (docs/benchmarks.md).

    tools/memcap.sh -- References/rsciio-venv/bin/python -I -B tools/benchmarks/bench.py run --work DIR [--large] [--only PREFIX]
    References/rsciio-venv/bin/python -I -B tools/benchmarks/bench.py report --work DIR --out docs/benchmarks.md

`gen` writes the inputs under DIR (a scratch folder, never the repo) and DIR/cases.json; `run` generates what is missing, then for
every case starts one child process per side (a fresh interpreter for RosettaSciIO, `formato-bench` for the kit), each doing one
warm-up read then five timed reads of the whole data, and collects the median, the spread (min, max) and the child's peak resident
size; `report` writes the table. Sizes: small, typical, large; large cases are generated and run only with --large (the nightly
review). The timed operation is "open the file and have all its data in memory" on both sides: `file_reader(lazy=False)` against
the kit's signal load. Inputs are integer-valued so both sides' data sums (reported to prove same work) are exact.
The kit binary is built with `swift build -c release --product formato-bench` (not `--build-tests`).
"""
import argparse
import json
import os
import resource
import struct
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
RUNS = 5
SIDE_KIT = os.path.join(REPO, ".build", "release", "formato-bench")
sys.path.insert(0, os.path.join(REPO, "tools", "step-4"))

# ------------------------------------------------------------------------------------------------- generators


def u64(n):
    return struct.pack(">Q", n)


def dm_tag(name, info, payload):
    b = name.encode()
    return b"\x15" + struct.pack(">H", len(b)) + b + u64(0) + b"%%%%" + u64(len(info)) + b"".join(u64(x) for x in info) + payload


def dm_group(name, children):
    b = name.encode()
    body = b"\x01\x00" + u64(len(children)) + b"".join(children)
    return b"\x14" + struct.pack(">H", len(b)) + b + u64(len(body)) + body


def dm_text(name, s):
    return dm_tag(name, [20, 4, len(s.encode("utf-16le")) // 2], s.encode("utf-16le"))


def dm_number(name, n):
    return dm_tag(name, [7], struct.pack("<d", n))


def dm_integer(name, n):
    return dm_tag(name, [3], struct.pack("<i", n))


def write_dm4(path, array, code, enc, units):
    """array in C order (last axis fastest); DM lists dimensions fastest-first."""
    dims = list(array.shape[::-1])
    axes = [dm_group(str(i), [dm_number("Origin", 0.0), dm_number("Scale", 1.0), dm_text("Units", units[i])]) for i in range(len(dims))]
    image = dm_group("0", [dm_text("Name", "bench"), dm_group("ImageData", [
        dm_integer("DataType", code), dm_group("Dimensions", [dm_integer(str(i), d) for i, d in enumerate(dims)]),
        dm_group("Calibrations", [dm_group("Dimension", axes)]), dm_tag("Data", [20, enc, array.size], array.tobytes())]),
        dm_group("ImageTags", [dm_group("Microscope Info", [dm_number("Voltage", 200000.0)])])])
    root = b"\x01\x00" + u64(1) + dm_group("ImageList", [image])
    with open(path, "wb") as fh:
        fh.write(struct.pack(">I", 4) + u64(len(root)) + struct.pack(">I", 1) + root)


def gen_dm4_image(path, n):
    a = (np.arange(n * n, dtype=np.int64) % 65521).astype("<f4").reshape(n, n)
    write_dm4(path, a, 2, 6, ["nm", "nm"])


def gen_dm4_4d(path, r, q):
    a = (np.arange(r * r * q * q, dtype=np.int64) % 65521).astype("<u2").reshape(r, r, q, q)
    write_dm4(path, a, 10, 4, ["nm", "nm", "1/nm", "1/nm"])


def velox_helpers():
    import make_velox_si as mv
    return mv


def gen_velox_image(path, n, frames):
    mv = velox_helpers()
    with mv.new_file(path, 11, "v11") as f:
        data = (np.arange(n * n * frames, dtype=np.int64) % 65521).astype("<u2").reshape(n, n, frames)
        g = f.create_group("Data/Image/img0")
        g.create_dataset("Data", data=data, chunks=(n, n, 1), track_times=False)
        g.create_dataset("Metadata", data=mv.metadata_column(mv.image_doc((n, n), (0, 0, 1, 1), frame_time="0.25")), track_times=False)


def gen_velox_si(path, n, mean_events):
    mv = velox_helpers()
    rng = np.random.default_rng(20261021)
    npix = n * n
    counts = rng.poisson(mean_events, npix).astype(np.int64)
    total = int(counts.sum()) + npix
    stream = rng.integers(0, 4096, total, dtype=np.int64).astype(np.uint16)
    stream[np.cumsum(counts + 1) - 1] = 65535
    with mv.new_file(path, 11, "v11") as f:
        area = (0, 0, 1, 1)
        mv.add_image(f, "img0", (np.arange(npix, dtype=np.int64) % 60000).astype("<u2").reshape(n, n, 1), mv.image_doc((n, n), area))
        mv.add_si_settings(f, {"startFramePosition": "1", "endFramePosition": "1"})
        det = mv.detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-1", "SuperXG11", "5", "-480")])
        mv.add_stream(f, "s0", stream, 4096, "uint16", mv.base_doc(det, "SuperXG1", "1", (n, n), area))
    return total


def gen_velox_spectrum(path):
    sys.path.insert(0, os.path.join(REPO, "tools", "velox-spectrum"))
    import pins as vp
    with vp.new_file(path, 9) as f:
        vp.add_spectrum(f, "0a", (np.arange(4096, dtype=np.uint32) * 7 % 1000).reshape(4096, 1), vp.spectrum_doc())


def gen_tiff(path, n):
    import tifffile
    tifffile.imwrite(path, (np.arange(n * n, dtype=np.int64) % 65521).astype("<u2").reshape(n, n), description="", metadata=None)


def gen_mrc(path, n, frames):
    h = bytearray(1024)
    struct.pack_into("<4i", h, 0, n, n, frames, 2)
    struct.pack_into("<3i", h, 28, n, n, frames)
    struct.pack_into("<3f", h, 40, float(n), float(n), float(frames))
    struct.pack_into("<3i", h, 64, 1, 2, 3)
    h[208:212] = b"MAP "
    h[212:216] = b"\x44\x44\0\0"
    with open(path, "wb") as fh:
        fh.write(bytes(h))
        for k in range(frames):
            fh.write((np.arange(n * n, dtype=np.int64) % 65521 + k).astype("<f4").tobytes())


def gen_mib(path, frames, q=256):
    def header(i):
        prefix = f"MQ1,{i:06d},00384,1,{q},{q},U16,1x1,12,"
        tail = f",2026-01-02T03:04:{i // 3 % 60:02d}.{i % 3:06d}Z,1250000ns,0,\0"
        return (prefix + " " * (384 - len(prefix) - len(tail)) + tail).encode()
    with open(path, "wb") as fh:
        for i in range(frames):
            fh.write(header(i) + ((np.arange(q * q, dtype=np.int64) * 7 + i) % 4096).astype(">u2").tobytes())
    return frames


def gen_empad(base, scan):
    raw = np.zeros((scan * scan, 130, 128), dtype="<f4")
    raw[:, :128, :] = (np.arange(128 * 128, dtype=np.int64) % 255).reshape(1, 128, 128) + np.arange(scan * scan).reshape(-1, 1, 1) % 7
    raw[:, 128:, :] = -9999
    open(base + ".raw", "wb").write(raw.tobytes())
    open(base + ".xml", "w").write(f'<root><raw_file filename="{os.path.basename(base)}.raw"/><pix_x>{scan}</pix_x><pix_y>{scan}</pix_y>'
                                   '<timestamp><isoformat>2026-01-02T03:04:05</isoformat></timestamp><iom_measurements>'
                                   '<calibrated_pixelsize>3.315e-10</calibrated_pixelsize></iom_measurements></root>')


def gen_hdf5_4d(path, r, q):
    import h5py
    with h5py.File(path, "w") as f:
        a = (np.arange(r * r * q * q, dtype=np.int64) % 65521).astype("<f4").reshape(r, r, q, q)
        f.create_dataset("cube/data", data=a, chunks=(1, 1, q, q))


def gen_msa(path, n):
    from rsciio import msa
    data = (np.arange(n, dtype=np.int64) % 997).astype(float)
    axis = {"size": n, "index_in_array": 0, "name": "Energy", "scale": 0.01, "offset": -1.0, "units": "keV", "navigate": False}
    msa.file_writer(path, {"data": data, "axes": [axis], "metadata": {"General": {"title": "bench"}, "Signal": {"signal_type": ""}}, "original_metadata": {}}, format="Y")


# (id, label, size, large?, builder name, args)
CASES = [
    ("dm4-image-512", "DM4 image", "512² f32", "small", False),
    ("dm4-image-2048", "DM4 image", "2048² f32", "typical", False),
    ("dm4-image-4096", "DM4 image", "4096² f32", "large", True),
    ("dm4-4d-16x64", "DM4 4D", "16²x64² u16", "small", False),
    ("dm4-4d-32x128", "DM4 4D", "32²x128² u16", "typical", False),
    ("dm4-4d-128x128", "DM4 4D", "128²x128² u16", "large", True),
    ("velox-image-1024", "Velox image", "1024² x1 u16", "small", False),
    ("velox-image-2048x5", "Velox image", "2048² x5 u16", "typical", False),
    ("velox-image-4096x10", "Velox image", "4096² x10 u16", "large", True),
    ("velox-spectrum", "Velox spectrum", "4096 ch u32", "small", False),
    ("velox-si-16", "Velox SI (EDS)", "16² px, 4096 ch, 100 ev/px", "small", False),
    ("velox-si-128", "Velox SI (EDS)", "128² px, 4096 ch, 100 ev/px", "typical", False),
    ("velox-si-512", "Velox SI (EDS)", "512² px, 4096 ch, 100 ev/px", "large", True),
    ("tiff-1024", "TIFF", "1024² u16", "small", False),
    ("tiff-4096", "TIFF", "4096² u16", "typical", False),
    ("tiff-8192", "TIFF", "8192² u16", "large", True),
    ("mrc-512x1", "MRC", "512² x1 f32", "small", False),
    ("mrc-1024x10", "MRC", "1024² x10 f32", "typical", False),
    ("mrc-2048x20", "MRC", "2048² x20 f32", "large", True),
    ("mib-64", "MIB", "256² x64 U16", "small", False),
    ("mib-1024", "MIB", "256² x1024 U16", "typical", False),
    ("mib-16384", "MIB", "256² x16384 U16", "large", True),
    ("empad-16", "EMPAD", "16² scan, 128x130 f32", "small", False),
    ("empad-48", "EMPAD", "48² scan, 128x130 f32", "typical", False),
    ("empad-128", "EMPAD", "128² scan, 128x130 f32", "large", True),
    ("hdf5-4d-16x64", "HDF5 4D cube", "16²x64² f32", "small", False),
    ("hdf5-4d-32x128", "HDF5 4D cube", "32²x128² f32", "typical", False),
    ("hdf5-4d-64x256", "HDF5 4D cube", "64²x256² f32", "large", True),
    ("msa-4096", "MSA", "4096 points", "small", False),
    ("msa-65536", "MSA", "65 536 points", "typical", False),
    ("msa-1m", "MSA", "1 048 576 points", "large", True),
]
FORMAT_OF = {"dm4-image": "dm", "dm4-4d": "dm4d", "velox-image": "velox-images", "velox-spectrum": "velox-spectrum", "velox-si": "velox-si", "tiff": "tiff",
             "mrc": "mrc", "mib": "mib", "empad": "empad", "hdf5-4d": "hdf5", "msa": "msa"}


def kind_of(cid):
    for k in sorted(FORMAT_OF, key=len, reverse=True):
        if cid.startswith(k):
            return FORMAT_OF[k]


def build(cid, work):
    n = int(cid.split("-")[-1].split("x")[0]) if cid != "velox-spectrum" and cid != "msa-1m" else 0
    if cid.startswith("dm4-image"):
        p = os.path.join(work, cid + ".dm4"); gen_dm4_image(p, n); return {"path": p}
    if cid.startswith("dm4-4d"):
        r = int(cid.split("-")[-1].split("x")[0]); q = int(cid.split("x")[-1]); p = os.path.join(work, cid + ".dm4"); gen_dm4_4d(p, r, q); return {"path": p}
    if cid.startswith("velox-image"):
        frames = int(cid.split("-")[-1].split("x")[1]) if "x" in cid.split("-")[-1] else 1; p = os.path.join(work, cid + ".emd"); gen_velox_image(p, n, frames); return {"path": p}
    if cid == "velox-spectrum":
        p = os.path.join(work, cid + ".emd"); gen_velox_spectrum(p); return {"path": p}
    if cid.startswith("velox-si"):
        p = os.path.join(work, cid + ".emd"); ev = gen_velox_si(p, n, 100); return {"path": p, "events": ev}
    if cid.startswith("tiff"):
        p = os.path.join(work, cid + ".tif"); gen_tiff(p, n); return {"path": p}
    if cid.startswith("mrc"):
        frames = int(cid.split("-")[-1].split("x")[1]); p = os.path.join(work, cid + ".mrc"); gen_mrc(p, n, frames); return {"path": p}
    if cid.startswith("mib"):
        p = os.path.join(work, cid + ".mib"); gen_mib(p, n); return {"path": p, "frames": n}
    if cid.startswith("empad"):
        b = os.path.join(work, cid); gen_empad(b, n); return {"path": b + ".xml"}
    if cid.startswith("hdf5-4d"):
        r = int(cid.split("-")[-1].split("x")[0]); q = int(cid.split("x")[-1]); p = os.path.join(work, cid + ".h5"); gen_hdf5_4d(p, r, q); return {"path": p, "dataset": "/cube/data"}
    if cid.startswith("msa"):
        n = 1048576 if cid == "msa-1m" else n; p = os.path.join(work, cid + ".msa"); gen_msa(p, n); return {"path": p}
    raise KeyError(cid)


# ------------------------------------------------------------------------------------------------- the python side


def python_read(case):
    kind, path = case["kind"], case["path"]
    if kind == "dm":
        from rsciio.digitalmicrograph import file_reader
        return lambda: file_reader(path, lazy=False)[0]["data"]
    if kind == "dm4d":
        from rsciio.digitalmicrograph import file_reader
        return lambda: file_reader(path, lazy=False)[0]["data"]
    if kind == "velox-images":
        from rsciio.emd import file_reader
        return lambda: file_reader(path, select_type="images", lazy=False)[0]["data"]
    if kind == "velox-spectrum":
        from rsciio.emd import file_reader
        return lambda: file_reader(path, select_type="single_spectrum", lazy=False)[0]["data"]
    if kind == "velox-si":
        from rsciio.emd import file_reader
        return lambda: file_reader(path, select_type="spectrum_image", lazy=False)[0]["data"]
    if kind == "tiff":
        from rsciio.tiff import file_reader
        return lambda: file_reader(path, lazy=False)[0]["data"]
    if kind == "mrc":
        from rsciio.mrc import file_reader
        return lambda: file_reader(path, lazy=False)[0]["data"]
    if kind == "mib":
        from rsciio.quantumdetector import file_reader
        return lambda: np.array(file_reader(path, lazy=False)[0]["data"])
    if kind == "empad":
        from rsciio.empad import file_reader
        return lambda: np.array(file_reader(path, lazy=False)[0]["data"])
    if kind == "hdf5":
        import h5py

        def read():
            with h5py.File(path) as f:
                return f[case["dataset"]][...]
        return read
    if kind == "msa":
        from rsciio.msa import file_reader
        return lambda: file_reader(path)[0]["data"]
    raise KeyError(kind)


def child_python(case):
    read = python_read(case)
    read()   # warm-up (imports, jit, page cache)
    times = []
    for _ in range(RUNS):
        t0 = time.perf_counter()
        data = read()
        times.append(time.perf_counter() - t0)
    total = float(np.asarray(data, dtype=np.float64).sum())
    import rsciio
    print(json.dumps({"times": times, "rss_mb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6, "sum": total, "shape": list(np.shape(data)),
                      "version": rsciio.__version__}))


# ------------------------------------------------------------------------------------------------- orchestration


def run_child(argv, env=None):
    p = subprocess.run(argv, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        return {"error": (p.stderr or p.stdout).strip().splitlines()[-1:] or ["failed"]}
    line = [l for l in p.stdout.splitlines() if l.startswith("{")][-1]
    return json.loads(line)


def load_cases(work):
    return json.load(open(os.path.join(work, "cases.json")))


def cmd_run(args):
    os.makedirs(args.work, exist_ok=True)
    cases_path = os.path.join(args.work, "cases.json")
    cases = json.load(open(cases_path)) if os.path.exists(cases_path) else {}
    for cid, label, size, tier, large in CASES:
        if args.only and not cid.startswith(args.only):
            continue
        if large and not args.large:
            cases.setdefault(cid, {"label": label, "size": size, "tier": tier, "kind": kind_of(cid), "nightly": True})
            continue
        if cid not in cases or "path" not in cases[cid] or not os.path.exists(cases[cid]["path"]):
            print("generating", cid, flush=True)
            cases[cid] = dict(label=label, size=size, tier=tier, kind=kind_of(cid), nightly=False, **build(cid, args.work))
        json.dump(cases, open(cases_path, "w"), indent=1)
        case = dict(cases[cid], id=cid)
        json.dump(case, open(os.path.join(args.work, cid + ".case.json"), "w"))
        print("running", cid, flush=True)
        cases[cid]["python"] = run_child([sys.executable, "-I", "-B", os.path.abspath(__file__), "child", "--case", os.path.join(args.work, cid + ".case.json")])
        cases[cid]["kit"] = run_child([SIDE_KIT, os.path.join(args.work, cid + ".case.json")])
        json.dump(cases, open(cases_path, "w"), indent=1)


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def fmt_time(t):
    return f"{t * 1000:.1f} ms" if t < 1 else f"{t:.2f} s"


def cmd_report(args):
    cases = load_cases(args.work)
    import platform
    rows = []
    for cid, label, size, tier, large in CASES:
        c = cases.get(cid)
        if not c:
            continue
        k, p = c.get("kit"), c.get("python")
        if c.get("nightly") or not k or not p:
            rows.append(f"| {label} | {size} | {tier} | nightly | nightly | nightly | | |")
            continue
        if "error" in k or "error" in p:
            rows.append(f"| {label} | {size} | {tier} | {k.get('error', 'ok')} | {p.get('error', 'ok')} | | | |")
            continue
        km, pm = median(k["times"]), median(p["times"])
        same = "yes" if k.get("sum") == p.get("sum") else f"NO ({k.get('sum')} vs {p.get('sum')})"
        rows.append(f"| {label} | {size} | {tier} | {fmt_time(km)} ({fmt_time(min(k['times']))} to {fmt_time(max(k['times']))}) | "
                    f"{fmt_time(pm)} ({fmt_time(min(p['times']))} to {fmt_time(max(p['times']))}) | {pm / km:.2f}x | "
                    f"{k['rss_mb']:.0f} / {p['rss_mb']:.0f} MB | {same} |")
    any_py = next((c["python"] for c in cases.values() if c.get("python") and "version" in c["python"]), {})
    out = "\n".join([
        "| Format | Input | Size | Kit CPU: median (min to max) | RosettaSciIO: median (min to max) | Python / kit | Peak RSS kit / Python | Same data sum |",
        "|---|---|---|---|---|---|---|---|", *rows])
    open(args.out + ".table", "w").write(out + "\n")
    print(out)
    print(json.dumps({"python": platform.python_version(), "rsciio": any_py.get("version"), "machine": platform.machine(), "mac": platform.mac_ver()[0]}))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run"); r.add_argument("--work", required=True); r.add_argument("--large", action="store_true"); r.add_argument("--only")
    c = sub.add_parser("child"); c.add_argument("--case", required=True)
    rep = sub.add_parser("report"); rep.add_argument("--work", required=True); rep.add_argument("--out", required=True)
    args = ap.parse_args()
    if args.cmd == "run":
        cmd_run(args)
    elif args.cmd == "child":
        child_python(json.load(open(args.case)))
    else:
        cmd_report(args)


if __name__ == "__main__":
    main()

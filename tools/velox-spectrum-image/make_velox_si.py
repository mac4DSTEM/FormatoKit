#!/usr/bin/env python3
"""Planted Velox spectrum-image files.

    References/rsciio-venv/bin/python -I -B tools/velox-spectrum-image/make_velox_si.py [--out DIR]

writes the files into DIR (default Tests/FormatoEMDTests/Fixtures/velox-spectrum-image). THE TRUTH IS THE PLANTED COUNTS: each file's
counts per stream, frame, pixel and channel are drawn from a seed (or typed) HERE, the stream is encoded from them, and
`expected(name, options)` computes every option set's arrays from those counts by these definitions (frames
first_frame <= f < last_frame, last_frame 0 never stopping, rebinning, `+= 1` in the target type), without RosettaSciIO's code.
tools/velox-spectrum-image/pins.py reads the files with RosettaSciIO and stops if it disagrees.

The `sk-<case>.emd` files take SpectroKit 0.4.0's planted streams and HAADF data VERBATIM from the copies in
DIR/spectrokit/ (PROVENANCE.md there); their truth is SpectroKit's draw (DIR/spectrokit/velox-streams-truth.json), not a
decode. Only the metadata is completed (pixel size, Acquisition, Displays), so RosettaSciIO reads them.
"""
import argparse
import json
import os

import h5py
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(REPO, "Tests", "FormatoEMDTests", "Fixtures", "velox-spectrum-image")
S = h5py.string_dtype()
MARK = 65535
SEED = 20261015
SK_CASES = ["1stream-1frame", "1stream-3frames", "4streams-2frames", "unterminated", "axis-decoy", "axis-order"]

# The option sets (O10 is filled per file: last_frame one past the recorded frame count).
OPTIONS = {
    "O1": {},
    "O2": {"sum_frames": False},
    "O3": {"sum_EDS_detectors": False},
    "O4": {"rebin_energy": 4},
    "O5": {"SI_dtype": "float32"},
    "O6": {"SI_dtype": "uint8"},
    "O7": {"first_frame": 1},
    "O8": {"last_frame": 1},
    "O9": {"sum_frames": False, "sum_EDS_detectors": False, "rebin_energy": 2, "SI_dtype": "int8", "first_frame": 1},
    "O10": None,
}

# ------------------------------------------------------------------------------------------------- layout helpers

def metadata_column(doc, rows=None):
    raw = json.dumps(doc).encode("utf-8")
    rows = rows or max(4096, len(raw) + 64)
    col = np.zeros((rows, 1), dtype=np.uint8)
    col[: len(raw), 0] = np.frombuffer(raw, dtype=np.uint8)
    return col


def write_json(group, name, doc):
    group.create_dataset(name, data=np.array([json.dumps(doc)], dtype=object), dtype=S, track_times=False)


def detectors_doc(entries):
    """entries: [(key, name, dispersion eV or None, offset eV or None)] in WRITTEN order."""
    out = {}
    for key, name, disp, off in entries:
        d = {"DetectorName": name, "DetectorType": "AnalyticalDetector" if disp is not None else "ScanningDetector", "Enabled": "true"}
        if disp is not None:
            d.update({"Dispersion": disp, "OffsetEnergy": off, "ElevationAngle": "0.3", "AzimuthAngle": "0.785"})
        out[key] = d
    return out


def base_doc(detectors, br_detector, br_index, scan_size, scan_area, frame_time="0.5", volts="300000",
             pixel=("2e-9", "2e-9"), offset=("-1e-8", "3e-9"), unit="m"):
    br = {"Detector": br_detector, "PixelSize": {"width": pixel[0], "height": pixel[1]}, "PixelUnitX": unit,
          "PixelUnitY": unit, "Offset": {"x": offset[0], "y": offset[1]}}
    if br_index is not None:
        br["DetectorIndex"] = br_index
    doc = {"Acquisition": {"AcquisitionStartDatetime": {"DateTime": "1490107072"}}, "BinaryResult": br,
           "Detectors": detectors, "Optics": {"AccelerationVoltage": volts}, "CustomProperties": {}}
    scan = {}
    if scan_size is not None:
        scan["ScanSize"] = {"width": str(scan_size[0]), "height": str(scan_size[1])}
    if scan_area is not None:
        scan["ScanArea"] = dict(zip(("left", "top", "right", "bottom"), map(str, scan_area)))
    if frame_time is not None:
        scan["FrameTime"] = frame_time
    doc["Scan"] = scan
    return doc


def new_file(path, version, displays):
    f = h5py.File(path, "w", track_order=False)
    write_json(f, "Version", {"version": str(version), "format": "Velox"})
    if displays == "v11":
        f.create_group("Displays").create_group("ImageDisplay")
    elif displays == "v9":
        f.create_group("Presentation").create_group("Displays").create_group("ImageDisplay")
    f.create_group("Data")
    return f


def add_image(f, name, data, doc):
    g = f.create_group(f"Data/Image/{name}")
    g.create_dataset("Data", data=data, track_times=False)
    g.create_dataset("Metadata", data=metadata_column(doc), track_times=False)


def add_si_settings(f, settings, md=None):
    g = f.create_group("Data/SpectrumImage/si0")
    write_json(g, "SpectrumImageSettings", settings)
    if md is not None:
        g.create_dataset("Metadata", data=metadata_column(md), track_times=False)


def add_stream(f, name, values, bincount, encoding, doc):
    g = f.create_group(f"Data/SpectrumStream/{name}")
    g.create_dataset("Data", data=np.asarray(values, dtype=np.uint16).reshape(-1, 1), track_times=False)
    write_json(g, "AcquisitionSettings", {"bincount": str(bincount), "StreamEncoding": encoding})
    g.create_dataset("Metadata", data=metadata_column(doc), track_times=False)


def image_doc(scan_size, scan_area, **kw):
    return base_doc(detectors_doc([("Detector-0", "HAADF", None, None)]), "HAADF", "0", scan_size, scan_area, **kw)

# ------------------------------------------------------------------------------------------------- the planted counts

class Planted:
    """counts[s][f][p] = {channel: n} for stream s, frame f, pixel p; recorded[s] = pixels of the last frame written
    (None = whole), terminated[s] = whether the stream's last pixel has its marker."""
    def __init__(self, ny, nx, frames, streams, bins):
        self.ny, self.nx, self.frames = ny, nx, frames
        self.bins = bins   # per stream
        self.counts = [[[{} for _ in range(ny * nx)] for _ in range(frames)] for _ in range(streams)]
        self.recorded = [None] * streams
        self.terminated = [True] * streams

    def add(self, s, f, p, ch, n=1):
        self.counts[s][f][p][ch] = self.counts[s][f][p].get(ch, 0) + n

    def encode(self, s, rng):
        """The stream: per frame, per pixel, its events in shuffled order, then 65535."""
        out = []
        npix = self.ny * self.nx
        for f in range(self.frames):
            last = f == self.frames - 1
            pixels = self.recorded[s] if (last and self.recorded[s] is not None) else npix
            for p in range(pixels):
                ev = [ch for ch, n in sorted(self.counts[s][f][p].items()) for _ in range(n)]
                rng.shuffle(ev)
                out.extend(ev)
                if not (last and p == pixels - 1 and not self.terminated[s]):
                    out.append(MARK)
        return out

    def recorded_frames(self, s):
        return self.frames


def accumulate(n, dtype):
    """n times `+= 1` in dtype, from 0: integers wrap, floats stop where +1 no longer changes them."""
    dt = np.dtype(dtype)
    if dt.kind in "iu":
        return np.array(n % (1 << (8 * dt.itemsize)), dtype=np.uint64).astype(dt.str.replace("i", "u")).view(dt)
    limit = 1 << (24 if dt.itemsize == 4 else 53)
    return np.array(min(n, limit), dtype=dt)


def expected_arrays(pl, enc0, options, streams_summed):
    """The expected arrays, from the planted counts. Returns a list (one per signal)."""
    first = options.get("first_frame", 0)
    last = options.get("last_frame")
    rebin = options.get("rebin_energy", 1)
    dtype = options.get("SI_dtype") or enc0
    sum_frames = options.get("sum_frames", True)
    sum_det = options.get("sum_EDS_detectors", True)
    if last is None:
        last = pl.number_of_frames
    npix = pl.ny * pl.nx

    def frames_used():
        # the loop stops when the frame counter, incremented on the value after a frame's last marker, equals last_frame;
        # last_frame 0 never stops (the counter starts at 0 and is incremented before the test)
        return [f for f in range(pl.frames) if f >= first and (last == 0 or f < last)]

    def fill(target_counts, s, bins0):
        for f in frames_used():
            pixels = pl.recorded[s] if (f == pl.frames - 1 and pl.recorded[s] is not None) else npix
            for p in range(pixels):
                for ch, n in pl.counts[s][f][p].items():
                    assert ch < bins0, "planted channel beyond the bin count"
                    key = (p // pl.nx, p % pl.nx, ch // rebin) if sum_frames else (f - first, p // pl.nx, p % pl.nx, ch // rebin)
                    target_counts[key] = target_counts.get(key, 0) + n

    def materialise(target_counts, bins):
        shape = (pl.ny, pl.nx, bins // rebin) if sum_frames else (last - first, pl.ny, pl.nx, bins // rebin)
        a = np.zeros(shape, dtype=dtype)
        for key, n in target_counts.items():
            a[key] = accumulate(n, dtype)
        return a

    streams = range(len(pl.counts))
    if sum_det:
        c = {}
        for s in streams:
            fill(c, s, pl.bins[0])
        return [materialise(c, pl.bins[0])]
    out = []
    for s in streams:
        c = {}
        fill(c, s, pl.bins[s])
        out.append(materialise(c, pl.bins[s]))
    return out

# ------------------------------------------------------------------------------------------------- the files

def file_v11(out):
    rng = np.random.default_rng([SEED, 4, 1])
    ny, nx, frames = 3, 4, 3
    pl = Planted(ny, nx, frames, 3, [16, 16, 16])
    for s in range(3):
        for f in range(frames):
            for p in range(ny * nx):
                for _ in range(int(rng.integers(0, 7))):
                    pl.add(s, f, p, int(rng.integers(0, 16)))
    pl.add(0, 1, 5, 7, 300)        # one voxel of 300 counts in stream 0 (uint8 wraps)
    pl.add(1, 0, 0, 0, 3)          # channel 0
    pl.add(2, 2, 3, 15, 2)         # channel 15, in the last frame
    pl.recorded[0] = 7             # stream 0's last frame stops after 7 pixels ...
    pl.add(0, 2, 6, 9, 4)          # ... whose last pixel has events and no marker
    pl.terminated[0] = False
    pl.number_of_frames = 3
    path = os.path.join(out, "si-planted-v11.emd")
    with new_file(path, 11, "v11") as f:
        area = (0.25, 0, 0.75, 0.5)
        add_image(f, "img0", np.arange(ny * nx * frames, dtype=np.uint16).reshape(ny, nx, frames), image_doc((8, 6), area))
        add_si_settings(f, {"startFramePosition": "1", "endFramePosition": "3"})
        # written order: the decoy SuperXG23 comes before SuperXG21, so "SuperXG2" CONTAINED picks Detector-3
        det = detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-3", "SuperXG23", "5", "-20"),
                             ("Detector-1", "SuperXG21", "10", "-50"), ("Detector-2", "SuperXG22", "10", "-50")])
        for s, (name, br, idx) in enumerate([("s0", "SuperXG2", "1"), ("s1", "SuperXG22", "2"), ("s2", "SuperXG23", "3")]):
            add_stream(f, name, pl.encode(s, rng), 16, "uint8", base_doc(det, br, idx, (8, 6), area))
    return pl, "uint8", "si-planted-v11.emd"


def file_v9(out):
    rng = np.random.default_rng([SEED, 4, 2])
    ny, nx, frames = 2, 3, 4
    pl = Planted(ny, nx, frames, 1, [8])
    for f in range(frames):
        for p in range(ny * nx):
            for _ in range(int(rng.integers(0, 5))):
                pl.add(0, f, p, int(rng.integers(0, 8)))
    pl.add(0, 3, 4, 6, 200)        # int8: 200 -> -56 (plus whatever else lands there)
    pl.number_of_frames = 4        # from the markers: no endFramePosition
    path = os.path.join(out, "si-planted-v9.emd")
    with new_file(path, 9, "v9") as f:
        area = (0, 0, 1, 1)
        add_image(f, "img0", (np.arange(ny * nx * frames, dtype=np.uint16) * 3).reshape(ny, nx, frames),
                  image_doc((nx, ny), area, frame_time="1.5e-3"))
        add_si_settings(f, {"startFramePosition": "1"})
        det = detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-1", "UltraX1", "15", "-480.5")])
        add_stream(f, "a", pl.encode(0, rng), 8, "int8",
                   base_doc(det, "UltraX1", "1", (nx, ny), area, frame_time="1.5e-3", volts="200000", pixel=("1.5e-10", "1.25e-10"),
                            offset=("0", "-2.5e-10")))
    return pl, "int8", "si-planted-v9.emd"


EELS_TRUTH = {}


def file_eels(out):
    rng = np.random.default_rng([SEED, 4, 3])
    ny, nx = 2, 3
    pl = Planted(ny, nx, 1, 1, [8])
    for p in range(ny * nx):
        pl.add(0, 0, p, p % 8, p + 1)
    pl.number_of_frames = 1
    path = os.path.join(out, "si-planted-eels.emd")
    # EELS e1: stored (x, E, y) = (3, 5, 2) uint16, value 100*x + 10*E + y; RosettaSciIO's transpose (2, 0, 1) makes it
    # (y, x, E) with value[y][x][E] = 100*x + 10*E + y. e2: stored (x, E) = (3, 5) float32, value x + E/4.
    e1 = np.zeros((nx, 5, ny), dtype=np.uint16)
    for x in range(nx):
        for e in range(5):
            for y in range(ny):
                e1[x, e, y] = 100 * x + 10 * e + y
    e2 = np.zeros((nx, 5), dtype=np.float32)
    for x in range(nx):
        for e in range(5):
            e2[x, e] = x + e / 4
    t1 = np.zeros((ny, nx, 5), dtype=np.uint16)
    for y in range(ny):
        for x in range(nx):
            for e in range(5):
                t1[y, x, e] = 100 * x + 10 * e + y      # typed from the stored rule, not from a transpose call
    EELS_TRUTH["si-planted-eels.emd"] = [t1, e2.copy()]
    with new_file(path, 11, "v11") as f:
        area = (0, 0, 1, 1)
        add_image(f, "img0", np.arange(ny * nx, dtype=np.uint16).reshape(ny, nx, 1), image_doc((nx, ny), area))
        si_md = base_doc(detectors_doc([("Detector-0", "HAADF", None, None)]), "HAADF", "0", (nx, ny), area,
                         pixel=("5e-9", "4e-9"), offset=("1e-8", "-2e-8"))
        add_si_settings(f, {"startFramePosition": "1", "endFramePosition": "1"}, md=si_md)
        for name, data, acq in [("e1", e1, {"Data": {"offset": 100.5, "dispersion": 0.25}}),
                                ("e2", e2, {"Data": {"offset": -5, "dispersion": 0.05}})]:
            g = f.create_group(f"Data/EelsSpectrumImage/{name}")
            g.create_dataset("Data", data=data, track_times=False)
            g.create_dataset("AcquisitionMetadata", data=metadata_column(acq), track_times=False)
            g.create_dataset("Metadata", data=metadata_column({"Core": {"MetadataDefinitionVersion": "7.9"}, "Id": name}), track_times=False)
        det = detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-1", "SuperXG11", "20", "-1000")])
        add_stream(f, "s0", pl.encode(0, rng), 8, "uint16", base_doc(det, "SuperXG1", "1", (nx, ny), area))
    return pl, "uint16", "si-planted-eels.emd"


def file_grid(out):
    rng = np.random.default_rng([SEED, 4, 4])
    pl = Planted(3, 4, 1, 1, [8])
    for p in range(12):
        pl.add(0, 0, p, p % 8)
    pl.number_of_frames = 1
    path = os.path.join(out, "si-planted-grid.emd")
    with new_file(path, 11, "v11") as f:
        area = (0, 0, 0.375, 0.5)       # ScanSize 8 x 8: 3 wide, 4 tall; the image is 3 tall, 4 wide
        add_image(f, "img0", np.arange(12, dtype=np.uint16).reshape(3, 4, 1), image_doc((8, 8), area))
        add_si_settings(f, {"startFramePosition": "1", "endFramePosition": "1"})
        det = detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-1", "SuperXG11", "20", "-1000")])
        add_stream(f, "s0", pl.encode(0, rng), 8, "uint16", base_doc(det, "SuperXG1", "1", (8, 8), area))
    return pl, "uint16", "si-planted-grid.emd"


def file_bins(out):
    rng = np.random.default_rng([SEED, 4, 5])
    pl = Planted(2, 2, 1, 2, [16, 32])
    for s in range(2):
        for p in range(4):
            pl.add(s, 0, p, (3 * p + s) % 16, 1 + s)
    pl.number_of_frames = 1
    path = os.path.join(out, "si-planted-bins.emd")
    with new_file(path, 11, "v11") as f:
        area = (0, 0, 1, 1)
        add_image(f, "img0", np.arange(4, dtype=np.uint16).reshape(2, 2, 1), image_doc((2, 2), area))
        add_si_settings(f, {"startFramePosition": "1", "endFramePosition": "1"})
        det = detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-1", "SuperXG11", "20", "-1000"),
                             ("Detector-2", "SuperXG12", "20", "-1000")])
        add_stream(f, "s0", pl.encode(0, rng), 16, "uint16", base_doc(det, "SuperXG11", "1", (2, 2), area))
        add_stream(f, "s1", pl.encode(1, rng), 32, "uint16", base_doc(det, "SuperXG12", "2", (2, 2), area))
    return pl, "uint16", "si-planted-bins.emd"


def file_endframe(out):
    """Amendment A1: endFramePosition (2) below the stream's own frames (3), so last_frame's default is told from the markers'
    count; and the matched detector without Dispersion, so the energy axis is RosettaSciIO's KeyError fallback (1, 0, none)."""
    rng = np.random.default_rng([SEED, 4, 6])
    pl = Planted(2, 2, 3, 1, [8])
    for f in range(3):
        for p in range(4):
            pl.add(0, f, p, (p + 2 * f) % 8, 1 + f)
    pl.number_of_frames = 2
    path = os.path.join(out, "si-planted-endframe.emd")
    with new_file(path, 11, "v11") as f:
        area = (0, 0, 1, 1)
        add_image(f, "img0", np.arange(12, dtype=np.uint16).reshape(2, 2, 3), image_doc((2, 2), area))
        add_si_settings(f, {"startFramePosition": "1", "endFramePosition": "2"})
        det = detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-1", "SuperXG11", "20", "-1000")])
        del det["Detector-1"]["Dispersion"]
        add_stream(f, "s0", pl.encode(0, rng), 8, "uint16", base_doc(det, "SuperXG1", "1", (2, 2), area))
    return pl, "uint16", "si-planted-endframe.emd"


def file_sk(out, case, truth):
    """SpectroKit's planted case: its stream(s), settings and HAADF data verbatim; metadata completed."""
    src = os.path.join(out, "spectrokit", f"velox-stream-{case}.emd")
    t = truth["cases"][case]
    ny, nx, frames = t["grid"]["ny"], t["grid"]["nx"], t["frames"]
    pl = Planted(ny, nx, frames, len(t["streams"]), [t["channels"]] * len(t["streams"]))
    for s, st in enumerate(t["streams"]):
        for f, per_pixel in enumerate(st["events"]):
            for p, events in enumerate(per_pixel):
                for ch, n in events:
                    pl.add(s, f, p, ch, n)
        pl.terminated[s] = t["terminated"]
    path = os.path.join(out, f"sk-{case}.emd")
    with h5py.File(src, "r") as g, new_file(path, 11, "v11") as f:
        pl.number_of_frames = int(json.loads(g["Data/SpectrumImage/si00/SpectrumImageSettings"][0])["endFramePosition"])
        for name in g["Data/Image"]:
            img = g[f"Data/Image/{name}"]
            doc = json.loads(img["Metadata"][:, 0].tobytes().decode("utf-8").rstrip("\x00"))
            complete(doc)
            h = f.create_group(f"Data/Image/{name}")
            h.create_dataset("Data", data=img["Data"][()], track_times=False)
            h.create_dataset("Metadata", data=metadata_column(doc, rows=img["Metadata"].shape[0]), track_times=False)
        h = f.create_group("Data/SpectrumImage/si00")
        h.create_dataset("SpectrumImageSettings", data=g["Data/SpectrumImage/si00/SpectrumImageSettings"][()], dtype=S, track_times=False)
        encs = []
        for name in g["Data/SpectrumStream"]:
            st = g[f"Data/SpectrumStream/{name}"]
            h = f.create_group(f"Data/SpectrumStream/{name}")
            h.create_dataset("Data", data=st["Data"][()], track_times=False)                 # verbatim
            h.create_dataset("FrameLocationTable", data=st["FrameLocationTable"][()], track_times=False)
            h.create_dataset("AcquisitionSettings", data=st["AcquisitionSettings"][()], dtype=S, track_times=False)
            encs.append(json.loads(st["AcquisitionSettings"][0])["StreamEncoding"])
            md = st["Metadata"][()]
            doc = json.loads(md[:, 0].tobytes().decode("utf-8").rstrip("\x00"))
            complete(doc)
            md = md.copy()
            md[:, 0:1] = metadata_column(doc, rows=md.shape[0])                             # the decoy columns stay
            h.create_dataset("Metadata", data=md, track_times=False)
    return pl, encs[0], f"sk-{case}.emd"


def complete(doc):
    """What RosettaSciIO indexes and SpectroKit's metadata lacks: the pixel size, Acquisition, CustomProperties; and a
    DetectorIndex naming no Detectors entry is dropped (axis-decoy and axis-order name Detector-3, which they lack, and
    RosettaSciIO's `_get_detector_information` raises on that before the energy axis it was planted to test)."""
    br = doc.setdefault("BinaryResult", {})
    index = br.get("DetectorIndex")
    if index is not None and f"Detector-{index}" not in doc.get("Detectors", {}):
        del br["DetectorIndex"]
    br.setdefault("PixelSize", {"width": "1e-9", "height": "1e-9"})
    br.setdefault("PixelUnitX", "m")
    br.setdefault("PixelUnitY", "m")
    br.setdefault("Offset", {"x": "0", "y": "0"})
    doc.setdefault("Acquisition", {"AcquisitionStartDatetime": {"DateTime": "1490107072"}})
    doc.setdefault("CustomProperties", {})


def build(out):
    """Writes every planted file; returns {name: (Planted, stream 0 encoding)}."""
    os.makedirs(out, exist_ok=True)
    made = {}
    for maker in (file_v11, file_v9, file_eels, file_grid, file_bins, file_endframe):
        pl, enc, name = maker(out)
        made[name] = (pl, enc)
    with open(os.path.join(out, "spectrokit", "velox-streams-truth.json")) as fh:
        truth = json.load(fh)
    for case in SK_CASES:
        pl, enc, name = file_sk(out, case, truth)
        made[name] = (pl, enc)
    return made


def options_for(pl):
    out = {}
    for key, opts in OPTIONS.items():
        out[key] = dict(opts) if opts is not None else {"last_frame": pl.number_of_frames + 1}
    return out


def expected(made, name, opts):
    """The planted arrays of one file and option set: the EELS ones (typed) then the EDS ones (§3.5)."""
    pl, enc = made[name]
    return EELS_TRUTH.get(name, []) + expected_arrays(pl, enc, opts, opts.get("sum_EDS_detectors", True))


# Files whose RosettaSciIO reading FormatoKit refuses on purpose, by option set.
DEVIATIONS = {
    "si-planted-grid.emd": ("all", "grid: ScanSize x ScanArea is 4 x 3, the first image 3 x 4 (§3.3)"),
    "si-planted-bins.emd": ("unsummed", "a stream's bin count differs from stream 0's with sum_EDS_detectors=False (§3.5)"),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    made = build(a.out)
    for name, (pl, enc) in made.items():
        print(name, f"{pl.ny}x{pl.nx}", pl.frames, "frames", len(pl.counts), "streams", enc)


if __name__ == "__main__":
    main()

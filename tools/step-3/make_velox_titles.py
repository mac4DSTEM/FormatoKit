#!/usr/bin/env python3
"""Planted Velox image files for step 3 (docs/registration-step-3.md §4): the title rule and the stored types.

    References/rsciio-venv/bin/python -I -B tools/step-3/make_velox_titles.py [--out DIR]

writes four files into DIR (default Tests/FormatoEMDTests/Fixtures) and prints EXPECT as JSON. THE TRUTH IS EXPECT, typed
by hand below from RosettaSciIO 049e7d70's rules as registration §3.2 states them; no reader is consulted here.
tools/step-3/pins.py reads the files with RosettaSciIO and stops if it disagrees with EXPECT.

Every image is (2, 3, 1) (y, x, frame), its values distinct and chosen so a wrong stored type shows: uint64 and int64 beyond
2^53, float64 that float32 does not hold, int8 negatives. Every image's metadata has what RosettaSciIO's `_read_image`
indexes (BinaryResult.PixelSize/Offset/PixelUnitX, Acquisition.AcquisitionStartDatetime, Detectors["Detector-<index>"]).
"""
import argparse
import json
import os

import h5py
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
ROWS = 8192
S = h5py.string_dtype()

# file -> image id -> (stored dtype, expected title or None); every title typed by hand (registration §3.2).
EXPECT = {
    "velox-titles-v6-image.emd": {
        "a01": ("uint8", "BM-Ceta"),          # CameraInputOperation -> cameraName (a STEM entry also names a01: camera first)
        "a02": ("uint16", "HAADF"),           # StemInputOperation -> detector (a Presentation label exists: Image files ignore it)
        "a03": ("uint32", "iDPC"),            # SurfaceReconstruction on unfilteredDataPath, integrationMode "true"
        "a04": ("int8", "dDPC"),              # SurfaceReconstruction on dataPath, integrationMode "false", no filter
        "a05": ("int16", "Filtered iDPC"),    # on dataPath, enableFilter "true"
        "a06": ("int32", "A-C"),              # MathematicsOperation, outputs[0].inputIndex "0"
        "a07": ("int64", "B-D"),              # inputIndex "1"
        "a08": ("uint64", "DPC"),             # a Mathematics entry with inputIndex "2" falls through to DpcOperation
        "a09": ("float32", "DCFI"),           # IntegrationOperation (an FftOperation's dataPath also names a09)
        "a10": ("float64", "Half FFT"),       # FftOperation on imageOutputPath
        "a11": ("uint16", "Unrecognized_image_signal"),  # no entry names it
        "a12": ("uint8", "DI-a12"),           # its camera entry lacks cameraName: KeyError -> DetectorInformation
        "b1": ("float32", "DF-S"),            # "b1" is a substring of the STEM entry's path "/Data/Image/b12"
        "b12": ("int16", "DF-S"),
    },
    "velox-titles-v11-noops.emd": {
        "img-a": ("uint16", None),            # no Operations, no DetectorIndex: no name yet, no title
        "img-b": ("uint16", "DF4-B"),         # DetectorIndex "2" -> Detectors["Detector-2"].DetectorName
        "img-c": ("uint16", "DF4-B"),         # no DetectorIndex: the name carried from img-b
        "img-e": ("uint16", "HAADF"),         # DetectorIndex as the JSON number 0
    },
    "velox-titles-v11-labels.emd": {
        "c1": ("uint16", "Si-K"),             # Displays.ImageDisplay entry -> SharedProperties dataPath -> its id
        "c2": ("uint16", "DI-c2"),            # no display: the DetectorInformation name (a Presentation label exists: v11 ignores it)
    },
    "velox-titles-v9-labels.emd": {
        "d1": ("uint16", "HAADF-label"),      # Presentation/Displays/ImageDisplay display.label
        "d2": ("uint16", "HAADF2"),           # no display: its StemInputOperation detector
    },
}


def values(dtype, seed):
    """Six distinct values of `dtype`, (2, 3, 1)."""
    k = np.arange(6) + 7 * seed
    if dtype == "uint64":
        v = (np.uint64(2**63) + k.astype(np.uint64) * np.uint64(2**40 + 3))
    elif dtype == "int64":
        v = -(np.int64(2**62) + k.astype(np.int64) * np.int64(2**33 + 5))
    elif dtype == "float64":
        v = np.array([0.1, 1e300, -2.5e-310, 1 / 3, -7.25, 2.0**60 + 1.0])
    elif dtype == "float32":
        v = (k.astype(np.float32) * np.float32(0.3) - np.float32(1.1))
    elif dtype == "int8":
        v = (-128 + 3 * k).astype(np.int8)
    else:
        info = np.iinfo(dtype)
        v = (info.max - 11 * k).astype(dtype)
    return np.asarray(v, dtype=dtype).reshape(2, 3, 1)


def metadata(detector_index="1", names=None, binary_detector="X"):
    dets = {f"Detector-{i}": {"DetectorName": n, "DetectorType": "ImagingDetector"} for i, n in (names or {}).items()}
    binary = {"Detector": binary_detector, "PixelSize": {"width": "2e-10", "height": "2e-10"},
              "Offset": {"x": "0", "y": "0"}, "PixelUnitX": "m", "PixelUnitY": "m"}
    if detector_index is not None:
        binary["DetectorIndex"] = detector_index
    doc = {"BinaryResult": binary, "Detectors": dets, "Acquisition": {"AcquisitionStartDatetime": {"DateTime": "1600000000"}},
           "Optics": {"AccelerationVoltage": "200000"}, "Scan": {"DwellTime": "1e-6"}}
    raw = json.dumps(doc).encode()
    assert len(raw) < ROWS
    return np.frombuffer(raw + b"\0" * (ROWS - len(raw)), dtype=np.uint8).reshape(ROWS, 1)


def text(group, name, obj):
    group.create_dataset(name, data=[json.dumps(obj)], dtype=S)


def image(f, gid, dtype, seed, md):
    g = f.create_group(f"Data/Image/{gid}")
    g.create_dataset("Data", data=values(dtype, seed), track_times=False)
    g.create_dataset("Metadata", data=md, track_times=False)


def version(f, v):
    f.create_dataset("Version", data=[json.dumps({"version": str(v), "format": "Velox"})], dtype=S)


def si(f):
    f.create_dataset("Data/SpectrumImage/si00/SpectrumImageSettings",
                     data=[json.dumps({"startFramePosition": "1", "endFramePosition": "1"})], dtype=S)


def p(gid):
    return f"/Data/Image/{gid}"


def write_v6(path):
    exp = EXPECT[os.path.basename(path)]
    with h5py.File(path, "w") as f:
        version(f, 6)
        for i, (gid, (dt, _)) in enumerate(exp.items()):
            image(f, gid, dt, i, metadata("1", {1: f"DI-{gid}"}))
        ops = f.create_group("Operations")
        text(ops.create_group("CameraInputOperation"), "e1", {"dataPath": p("a01"), "cameraName": "BM-Ceta"})
        text(ops["CameraInputOperation"], "e2", {"dataPath": p("a12")})
        stem = ops.create_group("StemInputOperation")
        text(stem, "e1", {"dataPath": p("a01"), "detector": "WRONG-STEM"})
        text(stem, "e2", {"dataPath": p("a02"), "detector": "HAADF"})
        text(stem, "e3", {"dataPath": p("b12"), "detector": "DF-S"})
        sr = ops.create_group("SurfaceReconstructionOperation")
        text(sr, "e1", {"unfilteredDataPath": p("a03"), "dataPath": "/Data/Image/zzz", "integrationMode": "true", "enableFilter": "false"})
        text(sr, "e2", {"dataPath": p("a04"), "integrationMode": "false", "enableFilter": "false"})
        text(sr, "e3", {"unfilteredDataPath": "/Data/Image/zzz", "dataPath": p("a05"), "integrationMode": "true", "enableFilter": "true"})
        ma = ops.create_group("MathematicsOperation")
        text(ma, "e1", {"dataPath": p("a06"), "outputs": [{"inputIndex": "0"}]})
        text(ma, "e2", {"dataPath": p("a07"), "outputs": [{"inputIndex": "1"}]})
        text(ma, "e3", {"dataPath": p("a08"), "outputs": [{"inputIndex": "2"}]})
        text(ops.create_group("DpcOperation"), "e1", {"dataPath": p("a08")})
        text(ops.create_group("IntegrationOperation"), "e1", {"dataPath": p("a09")})
        text(ops.create_group("FftOperation"), "e1", {"imageOutputPath": p("a10"), "dataPath": p("a09")})
        pres = f.create_group("Presentation/Displays/ImageDisplay")
        text(pres, "k1", {"dataPath": p("a02"), "display": {"label": "NOT-FOR-IMAGE-FILES"}})


def write_v11_noops(path):
    exp = EXPECT[os.path.basename(path)]
    names = {0: "HAADF", 2: "DF4-B"}
    mds = {"img-a": metadata(None, names), "img-b": metadata("2", names), "img-c": metadata(None, names),
           "img-e": metadata(0, names)}
    with h5py.File(path, "w") as f:
        version(f, 11)
        for i, (gid, (dt, _)) in enumerate(exp.items()):
            image(f, gid, dt, i, mds[gid])


def write_v11_labels(path):
    exp = EXPECT[os.path.basename(path)]
    with h5py.File(path, "w") as f:
        version(f, 11)
        for i, (gid, (dt, _)) in enumerate(exp.items()):
            image(f, gid, dt, i, metadata("1", {1: f"DI-{gid}"}))
        si(f)
        disp = f.create_group("Displays/ImageDisplay")
        text(disp, "u1", {"data": "/SharedProperties/ImageSeriesDataReference/r1", "id": "Si-K"})
        text(disp, "u2", {"id": "no-data-key"})
        text(f.create_group("SharedProperties/ImageSeriesDataReference"), "r1", {"dataPath": p("c1")})
        text(f.create_group("Presentation/Displays/ImageDisplay"), "k1", {"dataPath": p("c2"), "display": {"label": "WRONG-PRESENTATION"}})


def write_v9_labels(path):
    exp = EXPECT[os.path.basename(path)]
    with h5py.File(path, "w") as f:
        version(f, 9)
        for i, (gid, (dt, _)) in enumerate(exp.items()):
            image(f, gid, dt, i, metadata("1", {1: f"DI-{gid}"}))
        si(f)
        stem = f.create_group("Operations/StemInputOperation")
        text(stem, "e1", {"dataPath": p("d1"), "detector": "HAADF1"})
        text(stem, "e2", {"dataPath": p("d2"), "detector": "HAADF2"})
        text(f.create_group("Presentation/Displays/ImageDisplay"), "k1", {"dataPath": p("d1"), "display": {"label": "HAADF-label"}})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "Tests/FormatoEMDTests/Fixtures"))
    out = ap.parse_args().out
    for name, writer in (("velox-titles-v6-image.emd", write_v6), ("velox-titles-v11-noops.emd", write_v11_noops),
                         ("velox-titles-v11-labels.emd", write_v11_labels), ("velox-titles-v9-labels.emd", write_v9_labels)):
        writer(os.path.join(out, name))
    print(json.dumps({f: {g: {"dtype": d, "title": t} for g, (d, t) in imgs.items()} for f, imgs in EXPECT.items()}, indent=1))


if __name__ == "__main__":
    main()

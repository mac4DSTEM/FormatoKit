#!/usr/bin/env python3
"""Planted Velox single-spectrum files and RosettaSciIO's reading of them (FormatoKit 0.9.0, `VeloxSpectrumSignals`).

    References/venv/bin/python -I -B tools/velox-spectrum/pins.py

writes Tests/FormatoEMDTests/Fixtures/spectra/*.emd and Tests/FormatoEMDTests/Fixtures/spectra-pins.json.
Every record is `rsciio.emd.file_reader(path, select_type="single_spectrum", lazy=False)`: its exception, or per returned
dictionary the dtype, shape, data sha256 (little-endian C-order bytes), the axes, the General and Signal metadata and the
`mapping` RosettaSciIO returns applied the way HyperSpy applies it (`hyperspy/io.py` `dict2signal`: when the dotted path is in
`original_metadata`, value = function(value), set when not None); an exception inside a function is recorded. The date, time and
time zone are recorded under four process time zones (TZ + tzset, which `dateutil.tz.tzlocal` reads at every call).
The planted data is typed here; the reader's output must equal it (checked before anything is written).
"""
import hashlib
import json
import os
import shutil
import sys
import time

import h5py
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
FIX = os.path.join(REPO, "Tests", "FormatoEMDTests", "Fixtures")
OUT = os.path.join(FIX, "spectra")
S = h5py.string_dtype()
ZONES = ["Europe/Berlin", "America/New_York", "Asia/Kolkata", "UTC"]


def column(doc, rows=4096):
    raw = json.dumps(doc).encode("utf-8")
    col = np.zeros((max(rows, len(raw) + 16), 1), dtype=np.uint8)
    col[: len(raw), 0] = np.frombuffer(raw, dtype=np.uint8)
    return col


def write_json(group, name, doc):
    group.create_dataset(name, data=np.array([json.dumps(doc)], dtype=object), dtype=S, track_times=False)


def detectors(entries):
    out = {}
    for key, name, disp, off in entries:
        d = {"DetectorName": name, "DetectorType": "AnalyticalDetector" if disp is not None else "ScanningDetector"}
        if disp is not None:
            d.update({"Dispersion": disp, "OffsetEnergy": off})
        out[key] = d
    return out


def spectrum_doc(**kw):
    doc = {"Acquisition": {"AcquisitionStartDatetime": {"DateTime": "1490107072.25"}},
           "BinaryResult": {"Detector": "SuperXG1", "DetectorIndex": 1},
           "Detectors": detectors([("Detector-0", "HAADF", None, None), ("Detector-1", "SuperXG11", "5", "-480")]),
           "Optics": {"AccelerationVoltage": "200000", "CameraLength": "0.098"},
           "CustomProperties": {"StemMagnification": {"value": "40000", "type": "double"}},
           "Instrument": {"InstrumentClass": "Talos", "InstrumentModel": "Talos F200X"},
           "Stage": {"AlphaTilt": "0.0001", "BetaTilt": "-0.2", "Position": {"x": "-9.0000004e-06", "y": "0.0001444", "z": "2.94e-05"}}}
    doc.update(kw)
    return doc


def new_file(path, version=9, fmt="Velox"):
    f = h5py.File(path, "w", track_order=False)
    write_json(f, "Version", {"version": str(version), "format": fmt})
    f.create_group("Data")
    if version >= 11:
        f.create_group("Displays").create_group("ImageDisplay")
    else:
        f.create_group("Presentation").create_group("Displays").create_group("ImageDisplay")
    return f


def add_spectrum(f, name, data, doc):
    g = f.create_group(f"Data/Spectrum/{name}")
    g.create_dataset("Data", data=data, track_times=False)
    g.create_dataset("Metadata", data=column(doc), track_times=False)


def add_image_and_si(f):
    g = f.create_group("Data/Image/img0")
    g.create_dataset("Data", data=np.arange(6, dtype=np.uint16).reshape(2, 3, 1), track_times=False)
    doc = {"BinaryResult": {"Detector": "HAADF", "PixelSize": {"width": "1e-9", "height": "1e-9"}, "PixelUnitX": "m", "PixelUnitY": "m",
                            "Offset": {"x": "0", "y": "0"}},
           "Detectors": detectors([("Detector-0", "HAADF", None, None)]), "Scan": {"FrameTime": "1"},
           "Acquisition": {"AcquisitionStartDatetime": {"DateTime": "1490107072"}}, "Optics": {"AccelerationVoltage": "200000"}}
    g.create_dataset("Metadata", data=column(doc), track_times=False)
    s = f.create_group("Data/SpectrumImage/si0")
    write_json(s, "SpectrumImageSettings", {"startFramePosition": "1", "endFramePosition": "1"})
    st = f.create_group("Data/SpectrumStream/s0")
    st.create_dataset("Data", data=np.array([65535], dtype=np.uint16).reshape(-1, 1), track_times=False)
    write_json(st, "AcquisitionSettings", {"bincount": "8", "StreamEncoding": "uint8"})
    st.create_dataset("Metadata", data=column(doc), track_times=False)


# name -> (planted array as RosettaSciIO returns it, builder)
def build(out):
    cases = {}

    def make(name, version=9, fmt="Velox"):
        return new_file(os.path.join(out, name + ".emd"), version, fmt)

    ramp = np.arange(12, dtype=np.uint32) * 7 + 1
    with make("sp-single") as f:                                   # Spectrum type, one spectrum, uint32 (bins, 1)
        add_spectrum(f, "0a", ramp.reshape(12, 1), spectrum_doc())
    cases["sp-single"] = [ramp]

    with make("sp-devkit", fmt="DevelopersKit") as f:               # is_EMD_Velox accepts "DevelopersKit" as well
        add_spectrum(f, "d", ramp.reshape(12, 1), spectrum_doc())
    cases["sp-devkit"] = [ramp]
    with make("sp-notvelox", fmt="Other") as f:                    # any other format string is not a Velox file
        add_spectrum(f, "d", ramp.reshape(12, 1), spectrum_doc())

    stack = (np.arange(18, dtype=np.uint32).reshape(6, 3) * 3)      # stored (bins, stack)
    with make("sp-stack") as f:
        add_spectrum(f, "k", stack, spectrum_doc())
    cases["sp-stack"] = [stack.T]

    a = np.array([-3, 0, 5, 9, 11], dtype=np.int16).reshape(5, 1)
    b = np.array([0.5, 1.5, -2.25, 8, 1e7, 3], dtype=np.float32).reshape(6, 1)
    with make("sp-two") as f:                                      # names sort: "aa" before "zz"; the dtypes differ
        add_spectrum(f, "zz", b, spectrum_doc(Detectors=detectors([("Detector-1", "SuperXG12", "10", "-96.5")]),
                                               BinaryResult={"Detector": "SuperXG1", "DetectorIndex": 1}))
        add_spectrum(f, "aa", a, spectrum_doc())
    cases["sp-two"] = [a[:, 0], b[:, 0]]

    flat = np.arange(8, dtype=np.uint16)
    with make("sp-rank1") as f:                                    # a rank-1 Data
        add_spectrum(f, "r", flat, spectrum_doc())
    cases["sp-rank1"] = [flat]

    nodisp = np.arange(5, dtype=np.uint64).reshape(5, 1) * 2 ** 40
    with make("sp-nodetector") as f:                               # BinaryResult without Detector: axis (1, 0, no units)
        add_spectrum(f, "n", nodisp, spectrum_doc(BinaryResult={"DetectorIndex": 0}))
    cases["sp-nodetector"] = [nodisp[:, 0]]

    ceta = np.arange(4, dtype=np.int8).reshape(4, 1) - 2
    with make("sp-ceta-stamp") as f:                               # no AcquisitionStartDatetime: the Ceta time stamp, microseconds
        doc = spectrum_doc(Acquisition={}, CustomProperties={"Detectors[BM-Ceta].TimeStamp": {"value": "1490107072123456.0"}})
        del doc["Instrument"], doc["Stage"]
        add_spectrum(f, "c", ceta, doc)
    cases["sp-ceta-stamp"] = [ceta[:, 0]]

    with make("sp-stream", 11) as f:                               # Image + SpectrumImage + Spectrum (type SpectrumStream)
        add_image_and_si(f)
        add_spectrum(f, "s", ramp.reshape(12, 1), spectrum_doc(DetectorMetadata={"ElevationAngle": "0.6108652", "Gain": "5.0", "Offset": "-480",
                                                                                 "AzimuthAngle": "1.5707963", "LiveTime": "12.3456789",
                                                                                 "RealTime": "13.5", "DetectorName": "SuperXG11"},
                                                          ImportedDataParameter={"Number_of_frames": 20}))
    cases["sp-stream"] = [ramp]

    with make("sp-images-only") as f:                              # Image + Spectrum, no SpectrumImage: type Image, spectra not read
        g = f.create_group("Data/Image/img0")
        g.create_dataset("Data", data=np.arange(6, dtype=np.uint16).reshape(2, 3, 1), track_times=False)
        g.create_dataset("Metadata", data=column({"BinaryResult": {"Detector": "HAADF", "PixelSize": {"width": "1e-9", "height": "1e-9"},
                                                                    "PixelUnitX": "m", "PixelUnitY": "m", "Offset": {"x": "0", "y": "0"}}}),
                         track_times=False)
        add_spectrum(f, "s", ramp.reshape(12, 1), spectrum_doc())
    cases["sp-images-only"] = []

    with make("sp-none") as f:                                     # no spectra at all
        f.create_group("Data/Image")
    cases["sp-none"] = []

    # refusals: RosettaSciIO raises
    with make("sp-no-acquisition") as f:
        doc = spectrum_doc()
        del doc["Acquisition"]
        add_spectrum(f, "s", ramp.reshape(12, 1), doc)
    with make("sp-bad-voltage") as f:
        add_spectrum(f, "s", ramp.reshape(12, 1), spectrum_doc(Optics={"AccelerationVoltage": "abc"}))
    with make("sp-no-detector0") as f:
        add_spectrum(f, "s", ramp.reshape(12, 1), spectrum_doc(BinaryResult={"Detector": "SuperXG1", "DetectorIndex": 7}))
    with make("sp-bad-dispersion") as f:
        add_spectrum(f, "s", ramp.reshape(12, 1), spectrum_doc(Detectors=detectors([("Detector-1", "SuperXG11", "fast", "-480")])))
    return cases


def sha(a):
    return hashlib.sha256(np.ascontiguousarray(a).astype(a.dtype.newbyteorder("<")).tobytes()).hexdigest()


def dotted_in(d, path):
    cur = d
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return False, None
        cur = cur[part]
    return True, cur


def record(path):
    from rsciio.emd import file_reader
    try:
        dicts = file_reader(path, select_type="single_spectrum", lazy=False)
    except Exception as e:  # noqa: BLE001
        return {"raises": type(e).__name__}
    recs = []
    for d in dicts:
        om = d["original_metadata"]
        mapped = {}
        for opattr, (mpattr, fn) in d["mapping"].items():
            if mpattr == "Sample.elements":
                continue
            ok, value = dotted_in(om, opattr)
            if not ok:
                continue
            try:
                if fn is not None:
                    value = fn(value)
            except Exception as e:  # noqa: BLE001
                mapped[mpattr] = {"raises": type(e).__name__}
                continue
            if value is not None:
                mapped[mpattr] = value if not isinstance(value, np.generic) else value.item()
        md = d["metadata"]
        recs.append({
            "dtype": str(d["data"].dtype), "shape": list(d["data"].shape), "data_sha256": sha(d["data"]),
            "axes": [{k: v for k, v in ax.items()} for ax in d["axes"]],
            "general": md["General"], "signal": md["Signal"], "mapped": mapped,
        })
    return recs


PUBLIC = [("fei_emd_files.zip", n) for n in ["fei_emd_spectrum.emd", "fei_SI_EDS-HAADF-4detectors_2frames.emd", "fei_emd_si.emd",
                                              "fei_SI_SuperX-HAADF_10frames_10x50.emd", "fei_emd_image.emd"]] + \
         [("velox_emd_version11.zip", "Test SI 16x16 215 kx.emd"), ("velox_emd_version11.zip", "Test SI 16x16 ReducedData 215 kx.emd"),
          ("velox_EELS_EDS.zip", "example_velox_EELS_EDS.emd")]


def public_pins():
    """RosettaSciIO's public Velox test files (unzipped from the pinned clone's zips into a fresh directory), the same records."""
    import tempfile
    import zipfile
    data = os.path.join(REPO, "References", "rosettasciio-049e7d70", "rsciio", "tests", "data", "emd")
    out = {}
    with tempfile.TemporaryDirectory() as tmp:
        for zname in sorted({z for z, _ in PUBLIC}):
            zipfile.ZipFile(os.path.join(data, zname)).extractall(os.path.join(tmp, zname))
        for zname, fname in PUBLIC:
            path = os.path.join(tmp, zname, fname)
            per_zone = {}
            for zone in ZONES:
                os.environ["TZ"] = zone
                time.tzset()
                per_zone[zone] = record(path)
            out[f"{zname}/{fname}"] = {"zones": per_zone}
    os.environ["TZ"] = "Europe/Berlin"
    time.tzset()
    return out


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    cases = build(OUT)
    pins = {"rsciio": __import__("rsciio").__version__, "cases": {}}
    for name in sorted(f[:-4] for f in os.listdir(OUT) if f.endswith(".emd")):
        path = os.path.join(OUT, name + ".emd")
        per_zone = {}
        for zone in ZONES:
            os.environ["TZ"] = zone
            time.tzset()
            per_zone[zone] = record(path)
        os.environ["TZ"] = "Europe/Berlin"
        time.tzset()
        # everything but the time zone entries must agree across zones
        base = per_zone[ZONES[0]]
        if isinstance(base, list):
            for z in ZONES[1:]:
                for r0, r1 in zip(base, per_zone[z]):
                    for k in ("dtype", "shape", "data_sha256", "axes", "signal"):
                        assert r0[k] == r1[k], (name, z, k)
        if name in cases:
            truth = cases[name]
            assert isinstance(base, list) and len(base) == len(truth), name
            for r, t in zip(base, truth):
                assert r["shape"] == list(t.shape) and r["dtype"] == str(t.dtype) and r["data_sha256"] == sha(t), (name, "planted data differs")
        pins["cases"][name] = {"zones": per_zone}
    pins["public"] = public_pins()
    with open(os.path.join(FIX, "spectra-pins.json"), "w") as fh:
        json.dump(pins, fh, indent=1, sort_keys=True)
        fh.write("\n")
    print("wrote", len(pins["cases"]), "cases")


if __name__ == "__main__":
    main()

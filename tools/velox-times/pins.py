#!/usr/bin/env python3
"""Planted Velox spectrum images with live and real times, and RosettaSciIO's reading of them (FormatoKit 0.11.0).

    References/rsciio-venv/bin/python -I -B tools/velox-times/pins.py
        writes Tests/FormatoEMDTests/Fixtures/times/si-times-planted.emd, si-times-differ.emd and velox-times-pins.json

The files are built with the helpers of tools/velox-spectrum-image/make_velox_si.py (h5py, no data of the owner's): a Velox 11 file with one
image, one Super-X spectrum stream and a `Data/SpectrumImage` group whose Metadata states the optics (camera length, STEM
magnification), the pixel size and, per X-ray detector segment, the RealTime and LiveTime. In the first file three segments are
enabled and state the same times and the fourth is disabled (0); in the second the enabled segments state different times.

The pins are RosettaSciIO's (`rsciio.emd.file_reader(select_type="spectrum_image")`): the axes of the EDS signal (pixel size, in the
unit it converts to), and the `Acquisition_instrument.TEM.camera_length` and `.magnification` its returned mapping gives
(applied to the original_metadata as HyperSpy does). RosettaSciIO maps NO live or real time for a spectrum image: the script
asserts that no mapping target holds `live_time` or `real_time`, and records the planted times as the truth (typed here, from
what this script wrote). Built twice in the process, the outputs compared. Needs sparse and numba in the venv (step 4).
"""
import importlib.util
import json
import logging
import shutil
import sys
import tempfile
import warnings
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Tests" / "FormatoEMDTests" / "Fixtures" / "times"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


step1 = module("step1_pins", ROOT / "tools" / "dm-velox-pins" / "pins.py")
M = module("make_velox_si", ROOT / "tools" / "velox-spectrum-image" / "make_velox_si.py")

ENABLED_TIMES = ("4187.7267542261652", "1423.1050950000008")


def detectors(times):
    """Four Super-X segments (written order Detector-5..8) with their RealTime and LiveTime, plus the HAADF scanning detector."""
    det = M.detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-5", "SuperXG11", "10", "-480"), ("Detector-6", "SuperXG12", "10", "-480"),
                           ("Detector-7", "SuperXG13", "10", "-480"), ("Detector-8", "SuperXG14", "10", "-480")])
    for key, (real, live, enabled) in zip(["Detector-5", "Detector-6", "Detector-7", "Detector-8"], times):
        det[key]["RealTime"], det[key]["LiveTime"], det[key]["Enabled"] = real, live, enabled
    return det


def doc(times, camera, magnification):
    d = M.base_doc(detectors(times), "SuperXG1", "5", (4, 3), (0, 0, 1, 1), pixel=("1.26953125e-09", "2.5e-09"), offset=("0", "0"), volts="200000")
    d["Optics"]["CameraLength"] = camera
    d["CustomProperties"]["StemMagnification"] = {"type": "double", "value": magnification}
    return d


FILES = {
    "si-times-planted.emd": ([(ENABLED_TIMES[0], ENABLED_TIMES[1], "true")] * 3 + [("0", "0", "false")], "0.125", "94000"),
    "si-times-differ.emd": ([("100.5", "50.25", "true"), ("100.5", "49.75", "true"), ("101.5", "50.25", "true"), ("0", "0", "false")], "0.2", "0"),
}


def write(path, name):
    times, camera, magnification = FILES[name]
    rng = np.random.default_rng([20261022, len(name)])
    ny, nx = 3, 4
    pl = M.Planted(ny, nx, 1, 1, [8])
    for p in range(ny * nx):
        pl.add(0, 0, p, p % 8, (p % 3) + 1)
    pl.number_of_frames = 1
    with M.new_file(str(path), 11, "v11") as f:
        M.add_image(f, "img0", np.arange(ny * nx, dtype=np.uint16).reshape(ny, nx, 1), M.image_doc((nx, ny), (0, 0, 1, 1)))
        d = doc(times, camera, magnification)
        M.add_si_settings(f, {"startFramePosition": "1", "endFramePosition": "1"}, md=d)
        M.add_stream(f, "s0", pl.encode(0, rng), 8, "uint16", d)


def build(out):
    warnings.simplefilter("ignore")
    logging.disable(logging.CRITICAL)
    R = step1.load_rsciio()
    out.mkdir(parents=True, exist_ok=True)
    files = []
    for name in FILES:
        write(out / name, name)
        sigs = R["emd"].file_reader(str(out / name), lazy=False, select_type="spectrum_image")
        assert len(sigs) == 1, name
        sig = sigs[0]
        targets = {t for _, (t, _) in sig["mapping"].items()}
        assert not any("live_time" in t or "real_time" in t for t in targets), "RosettaSciIO maps a live or real time for a spectrum image"
        mapped = step1.apply_mapping(sig, ("Acquisition_instrument.TEM.camera_length", "Acquisition_instrument.TEM.magnification",
                                           "Acquisition_instrument.TEM.beam_energy"))
        times, camera, magnification = FILES[name]
        files.append({
            "file": name,
            "axes": [{"name": a["name"], "size": int(a["size"]), "scale": float(a["scale"]), "scale_bits": step1.bits(a["scale"]),
                      "units": a["units"], "navigate": bool(a["navigate"])} for a in sig["axes"]],
            "mapped": {t: {"value": float(v), "bits": step1.bits(v), "source": s} for t, (v, s) in sorted(mapped.items())},
            "planted": {"pixel_size_m": {"width": 1.26953125e-09, "height": 2.5e-09}, "camera_length_m": float(camera),
                        "stem_magnification": float(magnification),
                        "segments": [{"name": f"SuperXG1{i + 1}", "real_time_s": float(r), "live_time_s": float(l), "enabled": e == "true"}
                                     for i, (r, l, e) in enumerate(times)]},
        })
    return json.dumps({"generator": "tools/velox-times/pins.py", "reference": f"RosettaSciIO {step1.PIN} (rsciio.emd.file_reader, select_type=spectrum_image)",
                       "files": files}, indent=1, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"


def main():
    with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
        first, second = build(Path(a)), build(Path(b))
        if first != second:
            sys.exit("velox-times/pins.py: two builds differ")
        for name in FILES:
            if (Path(a) / name).read_bytes() != (Path(b) / name).read_bytes():
                sys.exit(f"velox-times/pins.py: {name} differs between two builds")
        OUT.mkdir(parents=True, exist_ok=True)
        for name in FILES:
            shutil.copyfile(Path(a) / name, OUT / name)
        (OUT / "velox-times-pins.json").write_text(first, encoding="utf-8")
    print(first[:1800])


if __name__ == "__main__":
    main()

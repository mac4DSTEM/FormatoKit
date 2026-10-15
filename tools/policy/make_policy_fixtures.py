#!/usr/bin/env python3
"""Planted Velox files for FormatoKit's 0.2.0 policies (docs/registration-0.2.0.md §3).

    References/rsciio-venv/bin/python -I -B tools/policy/make_policy_fixtures.py [--out DIR]

writes into DIR (default Tests/FormatoEMDTests/Fixtures/policy):

  si-units-px.emd   si-planted-v9.emd's counts (the same seeded draw, so the same stream) with the pixel unit "px" in the image
                    and in the stream, PixelSize width "0.5" height "0.25", Offset x "1" y "2". The truth for P1 is typed by
                    hand in Tests/FormatoEMDTests/VeloxPolicyTests.swift: scale 0.5 and 0.25, offsets 1 and 2, unit "px".

The helpers are tools/step-4/make_velox_si.py's (loaded as tools/step-4/pins.py loads it). The script stops if the stream written
differs from the one make_velox_si.py writes for si-planted-v9.emd (the counts are the planted truth shared by both files).
"""
import argparse
import importlib.util
import os
import sys
import tempfile

import h5py
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(REPO, "Tests", "FormatoEMDTests", "Fixtures", "policy")


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


truth = module("make_velox_si", os.path.join(REPO, "tools", "step-4", "make_velox_si.py"))


def file_units_px(out):
    """The v9 planted case (make_velox_si.file_v9), its draw unchanged, with pixel unit "px"."""
    rng = np.random.default_rng([truth.SEED, 4, 2])
    ny, nx, frames = 2, 3, 4
    pl = truth.Planted(ny, nx, frames, 1, [8])
    for f in range(frames):
        for p in range(ny * nx):
            for _ in range(int(rng.integers(0, 5))):
                pl.add(0, f, p, int(rng.integers(0, 8)))
    pl.add(0, 3, 4, 6, 200)
    pl.number_of_frames = 4
    path = os.path.join(out, "si-units-px.emd")
    pixel, offset, unit = ("0.5", "0.25"), ("1", "2"), "px"
    with truth.new_file(path, 9, "v9") as f:
        area = (0, 0, 1, 1)
        truth.add_image(f, "img0", (np.arange(ny * nx * frames, dtype=np.uint16) * 3).reshape(ny, nx, frames),
                        truth.image_doc((nx, ny), area, frame_time="1.5e-3", pixel=pixel, offset=offset, unit=unit))
        truth.add_si_settings(f, {"startFramePosition": "1"})
        det = truth.detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-1", "UltraX1", "15", "-480.5")])
        truth.add_stream(f, "a", pl.encode(0, rng), 8, "int8",
                         truth.base_doc(det, "UltraX1", "1", (nx, ny), area, frame_time="1.5e-3", volts="200000",
                                        pixel=pixel, offset=offset, unit=unit))
    return path


def same_stream(a, b):
    with h5py.File(a, "r") as x, h5py.File(b, "r") as y:
        return np.array_equal(x["Data/SpectrumStream/a/Data"][()], y["Data/SpectrumStream/a/Data"][()])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    path = file_units_px(a.out)
    with tempfile.TemporaryDirectory() as tmp:
        truth.file_v9(tmp)
        if not same_stream(path, os.path.join(tmp, "si-planted-v9.emd")):
            sys.exit("si-units-px.emd's stream differs from si-planted-v9.emd's")
    print(path)


if __name__ == "__main__":
    main()

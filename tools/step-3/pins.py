#!/usr/bin/env python3
"""Pins RosettaSciIO's reading of step 3's planted Velox files (docs/registration-step-3.md §2, §4).

    References/rsciio-venv/bin/python -I -B tools/step-3/pins.py
        writes Tests/FormatoCoreTests/Fixtures/step-3-pins.json from the four Tests/FormatoEMDTests/Fixtures/velox-titles-*.emd

Each file gets step 1's Velox record (tools/step-1/pins.py `velox_file`: rsciio.emd.file_reader(select_type="images") per
image: dtype, shape, data_sha256 over the stored little-endian bytes, title, axes, metadata with source), so PinsTests
compares them as it compares the public files. The script stops if RosettaSciIO's dtype or title of any image differs from
the planted truth (tools/step-3/make_velox_titles.py EXPECT, typed by hand), or if two builds in the process differ.
"""
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLANTED = ROOT / "Tests" / "FormatoEMDTests" / "Fixtures"
OUT = ROOT / "Tests" / "FormatoCoreTests" / "Fixtures" / "step-3-pins.json"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def build(step1, truth, R, np, h5py, pint):
    files = []
    for name, images in truth.EXPECT.items():
        path = PLANTED / name
        rec = step1.velox_file(path, name, "step-3-planted", R, np, h5py)
        if rec["raises"]:
            step1.die(f"{name}: RosettaSciIO raises: {rec['raises']}")
        got = {s["velox_image_id"]: (s["dtype"], s["title"]) for s in rec["signals"]}
        if got != images:
            step1.die(f"{name}: RosettaSciIO {got} differs from the planted truth {images}")
        files.append(rec)
    out = step1.header(np, h5py, pint, "step-3-planted")
    out["generator"] = "tools/step-3/pins.py"
    out["files"] = files
    return step1.dump(out)


def main():
    import h5py
    import numpy as np
    import pint
    step1 = module("step1_pins", ROOT / "tools" / "step-1" / "pins.py")
    truth = module("make_velox_titles", ROOT / "tools" / "step-3" / "make_velox_titles.py")
    R = step1.load_rsciio()
    a = build(step1, truth, R, np, h5py, pint)
    b = build(step1, truth, R, np, h5py, pint)
    if a != b:
        step1.die("two builds differ")
    OUT.write_text(a)
    n = sum(len(v) for v in truth.EXPECT.values())
    print(f"step-3 pins: {len(truth.EXPECT)} planted files, {n} images, RosettaSciIO equal to the planted truth -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    sys.exit(main())

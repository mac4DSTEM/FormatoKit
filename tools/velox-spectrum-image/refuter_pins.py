#!/usr/bin/env python3
"""Pins RosettaSciIO's reading of the Velox spectrum-image review files.

    References/venv/bin/python -I -B tools/velox-spectrum-image/refuter_pins.py
        writes Tests/FormatoCoreTests/Fixtures/velox-spectrum-image-refuter-pins.json from Tests/FormatoEMDTests/Fixtures/velox-spectrum-image/refuter/

The refuter's files on the frozen 4ac6df0 (one each per finding), with the option sets it found them under; each record as
tools/velox-spectrum-image/pins.py's. `deviations` names the files FormatoKit treats differently on purpose (A1): "all" refused although
RosettaSciIO reads, "reads" read although RosettaSciIO raises, "not-run" never given to RosettaSciIO (it would allocate past
the memory cap; FormatoKit must refuse it without allocating). The memory watchdog of tools/dm-velox-pins/pins.py is on.
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DIR = ROOT / "Tests" / "FormatoEMDTests" / "Fixtures" / "velox-spectrum-image" / "refuter"
OUT = ROOT / "Tests" / "FormatoCoreTests" / "Fixtures" / "velox-spectrum-image-refuter-pins.json"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


pins4 = module("step4_pins", ROOT / "tools" / "velox-spectrum-image" / "pins.py")
step1 = pins4.step1

FRAMES = {"O1": {}, "O2": {"sum_frames": False}}
FILES = {
    "endframe-arabic-digit.emd": {**FRAMES, "L4": {"last_frame": 4}},     # F1: endFramePosition "٣"
    "dispersion-arabic-digits.emd": {"O1": {}},                            # F1: Dispersion "١٠"
    "version-underscore.emd": {"O1": {}},                                  # F1: Version "1_1"
    "endframe-1e30.emd": {**FRAMES, "L1": {"last_frame": 1}},             # F2: endFramePosition beyond Int64
    "image-zero-frames.emd": {"O1": {}},                                   # F3: first image (3, 4, 0)
    "stream-bigendian-u2.emd": FRAMES,                                     # F4: >u2 stream (numba refuses)
    "unit-m-ulp-width2.7e-4-nx5.emd": {"O1": {}},                          # F5: a JSON-number pixel size
    "unit-m-ulp-width3.85e-4-nx5.emd": {"O1": {}},
    "unit-ym-ulp.emd": {"O1": {}},
    "unit-am-ulp.emd": {"O1": {}},
    "unit-fm-fermi.emd": {"O1": {}},                                       # F6: Pint's fermi
    "image-pixelunitx-null.emd": {"O1": {}},                               # F8: the first image's PixelUnitX null
    "detectorname-list.emd": {"O1": {}},                                   # a list DetectorName (Python's `in`)
    "stream-lzf.emd": {"O1": {}},                                          # LZF (step 3 A1)
}
NOT_RUN = {"overflow-grid-no-endframe.emd": "a (2^32, 2^32, 1) first image: RosettaSciIO reads its first frame whole"}
DEVIATIONS = {
    "stream-bigendian-u2.emd": ["reads", "a big-endian uint16 stream: numba's jitted fill refuses the non-native type; read here (A1)"],
    "unit-fm-fermi.emd": ["all", "'fm' is Pint's fermi: refused here (A1)"],
    "image-pixelunitx-null.emd": ["all", "the first image's PixelUnitX null: refused as the image path does (step 3; A1)"],
    "detectorname-list.emd": ["all", "a DetectorName that is not a string: refused (A1)"],
    "stream-lzf.emd": ["all", "an LZF-filtered stream: the shipped libhdf5 has no LZF filter (step 3 A1)"],
    "overflow-grid-no-endframe.emd": ["not-run", NOT_RUN["overflow-grid-no-endframe.emd"]],
}


def build(R, np, h5py, pint):
    files = []
    for name in sorted(FILES):
        rec = pins4.file_record(R, np, DIR / name, name, "refuter", FILES[name])
        for run in rec["runs"].values():   # numba's messages vary between runs past their first line
            if run["raises"]:
                run["raises"]["message"] = run["raises"]["message"].split("\n")[0]
        files.append(rec)
    for name in sorted(NOT_RUN):
        raw = (DIR / name).read_bytes()
        files.append({"set": "refuter", "path": name, "sha256": pins4.sha(raw), "bytes": len(raw),
                      "runs": {"O1": {"options": {}, "raises": {"type": "NotRun", "message": NOT_RUN[name]}, "signals": []}}})
    out = step1.header(np, h5py, pint, "step-4-refuter")
    out["generator"] = "tools/velox-spectrum-image/refuter_pins.py"
    out["versions"].update(pins4.require_stream_libraries())
    out["deviations"] = DEVIATIONS
    out["files"] = files
    return step1.dump(out)


def main():
    import h5py
    import numpy as np
    import pint
    R = step1.load_rsciio()
    a = build(R, np, h5py, pint)
    b = build(R, np, h5py, pint)
    if a != b:
        step1.die("two builds differ")
    OUT.write_text(a)
    print(f"spectrum-image refuter pins: {len(FILES) + len(NOT_RUN)} files -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    sys.exit(main())

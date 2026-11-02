#!/usr/bin/env python3
"""Pins RosettaSciIO's axes of the committed DM fixtures, for the scan pixel size of DM spectrum images and 4D scans (FormatoKit 0.11.0).

    References/venv/bin/python -I -B tools/dm-scan/pins.py
        writes Tests/FormatoDMTests/Fixtures/dm-scan-pins.json

For each fixture, `rsciio.digitalmicrograph.file_reader` (lazy) returns one dictionary per image object (thumbnails left out);
the file's order is recorded with each dictionary's title, array shape and every axis: name, size, scale and offset (with their
IEEE bits), units, navigate. The Swift test matches the objects of `DMFile` to these dictionaries by order and compares the
scan axes the kit exposes (`DM4EELSSpectrumImage.xAxis/yAxis`, `DM4EDSSpectrumImage.xAxis/yAxis`, the `DM4Datacube` axes) with
them exactly. Stops unless rsciio is the pinned install, NumPy 2.5.4; built twice, the outputs compared.
"""
import json
import logging
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VENV = ROOT / "References" / "venv"
CLONE = ROOT / "References" / "rosettasciio-049e7d70"
PIN = "049e7d7070e84779b499adaf3295beee9facb004"
FIXTURES = ROOT / "Tests" / "FormatoDMTests" / "Fixtures"
FILES = ["rsciio-EELS_SI.dm4", "demo-edx-tiny.dm4", "eels-planted.dm4", "acq-metadata/si-group.dm4", "acq-metadata/eds-full.dm4",
         "acq-metadata/eels-full.dm4", "acq-metadata/eels-orsay.dm4", "gather/detector-1.dm4", "gather/detector-10.dm4", "gather/detector-11.dm4"]


def bits(x):
    return struct.pack(">d", float(x)).hex()


def head():
    git = CLONE / ".git"
    ref = (git / "HEAD").read_text().strip()
    if ref.startswith("ref: "):
        p = git / ref[5:]
        if p.exists():
            return p.read_text().strip()
        for line in (git / "packed-refs").read_text().splitlines():
            if line.endswith(" " + ref[5:]):
                return line.split()[0]
    return ref


def build():
    import numpy as np
    import rsciio
    if np.__version__ != "2.5.4":
        sys.exit(f"dm-scan/pins.py: NumPy {np.__version__}")
    if VENV.resolve() not in Path(rsciio.__file__).resolve().parents:
        sys.exit("dm-scan/pins.py: rsciio is not the pinned install")
    if head() != PIN:
        sys.exit("dm-scan/pins.py: the clone is not at the pin")
    from rsciio.digitalmicrograph import file_reader
    out = []
    for name in FILES:
        rec = {"file": name, "signals": [], "raises": None}
        try:
            for d in file_reader(str(FIXTURES / name), lazy=True):
                rec["signals"].append({
                    "title": d["metadata"]["General"].get("title", ""),
                    "signal_type": d["metadata"]["Signal"].get("signal_type", ""),
                    "shape": [int(n) for n in d["data"].shape],
                    "axes": [{"name": a.get("name"), "size": int(a["size"]), "scale": float(a["scale"]), "scale_bits": bits(a["scale"]),
                              "offset": float(a["offset"]), "offset_bits": bits(a["offset"]), "units": a.get("units"),
                              "navigate": bool(a.get("navigate"))} for a in d["axes"]]})
        except Exception as e:
            rec["raises"] = type(e).__name__
        out.append(rec)
    return json.dumps({"generator": "tools/dm-scan/pins.py", "reference": f"RosettaSciIO {PIN} (rsciio.digitalmicrograph.file_reader, lazy)",
                       "versions": {"numpy": np.__version__}, "files": out}, indent=1, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"


def main():
    logging.disable(logging.CRITICAL)
    a, b = build(), build()
    if a != b:
        sys.exit("dm-scan/pins.py: two builds differ")
    (FIXTURES / "dm-scan-pins.json").write_text(a, encoding="utf-8")
    d = json.loads(a)
    for f in d["files"]:
        print(f["file"], f["raises"] or [(s["shape"], [(x["name"], x["units"], x["navigate"]) for x in s["axes"]]) for s in f["signals"]][:3])


if __name__ == "__main__":
    main()

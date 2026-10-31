#!/usr/bin/env python3
"""A Velox file whose images have PixelSize but no PixelUnitX (FormatoKit 0.11.0, AcquisitionMetadata.velox pixelSize).

    References/venv/bin/python -I -B tools/acq-metadata/no_unit.py
        copies Tests/FormatoEMDTests/Fixtures/acq-metadata/velox-acquisition.emd, deletes BinaryResult.PixelUnitX from every
        image's metadata, writes velox-no-unit.emd and velox-no-unit.pin.json (RosettaSciIO 049e7d70's axes for it:
        `.get("PixelUnitX", "")` gives an empty unit and keeps the scale, so the pixel size is kept with units "").
"""
import json
import shutil
from pathlib import Path

import h5py
import numpy as np
from rsciio.emd import file_reader

DIR = Path(__file__).resolve().parents[2] / "Tests/FormatoEMDTests/Fixtures/acq-metadata"


def main():
    dst = DIR / "velox-no-unit.emd"
    shutil.copy(DIR / "velox-acquisition.emd", dst)
    with h5py.File(dst, "r+") as f:
        for g in f["Data/Image"].values():
            md = g["Metadata"]
            doc = json.loads(md[:, 0].tobytes().rstrip(b"\0"))
            del doc["BinaryResult"]["PixelUnitX"]
            raw = json.dumps(doc).encode()
            arr = np.zeros(md.shape, md.dtype)
            arr[: len(raw), 0] = np.frombuffer(raw, np.uint8)
            md[...] = arr
    pins = []
    for s in file_reader(str(dst)):
        pins.append([{k: a[k] for k in ("name", "scale", "offset", "units", "size")} for a in s["axes"][-2:]])
    (DIR / "velox-no-unit.pin.json").write_text(json.dumps({"reference": "RosettaSciIO 049e7d70 rsciio.emd", "axes": pins}, indent=1) + "\n")
    print(dst, len(pins), "signals")


if __name__ == "__main__":
    main()

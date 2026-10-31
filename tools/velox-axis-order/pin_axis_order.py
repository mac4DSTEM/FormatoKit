#!/usr/bin/env python3
"""RosettaSciIO 049e7d70's energy axis for the planted axis-order file (pinned for SpectroKit at 0.0.3).

    References/rsciio-venv/bin/python -I -B tools/velox-axis-order/pin_axis_order.py

Reads Tests/FormatoEMDTests/Fixtures/velox-stream-axis-order.emd (SpectroKit c5a9a5e, sha256 checked) through RosettaSciIO's
own stream path: `rsciio.utils.hdf5._parse_sub_data_group_metadata` on the first stream (name order, as `_read_spectrum_stream`
takes `streams[0]`; `self.original_metadata` adds only Displays/Operations/SharedProperties/Features, none here) and the
reader's `_get_dispersion_offset` (`_emd_velox.py:866-876`) with rebin_energy 1. `rsciio.emd.file_reader` itself stops
earlier on this planted file (KeyError 'Displays' in `_parse_image_display`, which only maps image titles). Prints JSON: the
axis and the detector keys in the order json.loads keeps them (the file's order). Copied into
Tests/FormatoEMDTests/Fixtures/velox-stream-axis-order.pin.json before the Swift fix.
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
PATH = os.path.join(REPO, "Tests/FormatoEMDTests/Fixtures/velox-stream-axis-order.emd")
SHA = "5fb8100f76e030c83a0dd88e7df98c33ce70151e8a8b36469ce7f8ad094dae3b"

sys.path.insert(0, os.path.join(REPO, "References/rosettasciio-049e7d70"))
import h5py  # noqa: E402
import rsciio  # noqa: E402
from rsciio.emd._emd_velox import FeiEMDReader  # noqa: E402
from rsciio.utils.hdf5 import _get_keys_from_group, _parse_sub_data_group_metadata  # noqa: E402

with open(PATH, "rb") as fh:
    assert hashlib.sha256(fh.read()).hexdigest() == SHA, "not SpectroKit's planted file"
reader = FeiEMDReader.__new__(FeiEMDReader)
reader.rebin_energy = 1
with h5py.File(PATH, "r") as f:
    group = f["Data/SpectrumStream"]
    first = _get_keys_from_group(group)[0]
    om = _parse_sub_data_group_metadata(group[first])
dispersion, offset, units = reader._get_dispersion_offset(om)
print(json.dumps({"rsciio": "049e7d7070e84779b499adaf3295beee9facb004", "file": os.path.basename(PATH), "sha256": SHA,
                  "stream": first, "dispersion_keV": dispersion, "offset_keV": offset, "units": units,
                  "binary_result_detector": om["BinaryResult"]["Detector"],
                  "detector_keys_file_order": list(om["Detectors"].keys())}, indent=1))

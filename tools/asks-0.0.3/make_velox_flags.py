#!/usr/bin/env python3
"""A planted Velox spectrum-stream file for the two reader flags made public in 0.0.3 (SpectroKit's ask, 2026-10-15).

    References/rsciio-venv/bin/python -I -B tools/asks-0.0.3/make_velox_flags.py [--out DIR]

writes DIR/velox-flags-planted.emd (DIR defaults to Tests/FormatoEMDTests/Fixtures). Layout as SpectroKit's
tools/edx-stages/make_velox_streams.py (c5a9a5e), which copies the Velox structure RosettaSciIO reads:
  Version                                   {"version": "11", "format": "Velox"}
  Data/SpectrumStream/<id>/Data             uint16 (n, 1): 65535 ends a pixel
  Data/SpectrumStream/<id>/FrameLocationTable   uint64 (frames, 1)
  Data/SpectrumStream/<id>/Metadata         uint8 (8192, 2): column 0 the JSON, column 1 a decoy
  Data/SpectrumStream/<id>/AcquisitionSettings  {"bincount": "16", "StreamEncoding": "uint16"}
  Data/SpectrumImage/si00/SpectrumImageSettings {"startFramePosition": "1", "endFramePosition": "2"}
  Data/Image/img0/{Data (2, 2, 2) uint16, Metadata}

THE TRUTH IS THE LAYOUT (no reader consulted):
  grid 2 x 2, 16 channels, 2 frames (endFramePosition 2);
  stream "s0" (SuperXG21): both frames complete, pixel p of frame f holds one event at channel 4 * f + p (8 events);
  stream "s1" (SuperXG22): frame 0 complete as s0's, then frame 1 STOPS after pixel 1 (pixels 0 and 1 of frame 1 only,
    its last word a marker; 6 events). The streams end in different places: streamsAgreeOnCoverage is FALSE.
  Both analytical detectors: Dispersion 10 eV, OffsetEnergy -100 eV: energyCalibrationAgrees is TRUE.
  streamCount 2; stream ids "s0", "s1" (name order). Total counts 8 + 6 = 14.
"""
import argparse
import json
import os

import h5py
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
ROWS, MARK, NY, NX, CH = 8192, 65535, 2, 2, 16


def metadata(detector, decoy=False):
    dets = {"Detector-0": {"DetectorName": "HAADF", "DetectorType": "ScanningDetector", "Enabled": "true"}}
    for i, name in ((1, "SuperXG21"), (2, "SuperXG22")):
        dets[f"Detector-{i}"] = {"DetectorName": ("DECOY" if decoy else "") + name, "DetectorType": "AnalyticalDetector",
                                 "Enabled": "true", "Inserted": "true", "ElevationAngle": "0.5", "AzimuthAngle": "1.0",
                                 "CollectionAngle": "0.225", "Dispersion": "13" if decoy else "10",
                                 "OffsetEnergy": "-777" if decoy else "-100", "RealTime": "0", "LiveTime": "0"}
    doc = {"Detectors": dets, "BinaryResult": {"Detector": ("DECOY" if decoy else "") + detector, "DetectorIndex": "1"},
           "Scan": {"ScanSize": {"width": str(NX), "height": str(NY)},
                    "ScanArea": {"left": "0", "top": "0", "right": "1", "bottom": "1"}, "DwellTime": "1e-5", "FrameTime": "0.001"},
           "Optics": {"AccelerationVoltage": "200000"}}
    raw = json.dumps(doc).encode("utf-8")
    assert len(raw) < ROWS
    return np.frombuffer(raw + b"\0" * (ROWS - len(raw)), dtype=np.uint8)


def stream_words(frames_pixels):
    words, starts = [], []
    for f, pixels in enumerate(frames_pixels):
        starts.append(len(words))
        for p in range(pixels):
            words += [4 * f + p, MARK]
    return words, starts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(REPO, "Tests/FormatoEMDTests/Fixtures"))
    path = os.path.join(ap.parse_args().out, "velox-flags-planted.emd")
    with h5py.File(path, "w") as f:
        f.create_dataset("Version", data=[json.dumps({"version": "11", "format": "Velox"})], dtype=h5py.string_dtype())
        for sid, det, frames_pixels in (("s0", "SuperXG21", (4, 4)), ("s1", "SuperXG22", (4, 2))):
            words, starts = stream_words(frames_pixels)
            g = f.create_group(f"Data/SpectrumStream/{sid}")
            g.create_dataset("Data", data=np.array(words, dtype="<u2").reshape(-1, 1), track_times=False)
            g.create_dataset("FrameLocationTable", data=np.array(starts, dtype="<u8").reshape(-1, 1), track_times=False)
            g.create_dataset("Metadata", data=np.stack([metadata(det), metadata(det, decoy=True)], axis=1), track_times=False)
            g.create_dataset("AcquisitionSettings", data=[json.dumps({"bincount": str(CH), "StreamEncoding": "uint16"})],
                             dtype=h5py.string_dtype())
        s = f.create_group("Data/SpectrumImage/si00")
        s.create_dataset("SpectrumImageSettings", data=[json.dumps({"startFramePosition": "1", "endFramePosition": "2"})],
                         dtype=h5py.string_dtype())
        img = f.create_group("Data/Image/img0")
        img.create_dataset("Data", data=(np.arange(8) * 37 + 11).astype("<u2").reshape(NY, NX, 2), track_times=False)
        img.create_dataset("Metadata", data=np.stack([metadata("HAADF"), metadata("HAADF", decoy=True)], axis=1),
                           track_times=False)
    print(path)


if __name__ == "__main__":
    main()

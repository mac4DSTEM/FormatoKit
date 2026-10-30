#!/usr/bin/env python3
"""A planted Velox EELS spectrum image with its optics, and what RosettaSciIO and pyEELSMODEL read from it.

    PYEELSMODEL=<clone of github.com/joverbee/pyEELSMODEL at eed9f072> \
    References/rsciio-venv/bin/python -I -B tools/velox-eels/pins.py
        writes Tests/FormatoEMDTests/Fixtures/eels/si-eels-optics.emd and velox-eels-pins.json

The file is built with the helpers of tools/step-4/make_velox_si.py (h5py, no data of the owner's): a Velox 11 file with one
image, a `Data/SpectrumImage` group, one spectrum stream and two EELS spectrum images (`Data/EelsSpectrumImage/e1`, `e2`),
as a Zebra detector writes one per energy range. Each EELS group's Metadata states `Optics.AccelerationVoltage`,
`Optics.BeamConvergence` and the flat `CustomProperties["EnergyFilter.CollectionAngleRange.Begin"/".End"]` entries of
RosettaSciIO's public `velox_EELS_EDS.zip` file; the two groups state different collection ranges, and the SpectrumImage
group states none, so a reader that takes them from the wrong group fails.

The pins:
- RosettaSciIO 049e7d70 (`rsciio.emd.file_reader(select_type="spectrum_image")`): its EELS dictionaries carry only the title
  and file name and no mapping (the script asserts it), and the beam energy its mapping gives the EDS signal of the same file.
- pyEELSMODEL eed9f072 (`pyEELSMODEL/io_tools/emd_reader.py` `open_emd`, loaded from the clone by path): per EELS group, in its
  order, `beam_voltage` (V), `collection_angle_begin` and `collection_angle_end` (rad), as it reads them.
- The planted `Optics.BeamConvergence` (rad), typed here: no published reader reads it.
Built twice in the process, the outputs compared. Needs sparse and numba in the venv (step 4).
"""
import importlib.util
import json
import logging
import os
import shutil
import sys
import tempfile
import warnings
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Tests" / "FormatoEMDTests" / "Fixtures" / "eels"
NAME = "si-eels-optics.emd"
PYEELSMODEL_PIN = "eed9f0721d5b47788c00c8f81509f0e3006df6f4"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


step1 = module("step1_pins", ROOT / "tools" / "step-1" / "pins.py")
M = module("make_velox_si", ROOT / "tools" / "step-4" / "make_velox_si.py")

VOLTS = "300000"
CONVERGENCE = "0.02143377827928146"
# (group, energy offset eV, collection range begin and end in rad): e1 is the public file's range, e2 a wider one.
EELS = [("e1", -21.5026, "0", "0.0033435492928249842"), ("e2", 480.00000000000006, "0.0005", "0.0125")]


def pyeelsmodel_reader():
    clone = os.environ.get("PYEELSMODEL")
    if not clone:
        sys.exit("velox-eels/pins.py: set PYEELSMODEL to a clone of pyEELSMODEL at " + PYEELSMODEL_PIN)
    head = (Path(clone) / ".git" / "HEAD").read_text().strip()
    if head.startswith("ref: "):
        head = (Path(clone) / ".git" / head[5:]).read_text().strip()
    if head != PYEELSMODEL_PIN:
        sys.exit(f"velox-eels/pins.py: pyEELSMODEL is at {head}, not {PYEELSMODEL_PIN}")
    return module("pyeelsmodel_emd_reader", Path(clone) / "pyEELSMODEL" / "io_tools" / "emd_reader.py")


def eels_doc(begin, end):
    d = M.base_doc(M.detectors_doc([("Detector-0", "HAADF", None, None)]), "Zebra", None, (3, 2), (0, 0, 1, 1),
                   pixel=("5e-9", "4e-9"), offset=("1e-8", "-2e-8"), volts=VOLTS)
    d["Optics"]["BeamConvergence"] = CONVERGENCE
    d["CustomProperties"]["EnergyFilter.CollectionAngleRange.Begin"] = {"type": "double", "value": begin}
    d["CustomProperties"]["EnergyFilter.CollectionAngleRange.End"] = {"type": "double", "value": end}
    return d


def write(path):
    rng = np.random.default_rng([20261030, 10])
    ny, nx = 2, 3
    pl = M.Planted(ny, nx, 1, 1, [8])
    for p in range(ny * nx):
        pl.add(0, 0, p, p % 8, p + 1)
    pl.number_of_frames = 1
    with M.new_file(str(path), 11, "v11") as f:
        f.create_group("Features").create_group("SIFeature")   # pyEELSMODEL reads EELS only where this group is
        area = (0, 0, 1, 1)
        M.add_image(f, "img0", np.arange(ny * nx, dtype=np.uint16).reshape(ny, nx, 1), M.image_doc((nx, ny), area, volts=VOLTS))
        si = M.base_doc(M.detectors_doc([("Detector-0", "HAADF", None, None)]), "HAADF", "0", (nx, ny), area,
                        pixel=("5e-9", "4e-9"), offset=("1e-8", "-2e-8"), volts=VOLTS)
        M.add_si_settings(f, {"startFramePosition": "1", "endFramePosition": "1"}, md=si)
        for k, (name, offset, begin, end) in enumerate(EELS):
            cube = (np.arange(nx * 5 * ny, dtype=np.uint16) + 100 * k).reshape(nx, 5, ny)   # stored (x, E, y)
            g = f.create_group(f"Data/EelsSpectrumImage/{name}")
            g.create_dataset("Data", data=cube, chunks=cube.shape, track_times=False)   # chunked, as Velox writes it (pyEELSMODEL iterates chunks)
            g.create_dataset("AcquisitionMetadata", data=M.metadata_column(
                {"Data": {"offset": offset, "dispersion": 0.1692, "exposureTime": 0.004}, "Type": "EelsAcquisitionMetadata"}), track_times=False)
            g.create_dataset("Metadata", data=M.metadata_column(eels_doc(begin, end)), track_times=False)
        det = M.detectors_doc([("Detector-0", "HAADF", None, None), ("Detector-1", "SuperXG11", "20", "-1000")])
        M.add_stream(f, "s0", pl.encode(0, rng), 8, "uint16", M.base_doc(det, "SuperXG1", "1", (nx, ny), area, volts=VOLTS))


def build(out, pyeels):
    warnings.simplefilter("ignore")
    logging.disable(logging.CRITICAL)
    R = step1.load_rsciio()
    out.mkdir(parents=True, exist_ok=True)
    write(out / NAME)
    sigs = R["emd"].file_reader(str(out / NAME), lazy=False, select_type="spectrum_image")
    eels = [s for s in sigs if s["metadata"].get("Signal", {}).get("signal_type") == "EELS"]
    eds = [s for s in sigs if s["metadata"].get("Signal", {}).get("signal_type") == "EDS_TEM"]
    assert len(eels) == len(EELS) and len(eds) == 1, [s["metadata"] for s in sigs]
    for s in eels:
        assert "mapping" not in s, "RosettaSciIO maps something for an EELS spectrum image"
        assert set(s["metadata"]) == {"General", "Signal"}, s["metadata"]
        assert "Acquisition_instrument" not in s["metadata"], s["metadata"]
    mapped = step1.apply_mapping(eds[0], ("Acquisition_instrument.TEM.beam_energy",))
    energy, source = mapped["Acquisition_instrument.TEM.beam_energy"]

    with open(os.devnull, "w") as quiet:
        stdout, sys.stdout = sys.stdout, quiet
        try:
            _, cubes = pyeels.open_emd(str(out / NAME))
        finally:
            sys.stdout = stdout
    assert len(cubes) == len(EELS), cubes
    pins = {
        "generator": "tools/velox-eels/pins.py",
        "reference": f"RosettaSciIO {step1.PIN} (rsciio.emd.file_reader, select_type=spectrum_image); "
                     f"pyEELSMODEL {PYEELSMODEL_PIN} (io_tools/emd_reader.py open_emd)",
        "file": NAME,
        "rosettasciio": {"eels_signals": len(eels), "eds_beam_energy_kv": {"value": float(energy), "bits": step1.bits(energy), "source": source}},
        "pyeelsmodel": [{"beam_voltage_v": int(c["beam_voltage"]),
                         "collection_angle_begin_rad": {"value": float(c["collection_angle_begin"]), "bits": step1.bits(c["collection_angle_begin"])},
                         "collection_angle_end_rad": {"value": float(c["collection_angle_end"]), "bits": step1.bits(c["collection_angle_end"])}}
                        for c in cubes],
        "planted": {"groups": [name for name, *_ in EELS], "beam_convergence_rad": float(CONVERGENCE),
                    "energy_offsets_ev": [offset for _, offset, *_ in EELS]},
        "rosettasciio_eels_energy_offsets_ev": [float(s["axes"][-1]["offset"]) for s in eels],
    }
    return json.dumps(pins, indent=1, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"


def main():
    pyeels = pyeelsmodel_reader()
    with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
        first, second = build(Path(a), pyeels), build(Path(b), pyeels)
        if first != second:
            sys.exit("velox-eels/pins.py: two builds differ")
        if (Path(a) / NAME).read_bytes() != (Path(b) / NAME).read_bytes():
            sys.exit(f"velox-eels/pins.py: {NAME} differs between two builds")
        OUT.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(a) / NAME, OUT / NAME)
        (OUT / "velox-eels-pins.json").write_text(first, encoding="utf-8")
    print(first)


if __name__ == "__main__":
    main()

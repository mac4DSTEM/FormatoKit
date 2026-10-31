#!/usr/bin/env python3
"""Planted Velox single-spectrum files for `Sample.elements`, the four file-level metadata groups and the segment times.

    HYPERSPY_SITE_PACKAGES=<site-packages of a HyperSpy 2.4.0 install> \
    References/rsciio-venv/bin/python -I -B tools/velox-elements/pins.py

writes Tests/FormatoEMDTests/Fixtures/elements/*.emd and Tests/FormatoEMDTests/Fixtures/elements/velox-elements-pins.json.

Every file is a Velox `Spectrum` file (no `Data/Image`), built with the helpers of tools/velox-spectrum/pins.py, read by
RosettaSciIO 049e7d70 (`rsciio.emd.file_reader(select_type="single_spectrum")`). `Sample.elements` is a HyperSpy step: RosettaSciIO
returns `_convert_element_list` in its `mapping`, and that function indexes `d.keys()[0]`, which only HyperSpy's
`DictionaryTreeBrowser` allows (its `keys()` is a sorted list of the slugified keys). So the mapping is applied here with HyperSpy's
own class, in the loop of `hyperspy/io.py` `dict2signal` (`opattr in original_metadata`, `get_item`, the function, `set_item` when
not None), on an `original_metadata` built as `BaseSignal` builds it (`DictionaryTreeBrowser().add_dictionary(...)`). The class is
imported from HYPERSPY_SITE_PACKAGES, appended after the venv's own packages, so RosettaSciIO and numpy stay the venv's.

Per file: RosettaSciIO's exception, or per spectrum the elements (a list, absent when the mapping does not apply, or the exception
the mapping raises: HyperSpy's `load` raises it too), `BinaryResult.Detector` and every `Detectors` entry of the spectrum's
`original_metadata` in written order (name, type, `Enabled`, `float()` of `LiveTime` and `RealTime` with their bits). RosettaSciIO
maps no live or real time for these files: their spectra hold no `DetectorMetadata` (asserted).
Built twice in the process, the outputs compared.
"""
import hashlib
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
OUT = ROOT / "Tests" / "FormatoEMDTests" / "Fixtures" / "elements"
HYPERSPY_VERSION = "2.4.0"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


step1 = module("step1_pins", ROOT / "tools" / "dm-velox-pins" / "pins.py")
SP = module("velox_spectrum_pins", ROOT / "tools" / "velox-spectrum" / "pins.py")


def tree_class():
    site = os.environ.get("HYPERSPY_SITE_PACKAGES")
    if not site:
        sys.exit("velox-elements/pins.py: set HYPERSPY_SITE_PACKAGES to the site-packages of a HyperSpy " + HYPERSPY_VERSION + " install")
    sys.path.append(site)
    from importlib.metadata import version
    import hyperspy
    if Path(hyperspy.__file__).resolve().parents[1] != Path(site).resolve():
        sys.exit(f"velox-elements/pins.py: hyperspy imported from {hyperspy.__file__}, not from {site}")
    found = version("hyperspy")
    if found != HYPERSPY_VERSION:
        sys.exit(f"velox-elements/pins.py: HyperSpy is {found}, not {HYPERSPY_VERSION}")
    from hyperspy.misc._utils import DictionaryTreeBrowser
    return DictionaryTreeBrowser


V11_SETTINGS = "SharedProperties/EDSSpectrumQuantificationSettings"
V4_SETTINGS = "Operations/ImageQuantificationOperation"


def times_doc(names_times, binary):
    """A spectrum's Detectors: one scanning detector, then X-ray segments (name, live, real, enabled) as Velox 4 to 13 write them."""
    det = {"Detector-0": {"DetectorName": "HAADF", "DetectorType": "ScanningDetector"}}
    for i, (name, live, real, enabled) in enumerate(names_times, start=1):
        d = {"DetectorName": name, "DetectorType": "AnalyticalDetector", "Dispersion": "5", "OffsetEnergy": "-480",
             "PulseProcessTime": "3.0000000000000001e-006", "RealTime": real, "LiveTime": live}
        if enabled is not None:
            d["Enabled"] = enabled
        det[f"Detector-{i}"] = d
    return SP.spectrum_doc(Detectors=det, BinaryResult={"Detector": binary, "DetectorIndex": 1})


FOUR = [("SuperXG21", "10.061437738684702", "11.36485629375", None), ("SuperXG22", "10.061437738684702", "11.36485629375", None),
        ("SuperXG23", "10.061437738684702", "11.36485629375", None), ("SuperXG24", "10.061437738684702", "11.36485629375", None)]
SEGMENTS = [("SuperXG21", "27.582455349747178", "32.768026849999998", None), ("SuperXG22", "27.819320345368695", "32.767988875", None),
            ("SuperXG23", "27.906697271813595", "32.767735250000001", None), ("SuperXG24", "27.700038087004355", "32.768037800000002", None)]
ULTRA = [("UltraX1", "2.9071471999999998", "2.9071471999999998", "true"), ("UltraX2", "2.9071471999999998", "2.9071471999999998", "true"),
         ("UltraX3", "2.9071471999999998", "2.9071471999999998", "false"), ("UltraX4", "3.25", "3.5", "true")]


def write_group(f, path, entries):
    """`path` a group of variable-length JSON strings, one per entry name (a value that is a str is written as is)."""
    g = f.require_group(path)
    for name, doc in entries:
        text = doc if isinstance(doc, str) else json.dumps(doc)
        g.create_dataset(name, data=np.array([text], dtype=object), dtype=SP.S, track_times=False)


def build(out):
    ramp = np.arange(12, dtype=np.uint32).reshape(12, 1) * 3 + 2

    def make(name, version, settings=None, extra=None, doc=None, spectra=1):
        with SP.new_file(str(out / f"{name}.emd"), version) as f:
            for k in range(spectra):
                SP.add_spectrum(f, f"s{k}", ramp + k, doc if doc is not None else times_doc(FOUR, "SuperXG2"))
            if settings is not None:
                write_group(f, settings[0], settings[1])
            for path, entries in (extra or []):
                write_group(f, path, entries)

    # Velox 4: elements in Operations, four segments named by "SuperXG2", every one matching. The public fei_emd_spectrum.emd's times.
    make("el-v4", 4, (V4_SETTINGS, [("80e138836ebd4b7aad5be7d3dd071f47", {"elementSelection": ["41", "8"], "kind": "q"})]),
         extra=[("Features/SIFeature", [("f1", {"x": 1})]), ("Displays/Other", [("d1", {"y": 2})])])
    # Velox 6: one segment named, the others state other times; elements stored as numbers.
    make("el-v6-one-segment", 6, (V4_SETTINGS, [("fab3", {"elementSelection": [26, 27.9, "+8", " 1_4 "]})]),
         doc=times_doc(SEGMENTS, "SuperXG24"))
    # Velox 11: elements in SharedProperties; two entries, the first in HyperSpy's sorted order taken ("Number_0b..." before "a2...").
    make("el-v11-two-settings", 11, (V11_SETTINGS, [("a24a64ef30da49beb12dabaa598d9f16", {"elementSelection": ["6", "8"]}),
                                                    ("0b4c", {"elementSelection": ["20", "29", "1", "119"]})]),
         extra=[("Operations/ImageQuantificationOperation", [("zz", {"elementSelection": ["79"]})])], spectra=2)
    # The slugified order differs from the raw one: "B111" sorts before "Number_0b4c" (raw: "0b4c" first); "_a" is left out of
    # HyperSpy's keys(); the inner key "element-Selection" reads as elementSelection.
    make("el-slug-order", 11, (V11_SETTINGS, [("0b4c", {"elementSelection": ["8"]}), ("B111", {"element-Selection": ["26"]}),
                                              ("_a", {"elementSelection": ["1"]})]))
    # Velox 13: a disabled segment, and a segment the binary result does not name ("UltraX4" holds "UltraX"; all four match).
    make("el-v13-disabled", 13, (V11_SETTINGS, [("34d7", {"elementSelection": [8, 26, 27]})]), doc=times_doc(ULTRA, "UltraX"))
    # No elementSelection: the mapping gives []; an empty string gives [] too (iterating "" in Python).
    make("el-empty-selection", 11, (V11_SETTINGS, [("0ea5", {"other": "x"})]))
    make("el-empty-string", 4, (V4_SETTINGS, [("80e1", {"elementSelection": ""})]))
    make("el-digit-string", 4, (V4_SETTINGS, [("80e1", {"elementSelection": "82"})]))
    # The version picks the group: a Velox 11 file with Operations only maps nothing; a file with no group maps nothing.
    make("el-v11-operations-only", 11, extra=[(V4_SETTINGS, [("80e1", {"elementSelection": ["8"]})])])
    make("el-none", 11)
    # Refusals (HyperSpy raises in the mapping, or RosettaSciIO raises while reading the groups).
    make("el-bad-number", 11, (V11_SETTINGS, [("e1", {"elementSelection": ["8", "abc"]})]))
    make("el-z-120", 11, (V11_SETTINGS, [("e1", {"elementSelection": ["120"]})]))
    make("el-z-0", 11, (V11_SETTINGS, [("e1", {"elementSelection": [0]})]))
    make("el-null-selection", 11, (V11_SETTINGS, [("e1", {"elementSelection": None})]))
    make("el-settings-list", 11, extra=[("SharedProperties", [("EDSSpectrumQuantificationSettings", ["8"])])])
    make("el-entry-not-object", 11, (V11_SETTINGS, [("e1", ["8"])]))
    make("el-bad-json", 11, (V11_SETTINGS, [("e1", {"elementSelection": ["8"]})]), extra=[("Features/SIFeature", [("f1", "{not json")])])
    with SP.new_file(str(out / "el-empty-group.emd"), 11) as f:
        SP.add_spectrum(f, "s0", ramp, times_doc(FOUR, "SuperXG2"))
        f.require_group(V11_SETTINGS)
    with SP.new_file(str(out / "el-version-text.emd"), 11) as f:   # int("11.0") raises in _get_mapping
        del f["Version"]
        SP.write_json(f, "Version", {"version": "11.0", "format": "Velox"})
        SP.add_spectrum(f, "s0", ramp, times_doc(FOUR, "SuperXG2"))
    with SP.new_file(str(out / "el-no-version-key.emd"), 11) as f:
        del f["Version"]
        SP.write_json(f, "Version", {"format": "Velox"})
        SP.add_spectrum(f, "s0", ramp, times_doc(FOUR, "SuperXG2"))


def float_record(raw):
    if raw is None:
        return None
    return {"value": step1.jfloat(float(raw)), "bits": step1.bits(float(raw))}


def record(path, tree):
    from rsciio.emd import file_reader
    try:
        dicts = file_reader(str(path), select_type="single_spectrum", lazy=False)
    except Exception as e:  # noqa: BLE001
        return {"raises": type(e).__name__}
    out = []
    for d in dicts:
        om = d["original_metadata"]
        assert "DetectorMetadata" not in om, path
        rec = {"binary_result_detector": om.get("BinaryResult", {}).get("Detector"),
               "detectors": [{"key": k, "name": v.get("DetectorName"), "type": v.get("DetectorType"), "enabled": v.get("Enabled"),
                              "live_time_s": float_record(v.get("LiveTime")), "real_time_s": float_record(v.get("RealTime"))}
                             for k, v in om["Detectors"].items()]}
        browser = tree()
        browser.add_dictionary(om)
        md = tree()
        try:   # hyperspy/io.py dict2signal, the mapping loop
            for opattr, (mpattr, function) in d["mapping"].items():
                if opattr in browser:
                    value = browser.get_item(opattr)
                    if function is not None:
                        value = function(value)
                    if value is not None:
                        md.set_item(mpattr, value)
        except Exception as e:  # noqa: BLE001
            rec["elements"] = {"raises": type(e).__name__}
        else:
            if md.has_item("Sample.elements"):
                rec["elements"] = {"value": list(md.get_item("Sample.elements"))}
        out.append(rec)
    return out


def public(tree):
    """RosettaSciIO's public Velox files with single spectra (tools/velox-spectrum/pins.py's list), unzipped into a fresh folder:
    the elements of each spectrum. These files are SpectrumStream or Spectrum files; sparse is in the venv."""
    import zipfile
    data = step1.CLONE / "rsciio" / "tests" / "data" / "emd"
    out = {}
    with tempfile.TemporaryDirectory() as tmp:
        for zname in sorted({z for z, _ in SP.PUBLIC}):
            zipfile.ZipFile(data / zname).extractall(Path(tmp) / zname)
        for zname, fname in SP.PUBLIC:
            recs = record(Path(tmp) / zname / fname, tree)
            out[f"{zname}/{fname}"] = recs if isinstance(recs, dict) else [{"elements": r.get("elements")} for r in recs]
    return out


def run(out, tree):
    warnings.simplefilter("ignore")
    logging.disable(logging.CRITICAL)
    step1.load_rsciio()
    out.mkdir(parents=True, exist_ok=True)
    build(out)
    names = sorted(p.stem for p in out.glob("*.emd"))
    pins = {"generator": "tools/velox-elements/pins.py",
            "public": public(tree),
            "reference": f"RosettaSciIO {step1.PIN} (rsciio.emd.file_reader, select_type=single_spectrum); the mapping applied with "
                         f"HyperSpy {HYPERSPY_VERSION}'s DictionaryTreeBrowser as hyperspy/io.py dict2signal applies it",
            "files": {n: record(out / f"{n}.emd", tree) for n in names},
            "sha256": {n: hashlib.sha256((out / f"{n}.emd").read_bytes()).hexdigest() for n in names}}
    return json.dumps(pins, indent=1, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"


def main():
    tree = tree_class()
    with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
        first, second = run(Path(a), tree), run(Path(b), tree)
        if first != second:
            sys.exit("velox-elements/pins.py: two builds differ")
        if OUT.exists():
            shutil.rmtree(OUT)
        shutil.copytree(a, OUT)
        (OUT / "velox-elements-pins.json").write_text(first, encoding="utf-8")
    print("wrote", OUT / "velox-elements-pins.json")


if __name__ == "__main__":
    main()

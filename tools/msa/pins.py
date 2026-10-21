#!/usr/bin/env python3
"""Pins RosettaSciIO's MSA plugin for FormatoMSA (FormatoKit 0.9.0).

    References/rsciio-venv/bin/python -I -B tools/msa/pins.py

writes Tests/FormatoMSATests/Fixtures/msa-pins.json and copies RosettaSciIO's 11 public MSA test files (GPL-3.0-or-later) into
Tests/FormatoMSATests/Fixtures/public/. READ: for every file and every planted text, `rsciio.msa.file_reader` (a fresh module each time:
the writer rewrites the module-level keyword table for an SEM signal): its exception, or the data (float64 bit patterns), the axis,
the metadata flattened to dotted paths in the order DTBox returns them, and `original_metadata` as ordered [key, value] pairs.
WRITE: for each signal (the public files read by rsciio, and synthetic signals typed here) `file_writer` with format Y, XY and None:
the file's bytes (base64). The header comment names the version, which is the venv's (the FormatoKit test passes it as `creator`).
"""
import base64
import importlib
import json
import os
import shutil
import struct
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(REPO, "References", "rosettasciio-049e7d70", "rsciio", "tests", "data", "msa")
FIX = os.path.join(REPO, "Tests", "FormatoMSATests", "Fixtures")


def fresh():
    import rsciio.msa._api as api
    return importlib.reload(api)


def bits(x):
    return struct.pack("<d", float(x)).hex()


def flatten(d, prefix=""):
    out = []
    for k, v in d.items():
        if isinstance(v, dict):
            out += flatten(v, prefix + k + ".")
        else:
            out.append([prefix + k, v])
    return out


def enc(v):
    if v is None:
        return None
    if isinstance(v, str):
        return {"s": v}
    if isinstance(v, (int, float, np.generic)):
        return {"f": bits(v), "int": isinstance(v, (int, np.integer)) and not isinstance(v, bool)}
    return {"other": repr(v)}


def read_record(path):
    api = fresh()
    try:
        d = api.file_reader(path)[0]
    except Exception as e:  # noqa: BLE001
        return {"raises": type(e).__name__}
    ax = d["axes"][0]
    return {
        "data": [bits(x) for x in d["data"]],
        "axis": {k: (enc(v) if k in ("scale", "offset") else v) for k, v in ax.items()},
        "metadata": [[k, enc(v)] for k, v in flatten(d["metadata"])],
        "original": [[k, enc(v)] for k, v in d["original_metadata"].items()],
    }


HEADER = "#FORMAT      : EMSA/MAS Spectral Data File\n#VERSION     : 1.0\n"


def doc(*lines, data=("1, 2", "3, 4"), datatype="Y", npoints=4, tail=True):
    h = HEADER + "".join(l + "\n" for l in lines)
    if datatype is not None:
        h += f"#DATATYPE    : {datatype}\n"
    h += "#SPECTRUM    : Spectral Data Starts Here\n" + "".join(d + "\n" for d in data)
    if tail:
        h += "#ENDOFDATA   : End Of Data and File\n"
    return h


PLANTED = {
    "basic-units-suffix": doc("#TITLE       : A spectrum", "#BEAMKV -kV   : 200.", "#AZIMANGLE-dg: 90.", "#XPERCHAN    : 0.5", "#OFFSET      : -10", "#XUNITS      : eV", "#XLABEL      : Energy loss"),
    "two-dashes": doc("#FOO-BAR-BAZ  : 1"),
    "dash-in-title": doc("#TITLE       : a-b"),
    "exponent-with-space": doc("#OFFSET      : 2.0 E-06", "#XPERCHAN    : 1.0 e -3"),
    "value-then-unit": doc("#XPERCHAN    : 0.5 eV", "#OFFSET      : 3 x"),
    "bad-number-eds": doc("#SIGNALTYPE  : EDS", "#BEAMKV      : abc"),
    "bad-number-plain": doc("#BEAMKV      : abc", "#THICKNESS   : 12 nm"),
    "bad-xperchan": doc("#XPERCHAN    : abc"),
    "empty-xperchan": doc("#XPERCHAN    : "),
    "multiline-title-comment": doc("#TITLE       : first part, ", "#TITLE       : second part", "#COMMENT     : c1 ", "#COMMENT     : c2"),
    "title-colon-value": doc("#TITLE       : a: b"),
    "no-colon-line": doc("#TITLE:abc", "#OWNER"),
    "title-no-colon-then-title": doc("#TITLE", "#TITLE       : x"),
    "time-hm": doc("#TIME        : 10:57"),
    "time-hms": doc("#TIME        : 10:57:05"),
    "time-short": doc("#TIME        : 1:5"),
    "time-24": doc("#TIME        : 24:00"),
    "time-one-part": doc("#TIME        : 10"),
    "time-sec60": doc("#TIME        : 10:57:60"),
    "time-four-parts": doc("#TIME        : 10:57:5:5"),
    "time-text": doc("#TIME        : ab:cd"),
    "time-trailing": doc("#TIME        : 10:57x"),
    "date-ok": doc("#DATE        : 21-MAR-2017"),
    "date-lower-month": doc("#DATE        : 21-mar-2017"),
    "date-leap": doc("#DATE        : 29-FEB-2016"),
    "date-not-leap": doc("#DATE        : 29-FEB-2017"),
    "date-one-digit": doc("#DATE        : 1-JAN-2000"),
    "date-31-apr": doc("#DATE        : 31-APR-2000"),
    "date-numeric-month": doc("#DATE        : 01-01-2000"),
    "date-two-digit-year": doc("#DATE        : 21-MAR-17"),
    "date-text": doc("#DATE        : x"),
    "date-year-0": doc("#DATE        : 01-JAN-0000"),
    "xy": doc("#NCOLUMNS    : 2", datatype="XY", data=("0, 5, 1, 6", "2, 7, 3, 8")),
    "xy-one-pair": doc(datatype="XY", data=("0, 5", "1, 6")),
    "xy-three-columns": doc(datatype="XY", data=("0, 5, 1",)),
    "y-with-tabs-and-values": doc(data=("1\t2 ,3", "nan, inf -inf", "1_0 1e3 .5")),
    "y-bad-value": doc(data=("1, 2", "x, 4")),
    "no-datatype": doc(datatype=None),
    "datatype-other": doc(datatype="Z"),
    "datatype-lower-y": doc(datatype="y"),
    "empty": "",
    "no-spectrum": HEADER + "#TITLE       : none\n",
    "cr-only": doc("#TITLE       : cr").replace("\n", "\r"),
    "crlf": doc("#TITLE       : crlf").replace("\n", "\r\n"),
    "no-final-newline": doc("#TITLE       : tail", tail=False)[:-1],
    "blank-lines": doc("", "#TITLE       : blank", "", data=("", "1, 2", "", "3, 4")),
    "latin1-title": doc("#TITLE       : caf\xe9 \xb5m", "#XUNITS      : \xb5m"),
    "nbsp-value": doc("#BEAMKV      : \xa0200\xa0"),
    "els": doc("#SIGNALTYPE  : ELS"),
    "els-yunits": doc("#SIGNALTYPE  : ELS", "#YUNITS      : e-"),
    "els-ylabel": doc("#SIGNALTYPE  : ELS", "#YLABEL      : Intensity"),
    "cls": doc("#SIGNALTYPE  : CLS"),
    "eds-tem": doc("#SIGNALTYPE  : EDS", "#BEAMKV      : 200"),
    "eds-sem": doc("#SIGNALTYPE  : EDS", "#BEAMKV      : 15"),
    "eds-30": doc("#SIGNALTYPE  : EDS", "#BEAMKV      : 30"),
    "eds-no-beam": doc("#SIGNALTYPE  : EDS"),
    "eds-beamkv-unit-key": doc("#SIGNALTYPE  : EDS", "#BEAMKV-kV   : 100"),
    "wds": doc("#SIGNALTYPE  : WDS"),
    "unknown-type": doc("#SIGNALTYPE  : BANANA"),
    "yunits-only": doc("#YUNITS      : cps"),
    "ylabel-yunits": doc("#YLABEL      : Counts", "#YUNITS      : cps"),
    "eels-keywords": doc("#SIGNALTYPE  : ELS", "#INTEGTIME   : 100", "#DWELLTIME   : 0.5", "#COLLANGLE   : 20", "#CONVANGLE   : 10", "#PROBECUR   : 1e-9"),
    "eds-keywords": doc("#SIGNALTYPE  : EDS", "#BEAMKV      : 200", "#ELEVANGLE   : 20", "#AZIMANGLE   : 0", "#SOLIDANGLE  : 0.13",
                        "#LIVETIME    : 60", "#REALTIME    : 62", "#FWHMMNKA    : 130", "#EDSDET      : SDD", "#XTILTSTGE   : -5", "#THICKNESS   : 100"),
    "duplicate-key": doc("#OWNER       : a", "#OWNER       : b"),
    "format-rewritten": "#FORMAT      : something else\n" + HEADER[HEADER.index("#VERSION"):] + "#SPECTRUM    : x\n1, 2\n",
    "spectrum-twice": doc("#TITLE       : t") + "#SPECTRUM    : again\n9, 9\n",
}


def synthetic_signals():
    """(name, data, axis dict, metadata dict, signal_type, original_metadata or None) as HyperSpy would hand them to the writer."""
    x = np.array([0.0, 1.5, -2.25, 1e7, 3.0, 0.1], dtype=np.float64)
    ax = {"size": 6, "index_in_array": 0, "name": "Energy", "scale": 0.5, "offset": -1.0, "units": "keV", "navigate": False}
    def md(extra=None, signal_type=""):
        m = {"General": {"title": "t"}, "Signal": {"signal_type": signal_type}}
        for k, v in (extra or {}).items():
            cur = m
            parts = k.split(".")
            for p in parts[:-1]:
                cur = cur.setdefault(p, {})
            cur[parts[-1]] = v
        return m
    return [
        ("plain", x, ax, md(), "", None),
        ("date", x, ax, md({"General.date": "2017-03-21"}), "", None),
        ("date-one-digit", x, ax, md({"General.date": "2017-3-5"}), "", None),
        ("bad-date", x, ax, md({"General.date": "21/03/2017"}), "", None),
        ("long-title", x, ax, md({"General.title": "T" * 130}), "", None),
        ("eels", x, ax, md({"Acquisition_instrument.TEM.beam_energy": 200.0, "Acquisition_instrument.TEM.Detector.EELS.exposure": 0.1,
                            "Acquisition_instrument.TEM.convergence_angle": 10.0}, "EELS"), "EELS", None),
        ("eds-tem", x, ax, md({"Acquisition_instrument.TEM.beam_energy": 200.0, "Acquisition_instrument.TEM.Detector.EDS.live_time": 60.5,
                               "Acquisition_instrument.TEM.Stage.tilt_alpha": -5.0}, "EDS_TEM"), "EDS_TEM", None),
        ("eds-sem", x, ax, md({"Acquisition_instrument.SEM.beam_energy": 15.0, "Acquisition_instrument.SEM.Detector.EDS.live_time": 30.0,
                               "Acquisition_instrument.TEM.beam_energy": 99.0}, "EDS_SEM"), "EDS_SEM", None),
        ("cl", x, ax, md({}, "CL"), "CL", None),
        ("wds", x, ax, md({}, "WDS"), "WDS", None),
        ("other-type", x, ax, md({}, "Something"), "Something", None),
        ("sample", x, ax, md({"Sample.thickness": 123.456}), "", None),
        ("empty-title", x, ax, {"General": {}, "Signal": {"signal_type": ""}}, "", None),
        ("int-data", np.arange(5, dtype=np.int32), dict(ax, size=5), md(), "", None),
        ("float32-data", np.array([0.1, 0.2, 0.3], dtype=np.float32), dict(ax, size=3), md(), "", None),
        ("nan-inf", np.array([np.nan, np.inf, -np.inf, 0.0]), dict(ax, size=4), md(), "", None),
        ("tiny-scale", x, dict(ax, scale=1e-5, offset=1e16), md(), "", None),
        ("latin1", x, dict(ax, name="Énergie", units="µm"), md({"General.title": "café"}), "", None),
        ("non-latin", x, dict(ax, name="Energy", units="Å"), md({"General.title": "漢字 title"}), "", None),
    ]


def write_bytes(api, signal_dict, **kw):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "out.msa")
        try:
            api.file_writer(path, signal_dict, **kw)
        except Exception as e:  # noqa: BLE001
            return {"raises": type(e).__name__}
        return {"b64": base64.b64encode(open(path, "rb").read()).decode()}


def main():
    os.makedirs(os.path.join(FIX, "public"), exist_ok=True)
    pins = {"rsciio": __import__("rsciio").__version__, "read": {}, "write": {}, "texts": {}}
    with tempfile.TemporaryDirectory() as tmp:
        for name in sorted(os.listdir(SRC)):
            shutil.copy(os.path.join(SRC, name), os.path.join(FIX, "public", name))
            pins["read"]["public/" + name] = read_record(os.path.join(SRC, name))
        for name, text in PLANTED.items():
            path = os.path.join(tmp, name + ".msa")
            raw = text.encode("latin-1")
            with open(path, "wb") as fh:
                fh.write(raw)
            pins["texts"][name] = base64.b64encode(raw).decode()
            pins["read"][name] = read_record(path)
    # writes: the public files read by rsciio, then written by rsciio. The writer pops FORMAT and VERSION out of the
    # `original_metadata` it is given, so every write gets a freshly read dictionary.
    def fresh_signal(path, orig=True):
        api = fresh()
        d = api.file_reader(path)[0]
        if not orig:
            d["original_metadata"] = {}
            d["axes"][0]["scale"] = float(d["axes"][0]["scale"])      # a signal HyperSpy hands over has float axes, not the reader's int defaults
            d["axes"][0]["offset"] = float(d["axes"][0]["offset"])
        return api, d

    labels = [("Y", {"format": "Y"}, True), ("XY", {"format": "XY"}, True), ("None", {"format": None}, True),
              ("sep", {"format": "Y", "separator": "; "}, True), ("noorig", {"format": "Y"}, False), ("noorigXY", {"format": "XY"}, False)]
    for name in sorted(os.listdir(SRC)):
        for label, kw, orig in labels:
            try:
                api, d = fresh_signal(os.path.join(SRC, name), orig)
            except Exception:  # noqa: BLE001
                break
            pins["write"][f"public/{name}|{label}"] = write_bytes(api, d, **kw)
    # planted texts read by rsciio, then written
    with tempfile.TemporaryDirectory() as tmp:
        for name in ["eds-keywords", "eels-keywords", "multiline-title-comment", "basic-units-suffix", "eds-sem", "xy", "latin1-title", "yunits-only", "empty"]:
            path = os.path.join(tmp, name + ".msa")
            open(path, "wb").write(PLANTED[name].encode("latin-1"))
            for label, kw, orig in labels:
                try:
                    api, d = fresh_signal(path, orig)
                except Exception:  # noqa: BLE001
                    break
                pins["write"][f"{name}|{label}"] = write_bytes(api, d, **kw)
    # synthetic signals
    pins["synthetic"] = {}
    for name, data, ax, md, st, om in synthetic_signals():
        entry = {"data": [bits(v) for v in data], "dtype": str(data.dtype), "axis": {k: (enc(v) if k in ("scale", "offset") else v) for k, v in ax.items()},
                 "metadata": [[k, enc(v)] for k, v in flatten(md)], "signal_type": st, "write": {}}
        for label, kw in [("Y", {"format": "Y"}), ("XY", {"format": "XY"}), ("None", {"format": None}), ("utf8", {"format": "Y", "encoding": "utf8"}),
                          ("bad", {"format": "Q"})]:
            api = fresh()
            entry["write"][label] = write_bytes(api, {"data": data, "axes": [ax], "metadata": json.loads(json.dumps(md)), "original_metadata": {}}, **kw)
        pins["synthetic"][name] = entry
    with open(os.path.join(FIX, "msa-pins.json"), "w") as fh:
        json.dump(pins, fh, indent=0, sort_keys=True)
        fh.write("\n")
    print("read", len(pins["read"]), "write", len(pins["write"]), "synthetic", len(pins["synthetic"]))


if __name__ == "__main__":
    main()

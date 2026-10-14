#!/usr/bin/env python3
"""Break-once proof of step 1 (docs/registration-step-1.md §7): each planned mutant is applied to a COPY of a commit
(`git archive`, never the working tree), the tests that should catch it run (`swift test -c release --filter ...`), and the
mutant must turn at least one test red. The copy keeps one warm .build across mutants.

    mutants.py [--commit REV] [--only N,...]

Prints one line per mutant (`red` / `SURVIVED` / `does not apply`) and `mutants: N of M red`; exit 0 only if every one is red.
"""
import argparse, os, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DM = "Sources/FormatoDM/DMSignals.swift"
EMD = "Sources/FormatoEMD/VeloxImageSignals.swift"
UNITS = "Sources/FormatoCore/FormatoUnits.swift"
ARRAY = "Sources/FormatoCore/FormatoArray.swift"
READER = "Sources/FormatoEMD/VeloxEMDReader.swift"
PINS = "PinsTests|DMSignalsPlantedTests"
MUTANTS = [
    (1, "DM offset without the minus sign", DM, "cal.map { (-1 * $0.origin) * $0.scale }", "cal.map { $0.origin * $0.scale }", PINS),
    (2, "DM axes not reversed", DM, "let cal = Array(calibrations.reversed())", "let cal = calibrations", PINS),
    (3, "DM missing calibration scale 0 instead of 1", DM, 'return (0, 1, "")', 'return (0, 0, "")', PINS),
    (4, "DM navigate: the spectrum rule dropped", DM, "} else if spectrumLike && n == 2 {", "} else if false && spectrumLike && n == 2 {", PINS),
    (5, "DM energy-axis name by position instead of by units", DM, "let i = units.firstIndex(of: unit)", "let i = Optional(0)", PINS),
    (6, "DM signal type \"X-ray\" -> \"EDS\"", DM, 'if signal == "X-ray" { return "EDS_TEM" }', 'if signal == "X-ray" { return "EDS" }', PINS),
    (7, "int16 read as uint16", DM, "case 1: return .int16", "case 1: return .uint16", PINS),
    (8, "beam energy not divided by 1000", DM, "value: .number(volts / 1e3),", "value: .number(volts),", PINS),
    (9, "Velox single frame not squeezed", EMD, "let stacked = frames > 1", "let stacked = frames >= 1", PINS),
    (10, "Velox scale_y converted to the file's unit, not x's", EMD, "convertUnits(height, from: unit, to: x.units)", "convertUnits(height, from: unit, to: unit)", PINS),
    (11, "to_compact floor -> round", UNITS, "l.rounded(.down)", "l.rounded()", "UnitsTests|PinsTests"),
    (12, "the factor not halved", UNITS, "let half = Double(factor) / 2", "let half = Double(factor)", "UnitsTests|PinsTests"),
    (13, "row stride off by one", ARRAY, "strides[k] = strides[k + 1] * shape[k + 1]", "strides[k] = strides[k + 1] * (shape[k + 1] + 1)", "ArrayTests|PinsTests"),
    (14, "slab start ignored", ARRAY, "var element = start[rank - 1]", "var element = 0", "ArrayTests|PinsTests"),
    (15, "provenance source of the title swapped with the signal type's", DM, 'provenance: p("ImageList.\\(object.index).Name",', 'provenance: p(tags + "Meta Data.Signal",', PINS),
    (16, "the shipped libhdf5 removed from the lookup", READER, "            FormatoHDF5Library.bundledLibraryPath,\n", "", "BundledLibraryTests"),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", default="HEAD")
    ap.add_argument("--only")
    a = ap.parse_args()
    only = {int(x) for x in a.only.split(",")} if a.only else None
    work = Path(os.environ.get("MUTANTS_WORK") or tempfile.mkdtemp(prefix="formato-mutants-"))
    copy = work / "fk"
    if copy.exists():
        shutil.rmtree(copy / "Sources"); shutil.rmtree(copy / "Tests")
    copy.mkdir(parents=True, exist_ok=True)
    archive = subprocess.run(["git", "-C", str(ROOT), "archive", a.commit], check=True, capture_output=True).stdout
    subprocess.run(["tar", "-x", "-C", str(copy)], input=archive, check=True)
    refs = copy / "References"
    if not refs.exists():
        refs.symlink_to(ROOT / "References")
    env = dict(os.environ, MAC4DSTEM_HDF5_PATH=str(copy / "Sources/FormatoHDF5/Resources/hdf5/libhdf5.dylib"))
    # The public zips the pins read, unzipped as tools/test.sh does (into the copy's .build).
    subprocess.run(["zsh", "-c", "set -e; d=.build/rsciio-unzipped/emd; rm -rf .build/rsciio-unzipped; mkdir -p $d; "
                    "for z in fei_emd_files.zip velox_EELS_EDS.zip velox_emd_v11_elementSelection.zip velox_emd_version11.zip; do "
                    "mkdir $d/$z; unzip -q References/rosettasciio-049e7d70/rsciio/tests/data/emd/$z -d $d/$z; done"], cwd=copy, check=True)
    red = total = 0
    for n, what, path, old, new, flt in MUTANTS:
        if only and n not in only:
            continue
        total += 1
        f = copy / path
        pristine = f.read_text()
        if pristine.count(old) != 1:
            print(f"  {n:2d} does not apply ({pristine.count(old)} matches): {what}", flush=True); continue
        f.write_text(pristine.replace(old, new))
        try:
            r = subprocess.run(["swift", "test", "-c", "release", "--filter", flt], cwd=copy, env=env, capture_output=True, text=True)
            out = r.stdout + r.stderr
            # XCTest prints " error: -[Suite test] : ..."; Swift Testing prints "✘ Test ... recorded an issue ...".
            failed = r.returncode != 0 and (" error: -[" in out or "failed (" in out or "✘ Test" in out)
            built = "error: Build failed" not in out and "error: emit-module" not in out
            if failed and built:
                red += 1
                first = next((l for l in out.splitlines() if " error: -[" in l or ("✘ Test" in l and "recorded an issue" in l)), "")
                first = first.split(" error: ")[-1].replace("✘ ", "")[:150]
                print(f"  {n:2d} red       {what}: {first}", flush=True)
            else:
                print(f"  {n:2d} SURVIVED  {what} (exit {r.returncode}{'' if built else ', build failed'})", flush=True)
                (work / f"mutant-{n}.log").write_text(out)
        finally:
            f.write_text(pristine)
    print(f"mutants: {red} of {total} red (copy of {a.commit} in {work})")
    sys.exit(0 if red == total else 1)

if __name__ == "__main__":
    main()

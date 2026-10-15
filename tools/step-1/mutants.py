#!/usr/bin/env python3
"""Break-once proof of step 1 (docs/registration-step-1.md §7): each planned mutant is applied to a COPY of a commit
(`git archive`, never the working tree), the tests that should catch it run (`swift test -c release --filter ...`), and the
mutant must turn at least one test red. The copy keeps one warm .build across mutants.

    mutants.py [--commit REV] [--only N,...] [--step 1|2|3|4] [--jobs N]

`--step 2` runs docs/registration-step-2.md §6's mutants (FormatoTIFF) instead of step 1's; `--step 3` registration step 3
§6's (Velox stored types and titles); `--step 4` registration step 4 §6's (Velox spectrum images).

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

TIFF = "Sources/FormatoTIFF/TIFFSignals.swift"
TFILE = "Sources/FormatoTIFF/TIFFFile.swift"
CORE_PY = "Sources/FormatoCore/FormatoPython.swift"
T = "FormatoTIFFPinsTests|PlantedTIFFTests|TIFFRulesTests"
MUTANTS_STEP2 = [
    (1, "big-endian samples not swapped", TIFF, "guard bigEndian, bytesPerSample > 1 else { return }", "guard false, bytesPerSample > 1 else { return }", T),
    (2, "RowsPerStrip default 1 instead of the height", TIFF, "int(278, 0xFFFF_FFFF) ?? 0xFFFF_FFFF", "int(278, 1) ?? 1", T),
    (3, "the last strip's short row count ignored", TIFF, "let rows = min(layout.rowsPerStrip, layout.height - s * layout.rowsPerStrip)", "let rows = layout.rowsPerStrip", T),
    (4, "ASCII trailing NULs kept", TFILE, "while bytes.last == 0 { bytes.removeLast() }", "", T),
    (5, "RATIONAL denominator dropped", TFILE, "TIFFRational(numerator: Int64(r.u32u($0 * 8)), denominator: Int64(r.u32u($0 * 8 + 4)))", "TIFFRational(numerator: Int64(r.u32u($0 * 8)), denominator: 1)", T),
    (6, "the height/width cross-over undone", TIFF, 'case "height": scales[i] = s.x; offsets[i] = o.x; units[i] = u.x', 'case "height": scales[i] = s.y; offsets[i] = o.y; units[i] = u.y', T),
    (7, "ImageJ micron as um", TIFF, 'u.x = "µm"; u.y = "µm"', 'u.x = "um"; u.y = "um"', T),
    (8, "FEI IRBeam x divided by ResolutionY", TIFF, 's.x = try divide(try float(try value("IRBeam", "HFW")), try float(try value("Image", "ResolutionX")))', 's.x = try divide(try float(try value("IRBeam", "HFW")), try float(try value("Image", "ResolutionY")))', T),
    (9, "DM 65009 assigned to x", TIFF, "if let v = page[65009] { s.y = try dmNumber(v) }", "if let v = page[65009] { s.x = try dmNumber(v) }", T),
    (10, "astype tries float before int", CORE_PY, "    if let i = formatoPythonInt(s) { return .int(i) }\n    if let d = formatoPythonFloat(s) { return .float(d) }", "    if let d = formatoPythonFloat(s) { return .float(d) }\n    if let i = formatoPythonInt(s) { return .int(i) }", T),
    (11, "ImageJ axes Z before T", TIFF, 'default: axes = ["T", "Z", "C"]; shape = [frames, slices, channels]', 'default: axes = ["Z", "T", "C"]; shape = [frames, slices, channels]', T),
    (12, "RGB element read with the wrong size", TIFF, "case (3, 2, 1, 8): type = .rgb8", "case (3, 2, 1, 8): type = .rgba8", T),
    (13, "a tiled page read as strips", TIFF, "if dir[322] != nil || dir[324] != nil {", "if false {", T),
    (14, "FEI beam energy times 1e3", TIFF, 'scaled(1e-3), rule: "rsciio mapping_fei: float(x) * 1e-3"', 'scaled(1e3), rule: "rsciio mapping_fei: float(x) * 1e-3"', T),
    (15, "lazy slab column offset off by one", TIFF, "let at = src.layout.rowOffset(y) + src.shift + x0 * el", "let at = src.layout.rowOffset(y) + src.shift + (x0 + 1) * el", T),
]

IMG = "Sources/FormatoEMD/VeloxImageSignals.swift"
TITLES = "Sources/FormatoEMD/VeloxTitles.swift"
V = "VeloxTitlesTests|PinsTests"
MUTANTS_STEP3 = [   # docs/registration-step-3.md §6
    (1, "stored type ignored (Float32)", IMG, "let dataType = FormatoDataType(rawValue: stored.rawValue)", "let dataType = Optional(FormatoDataType.float32)", V),
    (2, "uint64 read as int64", READER, "case .uint64: (memory, size) = (h5.uint64, 8)", "case .uint64: (memory, size) = (h5.int64, 8)", V),
    (3, "a frame's bytes in the wrong order", IMG, "let frame = try FormatoArray(dataType: dataType, shape: frameShape, bytes: Data(bytes))", "let frame = try FormatoArray(dataType: dataType, shape: frameShape, bytes: Data(bytes.reversed()))", V),
    (4, "CameraInputOperation gives detector", TITLES, 'guard let name = try lookup(entry, "cameraName") as? String', 'guard let name = try lookup(entry, "detector") as? String', V),
    (5, "integrationMode true read as dDPC", TITLES, '(value as? String) == "true" ? "iDPC" : "dDPC"', '(value as? String) == "true" ? "dDPC" : "iDPC"', V),
    (6, "Filtered never prefixed", TITLES, 'name = "Filtered " + name', 'name = "" + name', V),
    (7, "inputIndex 1 gives A-C", TITLES, 'if index == "1" { return ("B-D"', 'if index == "1" { return ("A-C"', V),
    (8, "FFT matched on dataPath", TITLES, 'if try contains(entry, "imageOutputPath")', 'if try contains(entry, "dataPath")', V),
    (9, "the id-in-path test an equality", TITLES, "return text.range(of: id, options: .literal) != nil", "return Self.lastComponent(text) == id", V),
    (10, "no DetectorInformation fallback", TITLES, "            } catch is Fallback {\n                if let information {", "            } catch is Fallback {\n                if false, let information {", V),
    (11, "the carried name reset per image", TITLES, '            let group = "/Data/Image/" + id\n', '            carried = nil\n            let group = "/Data/Image/" + id\n', V),
    (12, "label maps for Image files too", TITLES, "        if spectrumStream {", "        if true {", V),
    (13, "version 11 labels from Presentation", TITLES, "if versionNumber >= 11 {", "if versionNumber >= 99 {", V),
    (14, "STEM tried before camera", TITLES, '["CameraInputOperation", "StemInputOperation",', '["StemInputOperation", "CameraInputOperation",', V),
    (15, "a lazy slab cut from the frame's origin", IMG, "out.append(try frame.slab(start: Array(start.suffix(2)), count: Array(count.suffix(2))).bytes)", "out.append(try frame.slab(start: [0, 0], count: Array(count.suffix(2))).bytes)", V),
]

SI = "Sources/FormatoEMD/VeloxSpectrumImageSignals.swift"
P4 = "SpectrumImagePinsTests|VeloxSpectrumImageTests"
MUTANTS_STEP4 = [   # docs/registration-step-4.md §6
    # The registered mutant 1 (the turnover tested after the value) is equivalent: for ny * nx >= 1 both orders count the same
    # events in the same voxels (amendment A1); re-aimed at a turnover one pixel early.
    (1, "the frame turnover one pixel early", SI, "            if navigation == frameSize {\n                navigation = 0", "            if navigation == frameSize - 1 {\n                navigation = 0", P4),
    (2, "no stop at frame == last_frame", SI, "if frame == layout.last { state.stopped = true; break }", "if false && frame == layout.last { state.stopped = true; break }", P4),
    (3, "first_frame <= frame made <", SI, "if layout.first <= frame {", "if layout.first < frame {", P4),
    (4, "the channel not divided by rebin_energy", SI, "index = navigation * outBins + channel / layout.rebin", "index = navigation * outBins + channel % outBins", P4),
    (5, "the dispersion not multiplied by rebin_energy", SI, "let scale = dispersion / 1000.0 * Double(options.rebinEnergy)", "let scale = dispersion / 1000.0", P4),
    (6, "integer counts saturating instead of wrapping", SI, "case .uint16: run(UInt16.self) { $0 &+= 1 }", "case .uint16: run(UInt16.self) { if $0 < .max { $0 += 1 } }", P4),
    (7, "float32 counts growing past 2^24 (as a Double sum rounded once)", SI, "case .float32: run(Float.self) { $0 += 1 }", "case .float32: run(Float.self) { $0 = $0 >= 16_777_216 ? $0.nextUp : $0 + 1 }", P4),
    (8, "streams 1... not added", SI, "for name in streams {\n                try fill(array,", "for name in streams.prefix(1) {\n                try fill(array,", P4),
    (9, "the not-summed frame index frame, not frame - first_frame", SI, "let f = frame - layout.first", "let f = frame", P4),
    (10, "the x scale factor nx when frames are not summed", SI, "let factor = frames == nil ? nx : ny", "let factor = nx", P4),
    (11, "the grid from the last image", SI, 'guard let first = file.children(of: "/Data/Image").first else {', 'guard let first = file.children(of: "/Data/Image").last else {', P4),
    (12, "last_frame from the markers although endFramePosition is there", SI, "var lastFrame = o.lastFrame ?? numberOfFrames", "var lastFrame = o.lastFrame", P4),
    (13, "the energy detector matched by equality", SI, "guard wantedText.isEmpty || name.range(of: wantedText, options: .literal) != nil else { continue }", "guard name == wantedText else { continue }", P4),
    (14, "the EELS transpose (1, 2, 0) shape", SI, "return try FormatoArray(dataType: a.dataType, shape: [s2, s0, s1], bytes: out)", "return try FormatoArray(dataType: a.dataType, shape: [s1, s2, s0], bytes: out)", P4),
    (15, "the EELS energy offset and dispersion swapped", SI, 'scale: energyScale, offset: energyOffset, units: "eV"', 'scale: energyOffset, offset: energyScale, units: "eV"', P4),
    (16, "the dispersion's KeyError fallback a refusal", SI, 'guard let dispersionValue = entry["Dispersion"] else { return fallback }', 'guard let dispersionValue = entry["Dispersion"] else { throw raises("no Dispersion") }', P4),
]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", default="HEAD")
    ap.add_argument("--only")
    ap.add_argument("--step", default="1", choices=["1", "2", "3", "4"])
    ap.add_argument("--jobs", type=int, default=None, help="swift test -j N (the suite's 8-job machine-wide limit)")
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
    # The public TIFFs the step-2 pins read, unpacked by tools/test.sh: linked, so a mutant's red is never "not found".
    tiffs = copy / ".build/rsciio-tiff"
    if not tiffs.exists() and (ROOT / ".build/rsciio-tiff").exists():
        tiffs.symlink_to(ROOT / ".build/rsciio-tiff")
    red = total = 0
    for n, what, path, old, new, flt in {"1": MUTANTS, "2": MUTANTS_STEP2, "3": MUTANTS_STEP3, "4": MUTANTS_STEP4}[a.step]:
        if only and n not in only:
            continue
        total += 1
        f = copy / path
        pristine = f.read_text()
        if pristine.count(old) != 1:
            print(f"  {n:2d} does not apply ({pristine.count(old)} matches): {what}", flush=True); continue
        f.write_text(pristine.replace(old, new))
        try:
            jobs = ["-j", str(a.jobs)] if a.jobs else []
            r = subprocess.run(["swift", "test", "-c", "release", *jobs, "--filter", flt], cwd=copy, env=env, capture_output=True, text=True)
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

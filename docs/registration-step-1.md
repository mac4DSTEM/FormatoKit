# Registration of step 1: FormatoCore and the reader move (tier 1)

Written 2026-10-14 night, before any Swift line of this repository, by FormatoKit's first session (a side session of the
suite coordinator). Direction: the suite `ROADMAP.md`, "Kits" and "Kits: the execution plan", phase 3. A change after code
starts is a dated amendment at the end (section 12) with its reason; nothing above it is edited silently.

## 1. What step 1 makes

1. **The move.** SpectroKit 0.3.0's readers (tag `0.3.0` = `14c6acf8`) leave `SpectroCore` for three FormatoKit modules,
   read only with `git -C ../SpectroKit show 0.3.0:<path>`:

   | From SpectroKit 0.3.0 | To |
   |---|---|
   | `Sources/SpectroCore/Data/HDF5Types.swift` (`HDF5Serial`, `hid_t`, `herr_t`, `hsize_t`) | `FormatoHDF5` |
   | `Sources/SpectroCore/Data/VeloxEMDReader.swift` | `FormatoEMD` |
   | `Sources/SpectroCore/Data/DM4Experiment.swift`, `DM4Error.swift` | `FormatoDM` |

   Byte-identical output is the claim (section 6, gates M1–M4). What may change in the moved text, and nothing else:
   - **Access.** A `package` declaration becomes `public` when SpectroKit's staying code, its staying tests or its
     consumer check use it (they are another package after the switch, and `package` does not cross a package
     boundary). The list is measured by compiling a scratch copy of SpectroKit 0.3.0 against FormatoKit (gate M4), not
     guessed; it is written into `docs/consumers-0.0.1.md`. A `private` type a new FormatoKit file must reach becomes
     internal. Nothing becomes less visible.
   - **Imports.** `import FormatoCore` / `import FormatoHDF5` where a moved file uses them.
   - **Three renames, one text.** SpectroCore's `SpectroCancelled`, `SpectroCancellation` and `spectroDisplayFileName`,
     which the readers use, stay in SpectroKit for its own code; the readers use FormatoCore's `FormatoCancelled`,
     `FormatoCancellation` (its `check` public, because SpectroKit calls it across the boundary) and
     `formatoDisplayFileName`, same bodies. SpectroKit 0.4.0 can make its two names typealiases of FormatoCore's, so a
     consumer's `catch is SpectroCancelled` keeps working (consumers note). The quit barrier's one stderr line says
     `FormatoKit:` instead of `SpectroKit:` (the module that prints it); its test's literal changes with it.
   - **libhdf5 lookup.** `VeloxHDF5Library.defaultCandidates` keeps its order and gains one candidate before the bare
     `libhdf5.dylib`: the copy FormatoKit ships (section 5). A host that ships its own (the apps) still finds its own
     first. The variable keeps its name, `MAC4DSTEM_HDF5_PATH`, because every consumer sets that name today.
   - **Doc comments** that name SpectroKit's paths or slots, where they would mislead a reader of FormatoKit.

2. **The tests that move, by name.** The brief said "the 258 reader test names"; the measured truth is narrower. The 258
   names of SpectroKit's `SpectroCoreTests` are mostly the X-ray tests (fits, proposer, quantification) that stay with
   `SpectroEDX`. The ones whose subject is a reader move, with their names unchanged:

   | SpectroKit 0.3.0 file | names | FormatoKit target |
   |---|---|---|
   | `SpectroCoreTests/DM4ExperimentTests+Spectro.swift` | 22 | `FormatoDMTests` |
   | `SpectroCoreTests/DM4TagTreeTests.swift` | 3 | `FormatoDMTests` |
   | `SpectroCoreTests/DemoEDXFixtureTests+Spectro.swift` | 5 | `FormatoDMTests` |
   | `SpectroKitTests/DM4EELSSpectrumImageTests.swift` | 21 | `FormatoDMTests` |
   | `SpectroCoreTests/VeloxEMDReaderTests.swift` | 30 | `FormatoEMDTests` |
   | `SpectroCoreTests/VeloxLockAndCancelTests.swift` | 7 | `FormatoEMDTests` |
   | `SpectroCoreTests/VeloxMetadataBoundTests.swift` | 1 | `FormatoEMDTests` |
   | `SpectroKitTests/VeloxMetadataFieldsTests.swift` | 26 | `FormatoEMDTests` |
   | `SpectroKitTests/HDF5ExitBarrierTests.swift` (+ the child `SpectroHDF5ExitProbe`, renamed `FormatoHDF5ExitProbe`) | 6 | `FormatoHDF5Tests` |
   | **total** | **121** | |

   The other 190 `SpectroCoreTests` names, `SpectrumImageOpeningTests` and `SpectroCancellationTests` among them (they
   test `SpectrumImageOpener`, which stays in `SpectroCore`), and `RankThresholdTests` stay in SpectroKit, which keeps
   them green at 0.4.0 (its session's lane). A moved test changes only where section 1.1 changes the code it calls (a
   renamed type, the barrier's line). The fixtures the moved tests read are copied byte for byte (sha256 listed in
   `Tests/README.md`); SpectroKit keeps its copies.

3. **The golden.** SpectroKit's `velox-tiny.txt` (its 0.2.0 re-record) holds the Velox reader's outputs in its lines
   1–175 (`readSpectrumImage`, the event store, the per-pixel spectra, frames 1..<2) and `SpectrumImageOpener` and the
   EDX windows after them. `FormatoGoldenTests` writes the same dump with the same `GoldenDump` walk over the same calls
   and compares it byte for byte with `Tests/FormatoGoldenTests/Fixtures/velox-tiny-reader.txt`, which is those 175
   lines verbatim. The other golden files (`demo-edx-tiny-dm4.txt` and the EDX ones) are outputs of `SpectrumImageOpener`
   and `SpectroEDX`; they stay in SpectroKit.

4. **FormatoCore**, new: the data model every reader returns (section 3).

5. **Adapters**, new: `FormatoDM` and `FormatoEMD` give a file's signals in FormatoCore's model, ported from RosettaSciIO
   (sections 3.4, 3.5). The moved APIs stay as they are beside them.

6. **The package**: `FormatoCore`, `FormatoDM`, `FormatoEMD`, `FormatoHDF5` as products, and `FormatoTIFF`, `FormatoMRC`,
   `FormatoEMPAD`, `FormatoMSA` as empty products with their planned scope in a doc comment; libhdf5 inside (section 5);
   Swift 6 language mode with the suite's three upcoming features; no unsafe flags; macOS 27 floor (section 5).

## 2. The oracle and the pins

- **RosettaSciIO** (GPL-3.0-or-later, the HyperSpy developers), commit `049e7d7070e84779b499adaf3295beee9facb004` (0.14.0
  + 96 commits, the commit SpectroKit's readers are already checked against), cloned into the gitignored
  `References/rosettasciio-049e7d70` and installed from that clone into `References/rsciio-venv` (Python 3.14.7,
  NumPy 2.5.4, h5py 3.16.0, Pint 0.26.1; the full freeze in `References/rsciio-venv-freeze.txt`). Oracles run as
  `References/rsciio-venv/bin/python -I -B`. A pins script stops unless `rsciio.__file__` is inside that venv and the
  clone's HEAD is the pin.
- **The pins are generated before the Swift code that reads them** (`tools/step-1/pins.py` writes
  `Tests/FormatoCoreTests/Fixtures/step-1-pins.json`). Per file and per signal RosettaSciIO returns: the data's dtype and
  shape, the sha256 of the data as little-endian bytes in C order, every axis (`name`, `size`, `scale` and `offset` as
  IEEE-754 bit patterns, `units`, `navigate`), `title`, `signal_type`, and the mapped metadata of section 3.3 with the
  source each value came from.
- **Files.** The public test files of the pinned clone, checked against its `registry.txt`: every
  `digitalmicrograph/{1D,2D,3D}/*.dm3|dm4` and the five loose files of that folder; every Velox file of `emd/` (the loose
  ones and the members of the four zips, unzipped into a scratch folder after the zip's sha256 is checked). The owner's
  files under `$MACEM_DATA` (`data/eels/**` DM4, `data/tem/*.emd`, `data/stem-edx/*.emd` images): read once by
  `tools/step-1/owner-check.sh`, numbers cited with their log in `docs/status.md`, a manifest line per file in
  `../data/README.md`; never copied or committed, never a gate in `tools/test.sh` (registration change first).
- **What runs where.** A committed subset of the public files (named in `Tests/README.md`, small enough to carry) runs in
  every gate. The full public set runs when `References/rosettasciio-049e7d70` is present and is skipped with that
  reason when it is not (a clone without References, CI). On this machine it is always present, so the gate reads all.
- Agreement with RosettaSciIO is agreement with an independent reading of the same bytes, not truth. Truth is the
  planted files (section 4).

## 3. Definitions (FormatoCore and the adapters)

### 3.1 The data model

- `FormatoDataType`: `int8`, `int16`, `int32`, `int64`, `uint8`, `uint16`, `uint32`, `uint64`, `float32`, `float64`, each
  with its byte size. A file type outside the list is refused by name (complex, RGB, bool), not converted.
- `FormatoArray`: `dataType`, `shape` (C order, slowest first: RosettaSciIO's array shape), and `bytes`, the values in C
  order as **little-endian** bytes, the file's own bytes where the file stores them that way. Two arrays are equal when
  all three are equal; that is the bit-for-bit claim.
- `FormatoAxis`: `name` (optional), `size`, `scale`, `offset`, `units`, `navigate`; uniform (`value(i) = offset + i *
  scale`). The axes list is in array order (axis k describes dimension k of `shape`), as RosettaSciIO's `index_in_array`.
- `FormatoMetadata`: an ordered list of entries `key` (RosettaSciIO's metadata path, e.g.
  `Acquisition_instrument.TEM.beam_energy`), `value` (a number, a string or a flag), `units` (optional), and its
  **provenance**: the file's display name, the source inside the file (a DM tag path, a Velox metadata JSON path) and the
  rule that made the value from the source (e.g. `rsciio digitalmicrograph mapping: value / 1000`). An entry without a
  source does not exist: a value the file does not state is absent, never defaulted.
- `FormatoSignal`: `title`, `signalType`, `axes`, `metadata`, `data: FormatoArray`.
- **Lazy.** `FormatoLazyArray` (protocol): `dataType`, `shape`, `read(start:count:) throws -> FormatoArray`, a hyperslab
  in C order. `FormatoLazySignal` carries the same fields as `FormatoSignal` with a lazy array and `load()`.
  **Registered equal:** `load()` equals `read(start: zeros, count: shape)` equals the eager reading bit for bit, and every
  hyperslab equals the same slice of the eager array (gate L1). A lazy read touches only the bytes of its slab (DM: file
  reads at computed offsets; never the whole file).
- **Units.** Strings as the reference writes them (`"nm"`, `"µm"` with U+00B5, `"1/nm"`, `"eV"`, `""`). `FormatoUnits`
  ports exactly what the adapters need: RosettaSciIO Velox's `_convert_scale_units` (Pint's `to_compact` with the
  `factor` trick) and `convert_units` for the units the files carry (length: m and its SI prefixes; time: s and its
  prefixes; anything else is passed through unconverted, and a test names the cases). Bit for bit against Pint 0.26.1 on
  the files and on a seeded sweep of values (gate U1).
- `FormatoCancelled`, `FormatoCancellation` (`task`, `check`) and `formatoDisplayFileName`: section 1.1.

### 3.2 FormatoDM: a DM3 or DM4 file as signals (RosettaSciIO `digitalmicrograph/_api.py` at the pin)

For each image object `DM4Experiment.list` returns (the thumbnail excluded, as RosettaSciIO excludes it), in `ImageList`
order:
- `shape` = the object's `Dimensions` reversed (DM lists fastest first); data = the object's `Data` bytes, unchanged
  (DM stores little-endian; a big-endian file is refused until one exists to test); dtype from the DM type code:
  1 int16, 2 float32, 6 uint8, 7 int32, 9 int8, 10 uint16, 11 uint32, 12 float64; types 3, 4, 5, 8, 13, 14, 23, 27, 28
  are refused by name.
- axes, per dimension in array order: `scale` = `Calibrations.Dimension.<i>.Scale` (1 when the calibration is absent),
  `offset` = `-1 * Origin * scale` evaluated as RosettaSciIO does (`(-1 * origin) * scale`, which is `-(origin * scale)`
  in IEEE arithmetic, so −0.0 where the origin is 0), `units` = the calibration's `Units` or `""`; `name`: the energy
  axis is "Energy loss" (signal type EELS, units contain "eV" exactly) or "Energy" (EDS / EDX, "keV") or "Wavelength"
  (CL, "nm"), found by RosettaSciIO's `units.index(...)`, and the rest are "x", "y", "z" from the fastest; `navigate` by
  RosettaSciIO's rule (one dimension: signal; a spectrum (image) by `Meta Data.Format` or `spim`, two dimensions: the
  last is signal; otherwise the last two are signal).
- `signalType`: `Meta Data.Signal` "X-ray" → `EDS_TEM`, "CL" or a `Monarc Spectrometer` group → `CL`, "EELS" or
  `spim.eels` → `EELS`, else `""`.
- `title`: the object's `Name`, `""` when absent.
- metadata at step 1, each with its tag path: `General.title`, `General.original_filename`, `Signal.signal_type`, and
  `Acquisition_instrument.TEM.beam_energy` (kV) from `Microscope Info.Voltage / 1000` where RosettaSciIO's mapping gives
  it under TEM (it puts it under SEM for an SEM file; that branch is mapped as RosettaSciIO does it, by
  `Microscope Info.Illumination Mode`). The rest of RosettaSciIO's DM mapping is the parity list's (`docs/parity.md`).

### 3.3 FormatoEMD: a Velox file's images as signals (RosettaSciIO `emd/_emd_velox.py` at the pin)

For each image `VeloxEMDReader.images()` lists (name order, as h5py iterates and RosettaSciIO reads them):
- `shape` = `(frames, y, x)`, or `(y, x)` for one frame (RosettaSciIO squeezes a single frame).
- data: **step 1 reads Float32** through the moved `readImageFrame` (its documented deviation: exact for int8, int16,
  uint8, uint16 and float32 storage). The pins compare the reference array converted with `astype('<f4')` bit for bit,
  and a file whose stored type does not convert exactly is named in the pins (`float32_exact: false`) and compared the
  same way. Stored-dtype reading is step 2's (`docs/parity.md`).
- axes: a stack adds `Time` (navigate), `scale` and units from `_convert_scale_units(FrameTime or the detector's
  ExposureTime, "s", 2 * frames)`; then `y` and `x` (signal), `scale_x, units` = `_convert_scale_units(PixelSize.width,
  PixelUnitX, width)`, `scale_y` = `convert_units(PixelSize.height, PixelUnitX, units)`, offsets the same
  `convert_units` of `Offset.x`, `Offset.y`. Bit for bit (gate P1).
- `title` = the detector name; metadata at step 1: `General.title`, `General.original_filename`,
  `Acquisition_instrument.TEM.beam_energy` from `Optics.AccelerationVoltage / 1000`, with their JSON paths.
- Velox spectrum images keep their moved API (`readSpectrumImage`, the CSR store); as a FormatoSignal they are step 2's.

## 4. Planted truth (independent of RosettaSciIO)

- `eels-planted.dm4` (SpectroKit's generator `tools/eels-reader/make_planted.py`, copied with its fixture): the generator
  writes origin 1.5, scale 2.5, units "nm" on x; scale 3.5, origin 0 on y; origin −40, scale 0.25, "eV" on energy. So x's
  offset is −3.75, y's is −0.0, energy's is 10.0, by closed form; the counts are the generator's literals, and the
  shape of each 3 × 2 × 5 cube is `[5, 2, 3]`. The Swift test states these literals itself.
- `FormatoUnits`: closed-form cases (1.5e-9 m over 100 pixels → 1.5 nm; 2.5e-7 m over 1000 pixels → 0.25 µm; 0.5 s
  over 20 frames → 500 ms; a 0 or NaN magnitude unchanged; units `"1/nm"` passed through), each with the prefix exact
  and the value equal to the closed form within one unit in the last place; the exact bits are the pins'.
- Lazy reading: a seeded set of hyperslabs per array, each compared to the slice cut from the eager array in Swift
  (no reference needed: the claim is equality of two paths).

## 5. libhdf5 inside the package; the platform floor

- `FormatoHDF5` carries HDF5 2.1.1 with libsz and libaec as a resource (`Sources/FormatoHDF5/Resources/hdf5/`): the three
  arm64 dylibs mac4DSTEM vendors, read with `git show 5ba712a0:<file>` (sha256 in `NOTICE`), their licences in
  `Licenses/`. The Velox reader `dlopen`s libhdf5 (it never linked it), so a resource is enough: `swift build` and
  `swift test` work with nothing installed and no variable set (gate H1). Rejected: a SwiftPM C target building HDF5
  from source (a generated `H5pubconf.h` per platform and ~300 k lines per build) and a binary XCFramework (it would
  link what the reader loads by `dlopen`, and its embedding of a bare dylib is not tested here). An app that ships its
  own libhdf5 in `Frameworks/` keeps finding it first; its signing of the resource copy is the app's concern
  (consumers note).
- Platform floor: macOS 27 on Apple silicon (the dylibs are arm64; macOS 27 runs on Apple silicon only). iPadOS needs an
  iOS build of HDF5 and is not claimed; the DM reader is pure Swift and a later step can open that door.

## 6. Gates

- **M1 (the names).** The 121 test names of section 1.2 run in FormatoKit and pass; `tools/step-1/names.sh` lists the
  names at SpectroKit 0.3.0 and in FormatoKit and requires equal sets.
- **M2 (the golden).** `FormatoGoldenTests` byte-identical to the 175 lines.
- **M3 (move parity).** `tools/step-1/move-parity.sh`: a scratch copy of SpectroKit 0.3.0 (by `git archive`, never its
  working tree) and FormatoKit each dump, through the same dump code, every reader output (DM listing, tag tree, 2D
  images, EDS and EELS spectrum images; Velox metadata, images, frames, spectrum image) for every committed fixture, every
  public RosettaSciIO DM and Velox file and the owner's files; the two dumps are equal byte for byte.
- **M4 (the switch compiles).** The same scratch copy of SpectroKit 0.3.0 minus the moved files, depending on FormatoKit
  by path, builds its library targets and runs its staying tests green. This is a dry run for SpectroKit's own 0.4.0
  lane, not that lane; it measures the public list of section 1.1.
- **P1 (pins).** Every signal of every pinned file: dtype, shape, data sha256, every axis field (bits), title, signal type
  and the mapped metadata equal to RosettaSciIO's; a file RosettaSciIO raises on is refused by FormatoKit too.
- **L1 (lazy = eager)** and **U1 (units)**: section 3.1.
- **H1 (no setup).** The consumer check builds and opens `velox-tiny.emd` with `MAC4DSTEM_HDF5_PATH` unset.
- **The gate** is `tools/test.sh` (`swift test -c release`), green with 0 warnings, stamped `.build/last-green`.
- Every new test broken once (section 7). One Gate B refuter on the frozen commit, with new files the fixtures do not hold.

## 7. Planned mutants (break-once proof, on a copy of the frozen commit)

1. DM offset without the minus sign. 2. DM axes not reversed. 3. DM unknown calibration scale 0 instead of 1.
4. DM navigate: spectrum rule dropped. 5. DM energy-axis name by index instead of by units. 6. DM signal type "X-ray" →
"EDS". 7. dtype int16 read as uint16. 8. beam energy not divided by 1000. 9. Velox single frame not squeezed.
10. Velox scale_y converted with the y size instead of x's unit. 11. `to_compact` floor → round. 12. the factor not halved.
13. lazy read with the row stride off by one. 14. lazy read ignoring `start`. 15. metadata provenance source swapped
between two keys. 16. the bundled libhdf5 candidate removed (H1 fails with the variable unset).
Each must turn at least one test red; a survivor is either a missing test (written) or an equivalent mutant (argued).

## 8. Validation

None. Agreement with RosettaSciIO and recovery of planted files are claimed; whether a calibration in a file is right is
the microscope's and the apps' question, registered against a FormatoKit tag.

## 9. Licence

GPL-3.0. The moved code is SpectroKit's (GPL-3.0, extracted from mac4DSTEM). The adapters port RosettaSciIO's rules
(GPL-3.0-or-later), credited in `NOTICE` and `README.md`. Pint (BSD-3-Clause) is ported in `FormatoUnits`, credited.
HDF5, libaec and libsz are BSD-style, their texts in `Licenses/`.

## 10. Data read

The owner's files read for section 2 get a line each in `../data/README.md` (the suite's manifest) when they are read.

## 11. Not in step 1

Writing any format; Velox spectrum images as FormatoSignal; stored-dtype Velox images; NCEM EMD; hspy; TIFF, MRC, EMPAD,
MSA (empty modules); DocC; an example executable; iPadOS. The parity list says where each one stands.

## 12. Amendments

**A1 (2026-10-15, 00:20, after the pins were generated, before any adapter code).** What RosettaSciIO does at the pin,
found by `tools/step-1/pins.py` (110 DM files with 111 signals, 18 Velox files with 42 image signals, none raising):
1. *Types outside `FormatoDataType`.* 47 of the pinned signals are complex64, complex128, bool or DM RGBA, which
   RosettaSciIO reads and §3.1 refuses. P1 for them is: FormatoKit refuses the signal by name
   (`FormatoReadError.unsupportedDataType`) and still lists its axes as RosettaSciIO does where they can be built; the data
   comparison is not made. Reading them is in the parity list.
2. *Units characters.* DM files carry "µm" with U+00B5; Pint's compact form, which the Velox axes get, writes "μm" with
   U+03BC and "1 / μm" for an inverse length. Units are compared as the exact strings each path produces; §3.1's single
   example was wrong.
3. *Inverse lengths are converted.* The public FFT files hand `1/m` to `_convert_scale_units`, which compacts it to
   `1 / μm`. `FormatoUnits` therefore handles powers −1 and 1 of a prefixed base unit (m, s), Pint's `to_compact` rule
   for a negative power (`ceil(log10|m| / power / 3) * 3`); any other unit is passed through, as before.
4. *A missing calibration* is padded by RosettaSciIO after the listed ones in DM order (`np.append` before the reverse),
   so it lands at the slowest end of the array order. Same as padding by DM index; stated here so the test says it.
5. *Beam-energy provenance.* RosettaSciIO's own source path is always under `ImageList.TagGroup0` (it rebuilds the
   tag tree per image) and, for a stack-builder file, under `source.Tags at creation`. FormatoKit's provenance names the
   real tag path in the file (`ImageList.<index>.ImageTags...`); P1 compares the value and the key, and the source by
   its tail (from `Microscope Info` on).
6. *`signal_type`.* Velox images carry no `Signal.signal_type`; FormatoKit's `signalType` is `""` there and the
   metadata has no `Signal.signal_type` entry.
7. *The planted closed form* 1.5e-9 m over 100 pixels gives 1.4999999999999998 nm in Pint (the factor's division
   round trip); §4's "within one unit in the last place" holds, and the exact bits are the pins'.
8. *Velox files with a spectrum stream* make RosettaSciIO import `sparse`, which the venv does not carry; `pins.py`
   neutralises that one check and the stream read for the duration of the call, so the image path runs unchanged
   (`spectrum_stream_not_read: true` on those 9 files). The images RosettaSciIO returns are unaffected.
9. *Packed complex.* `2D/test_fft_packed_complex8.dm4` returns a (5, 4) array with axes of sizes [5, 5]
   (`axes_sizes_match_shape: false` in the pins); FormatoKit refuses the type (point 1).

**A2 (2026-10-15, 00:30, the switch dry run, gate M4).** The access list of §1.1 is measured: a scratch copy of SpectroKit
0.3.0 without the four moved files, depending on FormatoKit by path, compiles its three library targets and its staying test
targets once 51 declarations of the moved files are public (`git diff 4a860dd -- Sources` shows each, 53 changed lines with the two
private types made internal for the Velox adapter; the commit message of `528032b` says 41, a miscount; listed in
`docs/consumers-0.0.1.md`). The quit-barrier probe, which moved, opens Velox through `VeloxEMDReader.readSpectrumImage`
instead of SpectroKit's `SpectrumImageOpener.open`, which made the same call and stays in SpectroKit. The renaming sed
also renamed one test method (`testEveryLongCallThrowsSpectroCancelled`); `names.sh` caught it and the name is restored:
test names never change. In release, Swift Build warns "not stripping binary because it is signed" once for each shipped
dylib; `tools/test.sh` allows exactly those three lines and fails on any other warning.

**A3 (2026-10-15, 00:40, the first run of the units tests).** §4's third closed form was wrong as written: 0.5 s over
20 frames is `_convert_scale_units(0.5, "s", 40)`, which compacts 0.5 × 20 = 10 s, already compact, so the result is
0.5 "s", not 500 ms. The test states 0.5 "s". Every one of the pinned records (the public files' calls, the sweep, the
planted cases) was bit-identical to RosettaSciIO on the first run; the two failures were the hand-written literals (this
one, and a µm to nm conversion that is Pint's factor, one unit in the last place from 1000).

**A4 (2026-10-15, 00:55, the first runs of the pins test).** Three RosettaSciIO behaviours the adapters now follow or
name, found by gate P1; none moves a number the earlier sections registered:
1. *Thumbnails.* `DM4Experiment.list` keeps the thumbnail objects (role `.thumbnail`); `DMFile` drops exactly those the root
   `Thumbnails.N.ImageIndex` list names, which is RosettaSciIO's rule (`get_image_dictionaries`), not the RGBA fallback.
2. *EDS axis names.* RosettaSciIO names the energy axis "Energy" when `signal_type in ("EDS", "EDX")`, but its own
   `signal_type` for an EDS object is "EDS_TEM", so the branch never fires and the axis is named "x". Ported as it is
   (this is a port of the reference's behaviour; a correction belongs upstream); `docs/parity.md` names it.
3. *Velox titles.* RosettaSciIO's title is the `Operations` group's name for the image (element maps, DPC, FFT, the
   camera's display name), which the moved reader does not read. At step 1 `FormatoEMD`'s title is
   `BinaryResult.Detector`; 26 of the 42 public images differ (listed by the test); title and `General.title` are not
   compared for Velox until step 2 ports the `Operations` rule.
Result: 128 public files, 106 signals equal bit for bit (data, shape, every axis field, signal type, DM title, metadata
with its source), 47 refused by name (complex, bool, RGB), lazy slabs equal the eager arrays on every one.

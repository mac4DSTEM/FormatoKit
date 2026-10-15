# Registration, step 4: Velox spectrum images as signals

Written 2026-10-15, 11:45 CEST (09:45 UTC), after 0.1.0 (`bc832ab`, tagged) and before any step-4 Swift line. Tier 1: the
counts, the energy axis and the grid of a spectrum image are numbers a scientist reads. Structure as steps 1 to 3; their
definitions (FormatoCore's array, axis, metadata with provenance) hold unless this file says otherwise. A change after code
starts is a dated amendment (§11).

## 1. What step 4 makes

1. **`VeloxSpectrumImageSignals`** (FormatoEMD, public, a new file): a Velox file's spectrum images as `FormatoSignal`s,
   as RosettaSciIO 049e7d70's `rsciio.emd.file_reader(filename, select_type="spectrum_image", lazy=False, ...)` returns
   them, in its order: the EELS spectrum images first, then the EDS one(s). Eager, as RosettaSciIO's non-lazy path is.
2. **The options as parameters**, `VeloxSpectrumImageOptions`, RosettaSciIO's six arguments with its defaults:
   `firstFrame` (0), `lastFrame` (nil), `sumFrames` (true), `sumEDSDetectors` (true), `rebinEnergy` (1), `dataType`
   (`SI_dtype`; nil = the stream's `StreamEncoding`).
3. **The moved reader does not change.** The adapter does not go through `VeloxEMDReader.readSpectrumImage`, which keeps its
   own rules for SpectroKit (the ScanSize x ScanArea grid, the CSR event store, every stream summed, its refusals): it reads
   the streams itself through `VeloxFile` (internal to FormatoEMD) with RosettaSciIO's rules. The four moved files stay
   byte-identical. FormatoKit's own `VeloxTitles` and `VeloxImageSignals` gain a first-image mode (§3.2).
4. **EELS spectrum images** (`Data/EelsSpectrumImage`, Velox's Zebra / Continuum EELS) are read too (§3.8): a decision of this
   registration. RosettaSciIO returns them with `select_type="spectrum_image"`, the data is a stored dataset (no stream), and
   leaving them out would make the signal list differ from RosettaSciIO's on its own public EELS + EDS file.
5. **Not in step 4:** `lazy=True` (RosettaSciIO's sparse COO and dask path, whose counts are cast with `astype` instead of
   accumulated in the target type: different values for floats beyond 2^24 counts in one voxel); `select_type=None` and
   `"single_spectrum"`; `load_SI_image_stack`; writing.

## 2. The oracle and the pins

- RosettaSciIO 049e7d70 in `References/rsciio-venv` as before, with **`sparse` 0.19.2, `numba` 0.68.0 and `llvmlite`
  0.50.0** installed on 2026-10-15 (the owner's approval of that morning; a download from PyPI; NumPy stays 2.5.4;
  `References/rsciio-venv-freeze.txt` regenerated). With numba present RosettaSciIO's stream fill runs jitted, its real path.
- `tools/step-4/pins.py` writes `Tests/FormatoCoreTests/Fixtures/step-4-pins.json` before any Swift code: for each file and
  each option set, RosettaSciIO's exception (type, message) or, per returned dictionary in order, `dtype`, `shape`,
  `data_sha256` (the array's little-endian C-order bytes), every axis field (scale and offset as bits), the title, the signal
  type, and step 1's metadata entries (`General.title`, `General.original_filename`, the beam energy through the mapping).
- **Files:** every public Velox file of the pinned clone with a spectrum stream or EELS spectrum image (8 that read, the
  pruned `Test SI 16x16 ReducedData 215 kx.emd` and the spectrum-only `fei_emd_spectrum.emd`, which return nothing); the
  planted files of §4; SpectroKit 0.4.0's (`9b93fb4`) six `velox-stream-*.emd`, `velox-tiny.emd` and FormatoKit's own
  `velox-flags-planted.emd` as they are (RosettaSciIO raises `KeyError: 'Displays'` on all eight: a version-11 spectrum-image
  file without `Displays`), copied with provenance, never written in SpectroKit.
- **Option sets:** O1 the defaults; O2 `sum_frames=False`; O3 `sum_EDS_detectors=False`; O4 `rebin_energy=4`; O5
  `SI_dtype="float32"`; O6 `SI_dtype="uint8"`; O7 `first_frame=1`; O8 `last_frame=1`; O9 `sum_frames=False,
  sum_EDS_detectors=False, rebin_energy=2, SI_dtype="int8", first_frame=1`; O10 `last_frame` one past `endFramePosition`.
- **Kernel pins:** RosettaSciIO's own `stream_to_array` (jitted) on synthetic streams the script builds from a seed: the type
  edges (float32 past 2^24 counts in one voxel, uint8 and int8 wrapping, uint16 past 65535), `last_frame=0`, a partial last
  frame, a stream without its last marker, `first_frame` past the stream. The Swift tests rebuild the same streams.
- **The owner's SI** (`$MACEM_DATA/stem-edx/SI HAADF 1456 77000 x 20260420.emd`, 926 x 215 pixels, 1607 frames, one stream of
  408 M values) only through `tools/step-4/owner-check.sh` (owner mode, never a gate, never committed), with O1, O4 and
  `first_frame=100, last_frame=200`; cited with its log.

## 3. Definitions (RosettaSciIO 049e7d70, `FeiEMDReader`, `select_type="spectrum_image"`, `lazy=False`)

### 3.1 Which signals, in which order

A Velox file (`Version.format` "Velox") whose `Data` has `Image` and `SpectrumImage` (RosettaSciIO's `SpectrumStream` type):
the EELS spectrum images (§3.8), one per child of `Data/EelsSpectrumImage` in name order, then the EDS signal(s) (§3.5),
unless `Data/SpectrumStream` is absent or empty (a pruned file: EELS only, or nothing). A file of any other type returns no
signals. Every refusal below is "RosettaSciIO raises" unless marked as a registered deviation.

### 3.2 What runs before the streams

As `read_file` and `_read_data`: `Version`'s `version` key; the four file-level groups and the label map (registration step 3
§3.2, ported in `VeloxTitles`); then `_read_images` reads **only the first image** (name order) before it returns
(`load_images` is false): step 3's title rule on that image alone (DetectorInformation, the carried name, the
detector-metadata lookup, `_get_metadata_dict`'s indexing) and its axes as `VeloxImageSignals` builds them (the pixel units,
`float()` of the sizes). Its stored type is not checked (RosettaSciIO reads compound images too). Refused: no child of
`Data/Image`; a first child that is not a group with a rank-3 `Data` and a `Metadata` (registered deviation, step 3 A1:
only rank-3 stacks are listed).

### 3.3 The grid

`spatial_shape` = the first image's `Data.shape[:2]`, `(y, x)` (RosettaSciIO sets it in `_read_image`; with
`select_type="spectrum_image"` the first image is the only one read, so the step-1 deviation about "the last image" concerns
`select_type=None` only). On all eight public files this equals ScanSize x ScanArea. **Registered deviation:** when the
first stream's metadata gives a grid (`VeloxMetadata.derivedGrid`: ScanSize x ScanArea) and it differs from the first image's,
the file is refused by name (RosettaSciIO decodes the stream onto the image's grid regardless).

### 3.4 Frames

`number_of_frames` = `int(endFramePosition)` of the first child of `Data/SpectrumImage`'s `SpectrumImageSettings` JSON, or
none on any failure (RosettaSciIO catches every exception). `last_frame` defaults to it; an explicit `last_frame` greater than a
non-zero `number_of_frames` is refused (ValueError). If still none, `ceil(markers of the first stream / (ny * nx))`.
`startFramePosition` is not read (the moved reader's refusal of values other than 1 is its own).

### 3.5 The EDS spectrum image (`_read_spectrum_stream`, `FeiSpectrumStream`, `stream_to_array`)

- **Streams:** the children of `Data/SpectrumStream` in name order. A stream's values are `Data[:, 0]`; refused unless
  `Data` is rank 2 with one column of unsigned 16-bit integers (registered deviation: RosettaSciIO reads other shapes and
  types through `.T[0]`).
- **Stream 0** is a `FeiSpectrumStream`: its `AcquisitionSettings` JSON, `int(bincount)`; `bincount % rebin_energy != 0`
  refused (ValueError); `StreamEncoding` (KeyError refused) is the type when `dataType` is nil; its `Metadata` (column 0,
  cut at the first NUL) is the signal's original metadata, merged with the four file-level groups.
- **The type** is one of FormatoKit's ten numeric types by numpy's canonical name (`uint8` ... `float64`); any other
  `StreamEncoding` is refused (registered: numpy also reads aliases such as `"u2"` or `"<u2"`). `rebinEnergy < 1` refused.
- **The fill**, line for line (RosettaSciIO's `_fill_array_with_stream_sum_frames` and `_fill_array_with_stream`):
  `nav = 0, frame = 0`; per value: if `nav == ny * nx` then `nav = 0, frame += 1`, and stop if `frame == last_frame`; a value
  other than 65535 at a frame `>= first_frame` adds one to `[y = nav / nx, x = nav % nx, value / rebin]` (summed) or to
  `[frame - first_frame, y, x, value / rebin]` (not summed); 65535 advances `nav`. Shapes: `(ny, nx, bincount / rebin)` or
  `(last_frame - first_frame, ny, nx, bincount / rebin)`.
- **Each count is `+= 1` in the target type:** integers wrap modulo 2^bits (two's complement for the signed ones), float32
  and float64 add 1.0 with IEEE rounding (so they stop at 2^24 and 2^53). Identical to RosettaSciIO's jitted loop.
- **Registered deviations (RosettaSciIO writes outside its array, which numba does not check):** a value `>= bincount` that is
  not 65535 is refused; with frames not summed, `last_frame - first_frame < 1` is refused (RosettaSciIO raises ValueError for a
  negative extent; for zero frames its Time axis divides by zero (ZeroDivisionError), or, without `Scan.FrameTime`, a
  `last_frame` of 0 never stops and writes out of bounds).
- **`sum_EDS_detectors` true:** one signal; streams 1... add their values into stream 0's array with stream 0's bin count, frame
  range and type (RosettaSciIO reads only their `Data`, not their settings or metadata). **False:** one signal per stream, each
  a `FeiSpectrumStream` (its own `bincount`, divisor check and `Metadata`; the type is stream 0's); the axes and metadata of
  every signal are stream 0's. Registered deviation: a stream whose bin count differs from stream 0's is refused (RosettaSciIO
  returns an energy axis whose size is not the data's).

### 3.6 The EDS axes

From stream 0's metadata merged with the four groups (`om`):
1. `_get_detector_information(om)` (step 3 §3.2.4: a `DetectorIndex` naming a missing `Detectors` entry is refused).
2. `om["BinaryResult"]`'s `PixelSize`, `Offset` and `PixelUnitX` (a missing key refused; `PixelUnitX` must be a string, else
   refused: RosettaSciIO passes a null through unconverted).
3. `x`: `_convert_scale_units(PixelSize.width, PixelUnitX, shape[1])`, where `shape[1]` is `nx` when frames are summed and
   `ny` when they are not (RosettaSciIO's index, ported as it is); `y`: `convert_units(float(height), unit, x_unit)`;
   offsets the same. FormatoUnits as for images (units outside it refused, step 1 A5 F7).
4. Frames not summed: a first axis "Time", offset 0, scale and units `_convert_scale_units(Scan.FrameTime, "s",
   frames)`; refused without `Scan.FrameTime` (RosettaSciIO's axis would have a None scale).
5. "X-ray energy": the first entry of `om["Detectors"]` in written order whose `DetectorName` CONTAINS
   `om["BinaryResult"]["Detector"]`: scale `float(Dispersion) / 1000 * rebin_energy`, offset `float(OffsetEnergy) / 1000`,
   units "keV"; a KeyError anywhere in that search gives scale 1, offset 0 and no units ("" here, None there). `float()`
   that fails is refused.
6. Order and `navigate`: (Time,) y, x navigate; the energy axis does not.

### 3.7 The EDS metadata

Title and `General.title` "EDS"; `signalType` "EDS_TEM"; `General.original_filename` the file name; the beam energy by the
mapping (`Optics.AccelerationVoltage` / 1e3, kV), each with its provenance. `_get_metadata_dict(om)`'s raises (step 3 A1)
apply to stream 0's metadata.

### 3.8 The EELS spectrum images (`_read_eels_spectrum_images`)

- The pixel calibration: the first child of `Data/SpectrumImage`, its `Metadata`'s `BinaryResult`; `spatial_dim =
  len(Offset)`; `x`: `_convert_scale_units(PixelSize.width, PixelUnitX)` (factor 1), `offset_x` = `convert_units(float(Offset.x),
  PixelUnitX, x_unit)`; with `spatial_dim == 2`, `y` and `offset_y` from `PixelSize.height`, `Offset.y` and `PixelUnitY`.
- Per child `<id>` of `Data/EelsSpectrumImage` (name order): `Data` in its stored type (the ten types; others refused);
  rank 3: transposed `(2, 0, 1)`, axes y (size `shape[0]`), x (`shape[1]`); rank 2: axis x; any other rank refused; rank 3
  with `spatial_dim != 2` refused (NameError). The axes are in RosettaSciIO's list order, which is HyperSpy's: its
  `index_in_array` values (y 1, x 0) are ignored by HyperSpy's `create_axes` (2.4.0, read in SpectroKit's exspy venv), whose check uses `hasattr` on a dictionary.
- "Energy-loss": offset `AcquisitionMetadata.Data.offset`, scale `.dispersion` as JSON numbers (a string is refused:
  RosettaSciIO passes it through unconverted), units "eV", not navigating.
- Title "EELS", `signalType` "EELS", `General.original_filename` the file name (registered deviation: RosettaSciIO writes the
  path as opened, `f.filename`). No mapping, so no beam energy.

### 3.9 Provenance

Every entry names its source: the stream, image or EELS group and JSON path, or the rule (`"rsciio emd velox: detector_name
= 'EDS'"`).

## 4. Planted truth (independent of RosettaSciIO)

`tools/step-4/make_velox_si.py` writes `Tests/FormatoEMDTests/Fixtures/step4/` (h5py, the Velox layout of the public files).
For each file the generator holds the planted counts per frame, pixel and channel (drawn from a seed or typed), encodes the
stream from them, and computes the expected array of every option set from the counts by §3.5's definitions, without
RosettaSciIO's code; `tools/step-4/pins.py` stops on any difference.
- `si-planted-v11.emd` (version 11, `Displays/ImageDisplay`): three streams, `bincount` 16, `StreamEncoding` "uint8", grid
  3 x 4, `endFramePosition` 3; a voxel of 300 counts (uint8 wraps to 44); a partial last frame whose stream ends without its
  final marker; events in channels 0 and 15.
- `si-planted-v9.emd` (version 9, `Presentation`): one stream, `bincount` 8, `StreamEncoding` "int8" (a voxel of 200 counts
  reads -56), no `SpectrumImageSettings.endFramePosition` (frames from the markers), `Scan.FrameTime`, a beam energy.
- `si-planted-eels.emd` (version 11): two EELS spectrum images (rank 3 uint16, rank 2 float32, values typed) and one EDS stream.
- `si-planted-grid.emd`: first image 3 x 4, ScanSize x ScanArea 4 x 3: RosettaSciIO reads; refused here (§3.3).
- `si-planted-bins.emd`: two streams, `bincount` 16 and 32, channels below 16: summed reads equal; not summed refused here (§3.5).
- `sk-<case>.emd` for SpectroKit's six cases: their stream and image datasets copied verbatim from the copies in
  `Fixtures/step4/spectrokit/` (with `PROVENANCE.md`: SpectroKit `9b93fb4`, path, sha256), with complete metadata and
  `Displays` (and a `DetectorIndex` that names no `Detectors` entry dropped: axis-decoy and axis-order name a
  Detector-3 they lack). Truth: SpectroKit's draw (`velox-streams-truth.json`, copied), including the voxel of 70 000 counts (uint16
  wraps to 4464) and the unterminated stream.

## 5. Gates

- **P4 (pins):** every pinned (file, option set): where RosettaSciIO raises, FormatoKit refuses; where it reads, the signals in
  order equal in type, shape, `data_sha256`, every axis field bit for bit, title, signal type and metadata with source. The
  registered deviations (§3.3, §3.5, the copied SpectroKit files' refusals) are listed by name in the test.
- **Kernel pins:** FormatoKit's fill on the same synthetic streams equals RosettaSciIO's `stream_to_array` byte for byte.
- **Planted literals** (`VeloxSpectrumImageTests`): voxels typed by hand (the wraps, a rebinned sum, a frame range, an EELS
  value) without the pins.
- **The owner's SI:** `tools/step-4/owner-check.sh` (owner mode), cited with its log; never a gate.
- `tools/test.sh` the gate; Swift Testing only; the consumer check gains one spectrum image through the public API;
  `docs/consumers-0.1.1.md` (additive: a new public type, nothing existing changes; 0.2.0 stays the generality pass).
- Every new test broken once (§6, `tools/step-1/mutants.py --step 4`); one Gate B refuter on the frozen commit.

## 6. Planned mutants

1. The frame turnover tested after the value instead of before it. 2. No stop at `frame == last_frame`. 3. `first_frame <=
frame` made `<`. 4. The channel not divided by `rebin_energy`. 5. The dispersion not multiplied by `rebin_energy`. 6. Integer
counts saturating instead of wrapping. 7. Float32 counts accumulated in Double and rounded once. 8. Streams 1... not added
(stream 0 only). 9. The not-summed frame index `frame` instead of `frame - first_frame`. 10. The x scale factor `nx` when
frames are not summed (RosettaSciIO's `shape[1]` lost). 11. The grid from the last image. 12. `last_frame` from the markers
although `endFramePosition` is there. 13. The energy detector matched by equality instead of containment. 14. The EELS
transpose `(1, 2, 0)` instead of `(2, 0, 1)`. 15. The EELS energy offset and dispersion swapped. 16. The dispersion's KeyError
fallback replaced by a refusal.

## 7. Validation

None. Agreement with RosettaSciIO, and planted files.

## 8. Licence

GPL-3.0; RosettaSciIO's rules (GPL-3.0-or-later) ported and credited in `NOTICE` as before.

## 9. Data read

The owner's SI (§2), already in `../data/README.md` for FormatoKit step 1; its manifest line gains step 4's use.

## 10. Not in step 4

`lazy=True`; `select_type=None` and `"single_spectrum"` (`Data/Spectrum`); `load_SI_image_stack`; the moved reader's API (as
it is); the `DetectorMetadata` mapping and RosettaSciIO's wider metadata (dates, stage, elements); writing.

## 11. Amendments

**A1 (2026-10-15, 12:45 CEST, the first runs, the mutants and Gate B).** None moves a registered number.
1. *A planted file added after code started* (`si-planted-endframe.emd`, at `4ac6df0`): `endFramePosition` 2 over a stream of
   3 frames, and the matched detector without `Dispersion`, so mutants 12 (`last_frame` from the markers) and 16 (the energy
   fallback) have a file that tells them apart; generated, pinned and equal to RosettaSciIO like the others.
2. *Results on `4ac6df0`.* Gate P4: 28 files (10 public, 12 planted, 6 SpectroKit copies), 226 (file, option set) runs, 234
   signals equal in type, shape, bytes, axes bit for bit, title, signal type and metadata; 34 refused where RosettaSciIO raises;
   9 registered deviations (the grid file's 8 reads, the bin counts' unsummed read). 20 kernel pins equal. Planted literals
   green. Consumer check 39 of 39. The owner's SI (`tools/step-4/owner-check.sh`, log `.build/owner-step4/owner-check.log`, never
   committed): O1, O4 and frames 100 to 200, all equal (926 x 215 x 4096 and x 1024 uint16; RosettaSciIO 9.8 s for the three,
   FormatoKit 1 to 4 s each). `tools/step-1/mutants.py --step 4`: 15 of 16 red; **mutant 1 as registered is equivalent**
   (testing the frame turnover right after a frame's last marker or on the next value counts the same events in the same
   voxels for every stream when ny * nx >= 1; only when the loop's stop flag is set differs) and is re-aimed at a turnover one
   pixel early: red, so 16 of 16.
3. *Gate B* (one refuter, Sonnet, on the frozen `4ac6df0`; about 28 000 generated (file, option set) cases against RosettaSciIO
   with numba): no wrong count, type or shape on ordinary inputs; wraps, float32 past 2^24, rebinning, frame ranges, 1 to 12
   streams, gzip / shuffle / fletcher32 streams, links, 20 EELS types and ranks 0 to 4 agree. Fixed (`40a1d7d`, red first on
   `4ac6df0`: 23 issues and a trap; 15 refuter files pinned by `tools/step-4/refuter_pins.py` in `step4/refuter/`):
   - F7: with no `endFramePosition` and no `last_frame`, a first image whose ny * nx overflows Int trapped in the frame count;
     now checked first and refused (RosettaSciIO raises on such an array).
   - F2: an `endFramePosition` beyond Int64 was taken as absent; Python keeps the integer and raises downstream (OverflowError,
     or ValueError for the array extent; with an explicit `last_frame` only a negative one raises): ported.
   - F3: a zero-frame first image raises in RosettaSciIO (`h5data[:, :, 0]`): refused (spectrum-image files).
   - F1: Velox numbers read Unicode decimal digits ("٣", "１") and underscores as Python's `int()` and `float()` do, after
     Python's own strip (`str.isspace`; Foundation's whitespace set also holds the zero-width space, which Python keeps). For
     FormatoEMD only (the SI path, `VeloxImageSignals`, the `Version` in `VeloxTitles`); TIFF and DM keep step 2's F15.
   - F5: a JSON number that `JSONSerialization` keeps as `NSDecimalNumber` gave a Double one ulp off Python's correctly rounded
     value (e.g. 0.000271666335894359: `...ef18` against `...ef17`); `formatoPythonFloat` (FormatoCore) now parses its exact
     decimal text. Velox writes its numbers as strings, so no public, planted or owner pin moves; the "ulp" cases the refuter
     filed against FormatoUnits were this, not the unit arithmetic. Beyond NSDecimalNumber's 38 digits a value may still differ.
   - F6: "fm" is Pint's fermi (it compacts to "Mfm", "mfm"), not femto-metre: refused by `FormatoUnits.parse` (step 1's units).
4. *Registered deviations added:* a big-endian uint16 stream is READ here (RosettaSciIO's jitted fill raises a numba
   TypingError on the non-native type; the values are the native file's); the first image's `PixelUnitX` null is refused, as the
   image path refuses it (step 3); a `DetectorName` or `BinaryResult.Detector` that is not a string (Python's `in` reads a list as
   membership) is refused; an LZF-filtered stream is refused (no LZF filter in the shipped libhdf5, step 3 A1); `SI_dtype` values
   outside the ten types (bool, complex, float16, numpy aliases) cannot be asked for. Left as before: a raising mapping
   (`AccelerationVoltage` that `float()` refuses) counts as RosettaSciIO raising (step 2's convention).
5. *Memory* (the suite's rule of 12:30, after the refuter's oracle grew to 44 GB on a hostile grid and was killed by the
   coordinator): every oracle launch runs under the suite's `../tools/memcap.sh` (8 GB over the process tree; the owner-check
   scripts call it), and inputs given to RosettaSciIO stay under 2 GB. macOS refuses `setrlimit` on RLIMIT_AS and RLIMIT_DATA
   below infinity: the refuter's worker first set them inside try/except and so ran uncapped (as did a draft of `cap_memory()`
   that was never committed); `tools/step-1/pins.py cap_memory()` as committed adds a watchdog on its own peak resident size
   (exit 3), a second line behind memcap.sh. The refuter's worker then got the same watchdog.
   The earlier owner runs (on `4ac6df0`) were therefore uncapped; under the cap the step-4 owner oracle first passed 8 GB (the
   little-endian copy made for hashing the 1.6 GB array), so `tools/step-4/pins.py` now hashes a contiguous little-endian array
   in place (same digest; the committed pins regenerate unchanged), and the owner check passes under memcap.sh (peak 5.5 GB;
   O1, O4 and frames 100 to 200 equal again).
   Not refuted on this machine: hostile grids and bin counts against RosettaSciIO (run on FormatoKit only, which refuses them
   or allocates lazily up to the machine's memory); the overflowing grid is pinned as "not run". The refuter's phase G3 results
   are absent. Regenerating step 3's pins now flips only their informational `spectrum_stream_not_read` to false (sparse is
   installed); the committed pins are kept (the message of `6bdecb3` said byte-identical for both: true for step 4 only).

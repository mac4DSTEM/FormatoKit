# Registration, step 3: Velox images in their stored type, titled as RosettaSciIO titles them

Written 2026-10-15 (late morning), after the 0.0.3 candidate (`8d647bd`) and before any step-3 Swift line. Tier 1: the data
type and the title of every Velox image signal change, and both are things a scientist reads. Structure as steps 1 and 2.

## 1. What step 3 makes

1. **Stored type.** `VeloxImageSignals` returns each image in the type the file stores (uint8 to uint64, int8 to int64,
   float32, float64), as RosettaSciIO's `_read_image_data` does, where step 1 converted every image to Float32 (amendment
   A4 of step 1, `docs/parity.md` "Velox images: stored dtype"). `VeloxImageArray.dataType` is the stored type; a slab
   reads its frames in that type. The moved reader gains one function, registered here: `VeloxEMDReader.readImageFrameBytes`
   (package), one frame's stored bytes, little-endian, through HDF5's native type of the stored class and size; the five
   native types it needs beside the existing ones (`H5T_NATIVE_INT8/16/32/64_g`, `H5T_NATIVE_DOUBLE_g`) join the symbol
   table. `readImageFrame` (Float32) stays as it is for its callers.
2. **Titles.** A Velox image's title, and its `General.title`, are RosettaSciIO 049e7d70's (`_emd_velox.py`), ported rule
   for rule (§3.2), where step 1 used `BinaryResult.Detector` (26 of the 42 public images and 7 of the owner's 11 differ).
3. **Not in step 3: Velox spectrum images as signals** (`select_type="spectrum_image"`, frame sums, `SI_dtype`,
   `rebin_energy`, first and last frame). They become **step 4**, with their own registration: their pins need RosettaSciIO's
   stream path, which imports `sparse`, absent from the oracle venv (installing it and numba is a download the owner has not
   cleared; a stub module, as `tools/step-1/pins.py`'s `sparse_stub`, lets the non-lazy path run and is step 4's first
   question), and RosettaSciIO takes the SI grid from the last image read, the moved reader's registered deviation, so the
   SI signal needs its own definitions. Splitting keeps step 3 one reviewable change.
4. **Compound images** (Velox FFT and DPC, which RosettaSciIO returns as complex64) stay refused by name: FormatoCore has no
   complex type (as DM's complex types, `docs/parity.md`).

## 2. The oracle and the pins

- RosettaSciIO 049e7d70 with its venv (`CLAUDE.md`). The public Velox files are already pinned by `tools/step-1/pins.py`
  (`Tests/FormatoCoreTests/Fixtures/step-1-pins.json`, written before step 1's code): per image RosettaSciIO's `dtype`,
  `data_sha256` (the stored array, little-endian, C order) and `title`. Step 3 compares those three instead of the Float32
  hash and the skipped title. No public pin is regenerated.
- The planted files of §4 are pinned by a new `tools/step-3/pins.py` (RosettaSciIO's `file_reader(select_type="images")`
  on each, the same record as step 1's), written to `Tests/FormatoEMDTests/Fixtures/step-3-pins.json` before the Swift
  code; it stops if RosettaSciIO disagrees with the planted truth (§4).
- The owner's Velox files go through `tools/step-1/owner-check.sh` (owner mode, never a gate, never committed), which shares
  the public comparison and so checks dtype, data and title there too.

## 3. Definitions

### 3.1 Stored type

- The signal's `FormatoDataType` is the image's `VeloxImageElementType` by name (the ten names are the same). Bytes are
  little-endian, C order `(frames, y, x)` or `(y, x)`, as FormatoArray stores them; RosettaSciIO's array is the stored
  dtype in native (little-endian) order. Frames as before: every frame in a file without `Data/SpectrumImage`, the first
  otherwise (`load_SI_image_stack=False`).
- The read: one hyperslab per frame, the memory type the native type of the stored class, size and sign (HDF5 converts
  a big-endian file to native; Velox writes little-endian). No value changes, so the Float32 deviations of
  `readImageFrame` (rounding of 32- and 64-bit values, float64 overflow to infinity) do not apply to signals.

### 3.2 Title (RosettaSciIO 049e7d70, `FeiEMDReader`, `select_type="images"`)

State and order as RosettaSciIO's: images in name order (`_get_keys_from_group`), one `detector_name` carried from image
to image (initially none).
1. **File-level groups.** For each of `Displays`, `Operations`, `SharedProperties`, `Features` present at the root,
   `_parse_metadata_group`: per child, a group gives `{key: json(dataset[0])}` per dataset in it, a dataset gives
   `json(dataset[0])`. These four keys are then merged over each image's own metadata (`original_metadata.update`).
2. **Image type.** `SpectrumStream` when `Data` has `Image` and `SpectrumImage`, `Image` when it has `Image` only.
3. **Label map** (`_parse_image_display`), only for `SpectrumStream` files. Version >= 11 (`int(Version.version)`):
   every entry of `Displays.ImageDisplay` that has a `data` key: the JSON at the HDF5 path `data` names, its `dataPath`'s
   last `/` component maps to the entry's `id`. Version < 11: every dataset of `Presentation/Displays/ImageDisplay`: its
   JSON's `dataPath`'s last component maps to `display.label`. A missing group or key raises in RosettaSciIO: refused.
4. **Per image** (`_read_image`): `detector_information` = the image metadata's `Detectors["Detector-<DetectorIndex>"]`
   when `BinaryResult` holds a `DetectorIndex` (`str.format` of the stored value), none when it holds none, index 0 when
   there is no `BinaryResult` (a missing entry raises: refused). Then `detector_name` = `_get_detector_name(id)`, and on a
   KeyError anywhere inside it, `detector_information["DetectorName"]` if `detector_information` exists (else the carried
   value stays).
5. **`_get_detector_name(id)`**: KeyError when there is no `Operations` group. Otherwise the first of these, in this order,
   that matches (`id` a SUBSTRING of the path, entries in `Operations.<kind>` order): `CameraInputOperation` →
   `cameraName` (on `dataPath`); `StemInputOperation` → `detector` (`dataPath`); `SurfaceReconstructionOperation` → on
   `unfilteredDataPath` "iDPC" if `integrationMode` is "true" else "dDPC", then on `dataPath` the same, prefixed
   "Filtered " when `enableFilter` is "true"; `MathematicsOperation` (`dataPath`) → "A-C" when `outputs[0].inputIndex` is
   "0", "B-D" when "1", else no match there; `DpcOperation` → "DPC"; `IntegrationOperation` → "DCFI"; `FftOperation` → "Half
   FFT" (on `imageOutputPath`). None → "Unrecognized_image_signal". A key the rule reads that is missing is that KeyError.
6. **Title**: `detector_name` when there is one, then replaced by the label map's entry for `id` when there is one. With
   neither, RosettaSciIO's metadata has no title: the signal's `title` is "" and it has no `General.title` entry.
- `General.title`'s provenance names the rule that gave it (an operation kind and its JSON path, `DetectorInformation`, a
  label map entry, or the carried value).

## 4. Planted truth (independent of RosettaSciIO)

`tools/step-3/make_velox_titles.py` writes small Velox files under `Tests/FormatoEMDTests/Fixtures/` (h5py, the layout
of `velox-tiny.emd`), each image 2 x 3 with distinct values, its expected title and stored type typed BY HAND in the
generator; `tools/step-3/pins.py` checks RosettaSciIO against them and stops on a difference:
- `velox-titles-v6-image.emd` (version 6, `Image`): one image per `Operations` kind and branch (camera, STEM, iDPC on
  `unfilteredDataPath`, dDPC and "Filtered iDPC" on `dataPath`, A-C, B-D, a Mathematics entry with another `inputIndex`
  that falls through, DPC, DCFI, Half FFT, an id no entry names → "Unrecognized_image_signal", an id that is a substring
  of another's path), each in a different one of the ten stored types (uint64 and int64 with values beyond 2^53, float64
  with values Float32 does not hold, int8 negatives).
- `velox-titles-v11-noops.emd` (version 11, `Image`, no `Operations`): titles from `DetectorInformation`; an image whose
  `BinaryResult` has no `DetectorIndex` carries the previous image's title; the first image without either has no title.
- `velox-titles-v11-labels.emd` (version 11, `SpectrumStream`, `Displays/ImageDisplay` and the `SharedProperties` entries
  they point at): labels replace the detector names; an image with no display keeps its detector name.
- `velox-titles-v9-labels.emd` (version 9, `SpectrumStream`, `Presentation/Displays/ImageDisplay`): `display.label`.

## 5. Gates

- **P3 (pins).** Every public pinned Velox image (step-1 pins) and every planted image (step-3 pins): `dtype`, shape,
  `data_sha256` over the stored bytes, `title` and `General.title` equal to RosettaSciIO's; every other field as step 1.
  The title-difference list of `PinsTests` goes; a difference is a failure.
- **L1** (lazy = eager) on every pinned image, in the stored type.
- **Planted literals** (`VeloxTitlesTests`): each planted image's title and type equal the generator's hand-typed truth,
  without the pins.
- **The owner's files**: `tools/step-1/owner-check.sh` (owner mode), cited with its log; never a gate.
- The gate is `tools/test.sh`; Swift Testing only; consumer check extended (a stored type and a title through the public
  API); `docs/consumers-0.0.4.md` names the change (`VeloxImageArray.dataType`, titles).
- Every new test broken once (§6, `tools/step-1/mutants.py --step 3`); one Gate B refuter on the frozen commit.

## 6. Planned mutants

1. Stored type ignored (the Float32 read kept). 2. uint64 read as int64 (sign lost). 3. A frame's bytes in big-endian
order. 4. `CameraInputOperation` returning `detector` instead of `cameraName`. 5. `integrationMode` "true" read as dDPC.
6. "Filtered " never prefixed. 7. Mathematics `inputIndex` "1" giving "A-C". 8. FFT matched on `dataPath` instead of
`imageOutputPath`. 9. The `id`-in-path test made an equality (substring lost). 10. The KeyError fallback to
`DetectorInformation` removed. 11. The carried `detector_name` reset per image. 12. The label map applied to `Image`
files too. 13. Version >= 11 labels read from `Presentation`. 14. The `Operations` kinds tried in another order (STEM
before camera). 15. A lazy slab reading the Float32 path.

## 7. Validation

None. Agreement with RosettaSciIO, and planted files.

## 8. Licence

GPL-3.0; RosettaSciIO's rules (GPL-3.0-or-later) ported and credited in `NOTICE` as before.

## 9. Data read

The owner's Velox files under `$MACEM_DATA` (the three Ceta `.emd` under `tem/` and the SI under `stem-edx/`, already in
`../data/README.md` for FormatoKit step 1): their manifest lines gain step 3's use when owner-check runs.

## 10. Not in step 3

Spectrum images as signals (step 4, §1.3); EELS spectrum images; single spectra (`Data/Spectrum`); compound (complex)
images; `DetectorMetadata` and RosettaSciIO's wider metadata mapping (dates, stage, magnification); `load_SI_image_stack`
as an option (the default only); writing.

## 11. Amendments

**A1 (2026-10-15, 13:00, the first runs, the mutants and Gate B).** None moves a registered number.
1. *Results on `f66bd60`.* Gate P3: all 42 public Velox images (step-1 pins) and the 22 planted ones equal to RosettaSciIO
   in dtype, stored bytes and title, with `General.title` and L1; the owner's 18 files (`tools/step-1/owner-check.sh`, the
   step-1 owner pins reused): 51 signals equal, the 11 Velox images now in their stored type and titles (log
   `.build/owner/owner-check.log`, never committed). `tools/step-1/mutants.py --step 3`: 15 of 15 red. Mutant 15 is aimed
   at the slab cut (a slab taken from the frame's origin) because the slab code no longer has a Float32 path.
2. *The consumers note* of §5 is `docs/consumers-0.1.0.md` (one note for step 3 and the 0.1.0 candidate), not 0.0.4.
3. *Gate B.* One refuter (Sonnet) on the frozen `f66bd60`: 247 hand-built files, about 1 900 fuzz files and 41 targeted
   ones against RosettaSciIO. No crash, no wrong type, bytes or title on ordinary inputs; all ten types, big-endian
   datasets, chunked, compressed and filtered stacks, links and lazy slabs held. Fixed (each refusing where RosettaSciIO
   raises): `_get_detector_metadata_dict`'s lookup, which `_read_image` runs whenever a name is set (no `Detectors`, a
   `Detectors` that is a non-empty list, an entry before the match without `DetectorName`; walked in written order);
   `Operations`, `Displays`, `SharedProperties` or `Features` stored as a root dataset; `_get_metadata_dict`'s indexing
   (no `Acquisition`; no `AcquisitionStartDatetime` and no `CustomProperties`); a `Version` without its `version` key;
   Python's `int()` whitespace (a no-break space is stripped, a zero-width space is not). Regression: 13 of its files under
   `Tests/FormatoEMDTests/Fixtures/refuter-step3/` with RosettaSciIO's reading (`tools/step-3/refuter_pins.py`), 11 that
   raise and 2 that read; red on `f66bd60` (11 issues), green on the fix.
4. *Registered deviations* (refusals where RosettaSciIO reads, or the reverse, on files no Velox version writes):
   - a title, `dataPath`, `Detectors` entry or index that is not a string (null, number, bool, list, dict; RosettaSciIO
     carries the object as the title, and null resets the carried name): refused;
   - names compared and sorted as Swift strings: an image or path that differs only by Unicode normalisation (NFC "é"
     against NFD "e" + U+0301) is one name here; groups listed in name order, where h5py follows a group's creation order
     when `track_order` was set;
   - fixed-length, multi-element, scalar or empty string datasets in the four groups (Velox writes one variable-length
     string per entry; RosettaSciIO swallows an IndexError and drops the rest of that group);
   - JSON that Python's `json` and `JSONSerialization` read differently: NaN and Infinity (refused here), a BOM, a trailing
     comma, text after an embedded NUL (read here), a lone surrogate, nesting beyond 512 levels;
   - `_convert_datetime`'s own refusals of a date value, and `float()` of the TimeStamp, are not checked;
   - the moved reader's rules stay: only 3-D image stacks are listed (a 1-, 2- or 4-D `Data` is skipped, where RosettaSciIO
     reads the 4-D one and raises on the others), the `Velox` format string, images over its size bound, LZF filters.

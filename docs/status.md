# Status

What is live, one table; then the hand-off and what is unverified. Rules are in `CLAUDE.md`; the registrations in
`docs/registration-step-1.md` to `docs/registration-step-4.md` (amendments A1 onward); what each consumer changes in
`docs/consumers-0.0.1.md` to `docs/consumers-0.1.1.md`; the format checklist in `docs/parity.md`.

## Live (2026-10-15: steps 1 and 2 early morning, tagged 0.0.2; 0.0.3 and 0.1.0 tagged; step 4 and the 0.1.1 candidate at midday)

| Area | State | Evidence |
|---|---|---|
| Registration of step 1 | Written before any code (`b012234`); dated amendments since, none moving a registered rule | `docs/registration-step-1.md` §12 |
| The move | SpectroKit 0.3.0's `DM4Experiment`, `DM4Error`, `VeloxEMDReader`, `HDF5Types` in `FormatoDM`, `FormatoEMD`, `FormatoHDF5`, changed only as §1.1 and A2 say; 121 moved test names green; the golden's 175 reader lines byte-identical | `tools/step-1/names.sh`; `FormatoGoldenTests` |
| The switch dry run (M4) | A scratch SpectroKit 0.3.0 without the readers builds against FormatoKit once 51 declarations are public; its 190 staying `SpectroCoreTests` names, its EELS tests and all six golden scenarios green | registration A2; `docs/consumers-0.0.1.md` |
| Move parity (M3) | every reader output through a scratch SpectroKit 0.3.0 and FormatoKit, byte-identical: 151 files (fixtures, RosettaSciIO's public DM and Velox files), 169 with the owner's 18 | `tools/step-1/move-parity/run.sh [--owner]` |
| `FormatoCore` | `FormatoArray` (stored bytes, C order, little-endian), `FormatoAxis`, `FormatoMetadata` with provenance, `FormatoSignal`, `FormatoLazySignal` over `FormatoLazyArray` (`FormatoFileArray`, `FormatoInMemoryArray`), `FormatoUnits` (Pint's compact units with Pint's factor table), `FormatoCancellation` | `ArrayTests`, `UnitsTests` |
| Units (U1) | every pinned call bit-identical to RosettaSciIO's `convert_units` and Velox `_convert_scale_units` (the public files' calls, a seeded sweep, planted cases) | `UnitsTests`; `Fixtures/units-pins.json` |
| `FormatoDM` adapter (P1) | `DMFile`: every object of a DM3/DM4 file as a signal | `PinsTests`: 110 public DM files, every readable signal bit-identical |
| `FormatoEMD` adapter (P1) | `VeloxImageSignals`: a Velox file's images as Float32 signals; axes and beam energy from the image's own metadata JSON by RosettaSciIO's indexing and `float()` rules | `PinsTests`: 18 public Velox files; titles are step 2 (A4) |
| Pins against RosettaSciIO | 128 public files: 106 signals bit-identical (data, shape, every axis field, signal type, metadata with source), 47 refused by name | `PinsTests`; `tools/step-1/pins.py` |
| Lazy = eager (L1) | every pinned signal's seeded slabs equal the eager array's; the file array on planted slabs | `PinsTests`, `ArrayTests` |
| The owner's files | Re-run after the Gate B fixes on `59a6bef`, unchanged: 18 files (14 DM4 under `eels/`, three Ceta `.emd`, the 1.7 GB Velox SI's images): 51 signals bit-identical to RosettaSciIO, the 1.2 to 1.5 GB EELS spectrum images included; RosettaSciIO 15 s, FormatoKit 7 s | `tools/step-1/owner-check.sh` on `70c6222` (log: `.build/owner/owner-check.log`) |
| libhdf5 (H1) | HDF5 2.1.1 + libsz + libaec ship as a `FormatoHDF5` resource; found after the host's copies; a separate package reads Velox with no variable set | `BundledLibraryTests`; `tools/consumer-check/run.sh` |
| Consumer check | 39 checks (0.0.3: both values of each flag, the detector order; step 3: a stored type and a title, a refusal where RosettaSciIO raises; step 4: a spectrum image, defaults and options) through the public API, Debug, 0 warnings, `MAC4DSTEM_HDF5_PATH` unset | `tools/consumer-check/run.sh` |
| Break-once proof | 16 of 16 planned mutants red on a copy of `db9e14a` (XCTest) and again on `59a6bef` (Swift Testing, after the Gate B fixes; mutant 10 re-aimed at the fixed line) | `tools/step-1/mutants.py` |
| Gate B refuter | One refuter on `3391460`: F1 (a units trap), F2 and F3 (Velox defaults where RosettaSciIO raises), F6 (the gate's allow-list) fixed in `dee9e58` with 11 of its files pinned; F4, F5, F7, F8 and F2's DM half registered as named deviations | registration A5; `PinsTests.testRefuterFilesAgreeOrAreRefused` |
| Step 2 registration | Written before code (`e566efe`); amendments A1 (the pins) and A2 (Gate B) | `docs/registration-step-2.md` |
| `FormatoTIFF` container | `TIFFFile`: classic TIFF and BigTIFF, II and MM, every directory and tag (a public walker: the Velox XML 34683, 65027, TIA tags as stored), tifffile's value rules | `FormatoTIFFPinsTests` (every page-0 tag equal to tifffile's) |
| `FormatoTIFF` signals (P2) | `TIFFSignals`: FEI, Gatan DM tags, ImageJ and plain TIFF as RosettaSciIO reads them; uncompressed strips; colour as one element per pixel; the other vendors, compression, tiles and tifffile's shaped / OME / several-series rules refused by name | 45 pinned files: 31 series bit-identical, 14 refused; 26 Gate B files; planted literals |
| The owner's Ceta TIFFs | 6 files (8-bit RGB renders, uncalibrated in RosettaSciIO): 6 signals bit-identical | `tools/step-2/owner-check.sh` on `2136ffc` |
| Step 2 break-once proof | 15 of 15 planned mutants red (mutant 2 needed a TIFF without RowsPerStrip, added) | `tools/step-1/mutants.py --step 2` |
| Step 2 Gate B refuter | One refuter on `700ede0`, 15 500 generated TIFFs: five crashes and the series rules fixed or refused, three deviations registered | registration step 2 A2 |
| 0.0.3 ask 1: five members public | `VeloxSpectrumImage.streamCount`, `.energyCalibrationAgrees`, `VeloxStreamInfo.id`, `VeloxEventStore.streamsAgreeOnCoverage`, `.pixelCount` (SpectroKit's tests read them); both flags over every stream, seen at both values on the planted `velox-flags-planted.emd` and `velox-tiny.emd`; 3 sampled mutants red | registration step 1 A6; `VeloxPublicFlagsTests`; consumer check |
| 0.0.3 ask 2: Velox detector order | `VeloxMetadata.detectors` in the written key order, as RosettaSciIO (was index order): the energy axis, `exposureTimeSeconds`, segments follow; SpectroKit's planted axis-order file equal to RosettaSciIO's pin (0.02 keV/ch from -1.9 keV, was 0.01 / -0.5); three moved tests changed and renamed on purpose; red first, 3 sampled mutants red; Gate B (68 inputs) fixed two minor cases; no public file moves (174 metadata columns scanned) | registration step 1 A7; `VeloxDetectorOrderTests`; `tools/asks-0.0.3/` |
| Standards | `.spi.yml` (DocC, five modules), `.github/workflows/ci.yml` (hook proof, gate, consumer check; enabling Actions is the owner's); the hook refuses `killall` and `pkill` without `-P <pid>` or a scratchpad path; the package builds unchanged at a macOS 15 floor (the floor stays 27 until the owner decides) | `tools/hooks/test-no-sleep-poll.sh`; `Package.swift` |
| Step 3: Velox images, stored type and titles | Registered before code (`6196b70`), planted truth and pins before code (`4154149`); `VeloxImageSignals` in the stored type (`readImageFrameBytes`) and titled by RosettaSciIO's rule (`VeloxTitles`); P3: all 42 public and 22 planted images equal in dtype, bytes and title; the owner's 18 files, 51 signals equal; 15/15 mutants red; Gate B (about 2 200 generated files): RosettaSciIO's remaining raises ported, deviations registered | `docs/registration-step-3.md` A1; `PinsTests`, `VeloxTitlesTests`; `tools/step-1/owner-check.sh` |
| 0.1.0 candidate | `formato-info` (an example executable: every signal of a DM, Velox or TIFF file through the public API), README's first ten minutes, `docs/parity.md` with RosettaSciIO's reader options, `docs/consumers-0.1.0.md` | `swift run formato-info <file>` |
| Step 4: Velox spectrum images as signals | Registered before code (`499adfc`), planted truth and pins before code (`9b740fa`); `VeloxSpectrumImageSignals` and `VeloxSpectrumImageOptions` (`4ac6df0`): RosettaSciIO's `select_type="spectrum_image"` (EELS then EDS, the six options, counts accumulated in the target type), the moved reader unchanged; oracle with sparse 0.19.2 and numba 0.68.0. P4: 28 files, 226 runs, 234 signals equal, 34 refused where RosettaSciIO raises, 9 registered deviations; 20 kernel pins; 16/16 mutants red (mutant 1 re-aimed: the registered one is equivalent) | `docs/registration-step-4.md` A1; `SpectrumImagePinsTests`, `VeloxSpectrumImageTests` |
| Step 4 Gate B | One refuter on `4ac6df0`, about 28 000 generated cases: no wrong count, type or shape; fixed in `40a1d7d` (a trap on an overflowing grid, endFramePosition past Int64, a zero-frame image, Unicode digits, JSON decimals one ulp off, Pint's fermi), 15 files pinned, red first (23 issues and the trap); deviations registered | registration step 4 A1; `testStep4RefuterFilesAgreeOrAreRefused` |
| The owner's SI as a spectrum image | O1, `rebin_energy=4`, frames 100 to 200: equal to RosettaSciIO (926 x 215 x 4096 uint16, 1.6 GB; FormatoKit 1 to 4 s each) | `tools/step-4/owner-check.sh` on `4ac6df0` (log `.build/owner-step4/owner-check.log`) |
| 0.2.0 generality pass | No app or project name in Sources, tests, README, Package.swift, the example or the consumer checks (`git grep` empty); `FORMATO_HDF5_PATH` (step 1 A8); FormatoKit's policies as parameters with 0.1.1's defaults (`VeloxReadPolicy`, `TIFFReadOptions`, `DMReadOptions`; registration 0.2.0 A1); DocC per module; README stands alone with a second consumer built from it; CI's type-check timeouts fixed (CI not yet re-run: needs a push); the Swift code measured green at macOS 15 and compiling for iOS 18, the declaration kept at 27 (the bundled dylibs need macOS 26) | `docs/registration-0.2.0.md`, `docs/consumers-0.2.0.md`; gate stamped at `cd2938b` |
| Empty modules | `FormatoMRC`, `FormatoEMPAD`, `FormatoMSA`: a scope statement each | their source file |
| Tests | Swift Testing throughout (the owner's standard, 2026-10-15): 199 tests, the 121 moved names among them (3 renamed on purpose, A7); 0 failures, 0 warnings beyond the registered strip lines | `tools/test.sh`; `tools/step-1/names.sh` |
| Gate | `tools/test.sh` green and stamped on `40a1d7d` (the Gate B fixes; later commits are docs only); 0.0.3 is `8d647bd`, 0.1.0 `bc832ab` (refuses to stamp with an untracked file under Sources/Tests) | `.build/last-green`; `tools/last-green.sh` |

Validation: none. Agreement with RosettaSciIO and recovery of planted files are what is claimed (registration §8).

## Hand-off

The suite board's `lanes/formatokit` carries the next prompt. In order:

1. **The 0.2.0 refuter** (registration 0.2.0 §3: one refuter over the non-default policy paths, against RosettaSciIO where it
   reads), its fixes red first; then the owner tags 0.2.0.
2. **0.2.1: macOS 15 and iOS 18.** Rebuild the three dylibs with MACOSX_DEPLOYMENT_TARGET=15 (HDF5 2.1.1, the same build,
   registered), declare `.macOS(.v15), .iOS(.v18)`, HDF5 and Velox macOS-only at run time; pin the Xcode version in CI.
3. **Step 5**: EMPAD and the 4D HDF5 readers.

## Unverified

- The resource-bundled dylibs inside a signed, notarised app (the apps embed their own; the bundle's copies are ad-hoc
  signed): not tried. An owner decision on the board.
- Big-endian DM files: none exists to test; not detected.
- `References/` is still a folder here (moving it to `../References/FormatoKit` with a link was refused by this session's
  permission check: the owner's command is on the board).
- Velox: the step-3 deviations of registration step 3 A1 and step 4's of A1; `lazy=True` and single spectra are not ported;
  hostile grids and bin counts were run on FormatoKit only (the suite's memory rule): not refuted against RosettaSciIO here.
- No performance work: lazy reads are positioned reads (DM, TIFF) and per-frame reads (Velox), not memory-mapped.
- TIFF: tifffile's shaped, OME and pyramid series, compression and the other vendor branches are refused, not read.

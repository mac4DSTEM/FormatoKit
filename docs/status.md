# Status

What is live, one table; then the hand-off and what is unverified. Rules are in `CLAUDE.md`; the registration in
`docs/registration-step-1.md` (amendments A1 onward); what each consumer changes in `docs/consumers-0.0.1.md`; the format
checklist in `docs/parity.md`.

## Live (2026-10-15 early morning, the first session)

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
| Consumer check | 27 checks through the public API, Debug, 0 warnings, `MAC4DSTEM_HDF5_PATH` unset | `tools/consumer-check/run.sh` |
| Break-once proof | 16 of 16 planned mutants red on a copy of `db9e14a` (XCTest) and again on `59a6bef` (Swift Testing, after the Gate B fixes; mutant 10 re-aimed at the fixed line) | `tools/step-1/mutants.py` |
| Gate B refuter | One refuter on `3391460`: F1 (a units trap), F2 and F3 (Velox defaults where RosettaSciIO raises), F6 (the gate's allow-list) fixed in `dee9e58` with 11 of its files pinned; F4, F5, F7, F8 and F2's DM half registered as named deviations | registration A5; `PinsTests.testRefuterFilesAgreeOrAreRefused` |
| Empty modules | `FormatoTIFF`, `FormatoMRC`, `FormatoEMPAD`, `FormatoMSA`: a scope statement each | their source file |
| Tests | Swift Testing throughout (the owner's standard, 2026-10-15): 137 tests in 17 suites, the 121 moved names among them; 0 failures, 0 warnings beyond the registered strip lines | `tools/test.sh` |
| Gate | `tools/test.sh` green and stamped at `59a6bef` (refuses to stamp with an untracked file under Sources/Tests) | `.build/last-green` |

Validation: none. Agreement with RosettaSciIO and recovery of planted files are what is claimed (registration §8).

## Hand-off

The suite board's `lanes/formatokit` carries the next prompt. What the next session starts from:

1. **Step 2, `FormatoTIFF`**, registered before code: macTEM's FEI / Thermo Fisher and TIA metadata walker
   (`Sources/TEMCore/Data/AcquisitionMetadata+TIFF.swift`, `TIFFImageReader.swift`, read at macTEM's pushed HEAD) ported into
   `FormatoTIFF` as signals, against RosettaSciIO's `tiff` plugin bit for bit on its public TIFF files and the owner's six
   Ceta TIFFs; macTEM's `tools/metadata-parity` and `tools/tiff-reader-parity` are the seeds of the pins.
2. The Velox gaps of `docs/parity.md` that step 2 can take with it: stored-dtype images, the `Operations` title rule.
3. The owner tags 0.0.1 after pushing; SpectroKit's session then makes the 0.4.0 switch (`docs/consumers-0.0.1.md`).

## Unverified

- The resource-bundled dylibs inside a signed, notarised app (the apps embed their own; the bundle's copies are ad-hoc
  signed): not tried. An owner decision on the board.
- Big-endian DM files: none exists to test; not detected.
- No performance work: lazy reads are positioned reads (DM) and per-frame reads (Velox), not memory-mapped.

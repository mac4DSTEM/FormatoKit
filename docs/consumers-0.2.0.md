# FormatoKit 0.2.0: what the consumers change

Written 2026-10-15 for anyone bumping from 0.1.1. Everything in `docs/consumers-0.0.1.md` to `docs/consumers-0.1.1.md` still
holds unless named here. 0.2.0 is the generality pass: the kit stands without the project it grew in, and FormatoKit's own
policies become parameters whose defaults are 0.1.1's behaviour (`docs/registration-0.2.0.md`).

## Breaking: one change to make

- **The libhdf5 override variable is `FORMATO_HDF5_PATH`** (it was an app-named variable; registration step 1 A8). Nothing reads
  the old name. A consumer that set it renames it; one that did not set it changes nothing (the bundled libhdf5 is found as
  before).

## New, all additive (defaults reproduce 0.1.1 bit for bit; every pin unchanged)

- **`VeloxReadPolicy`** on `VeloxSpectrumImageOptions.policy` and `VeloxImageSignals(path:policy:cancelled:)`:
  `unconvertedUnits` (`.refuse` / `.keepAsWritten`: a pixel unit FormatoUnits does not convert, such as "px", is kept as written
  with the file's numbers instead of refusing the image; Pint's raises still refuse), `spectrumImageGrid` (`.firstImageChecked`
  / `.firstImage`, RosettaSciIO's own reading / `.scanSizeTimesArea`), `maximumArrayBytes`, `streamBlockValues`.
- **`TIFFReadOptions`** on `TIFFSignals(path:options:)`: `vendorBranches` (`.refuse` / `.readAsGeneric`: Zeiss SEM, TVIPS,
  Olympus SIS, JEOL SightX and Hamamatsu streak files read as plain TIFFs, without their vendor metadata).
- **`DMReadOptions`** on `DMFile(path:options:)` and the inherited walk's entry points: `maximumStringBytes` (4096).
- **The flag:** any non-default branch that changed a result adds one metadata entry under `FormatoMetadata.policyKeyPrefix`
  ("FormatoKit.policy.") whose provenance rule begins "FormatoKit policy, not RosettaSciIO's". A consumer comparing against
  RosettaSciIO skips those keys; the defaults never add them.
- **DocC:** each module has a catalogue with one article. **README:** stands alone, with a second consumer
  (`tools/consumer-check/readme`) built from its Swift blocks verbatim.

## Not changed

- No reader's default output, no public signature (every new parameter has a default, every old initializer remains).
- **The platform stays macOS 27.** The Swift code builds and all tests pass at macOS 15, and the package compiles for iOS 18, but
  the bundled libhdf5, libsz and libaec dylibs are built for macOS 26, so declaring 15 would ship a library that cannot load on
  15 to 25. Rebuilding them for macOS 15 (same HDF5 2.1.1, a registration) and declaring macOS 15 with iOS 18 for the pure-Swift
  modules is the next tag, 0.2.1; FormatoHDF5 and FormatoEMD stay macOS-only at run time (iOS cannot load bundled dylibs).

## Bump

```
.package(url: "https://github.com/mac4DSTEM/FormatoKit", exact: "0.2.0")
```

Rename `FORMATO_HDF5_PATH` if you set the old variable. The consumer checks (`tools/consumer-check/run.sh`) read through the
public API only, Debug, no warnings, with the variable unset.

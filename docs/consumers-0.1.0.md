# FormatoKit 0.1.0: what the consumers change

Written 2026-10-15 by FormatoKit's session, for anyone bumping from 0.0.3 (SpectroKit first; mac4DSTEM and macTEM when they
import FormatoKit). Everything in `docs/consumers-0.0.1.md` to `docs/consumers-0.0.3.md` still holds. 0.1.0 is the first
minor: the readers SpectroKit 0.3.0 moved here, FormatoTIFF, and the Velox image path equal to RosettaSciIO in type and
title; the parity checklist (`docs/parity.md`) says what is and is not read. The API is still 0.x: a minor may break, and
every break is named in the next note. The generality pass (defaults as parameters, no suite names in the API) is 0.2.0.

## Changes from 0.0.3 (step 3, `docs/registration-step-3.md`)

- **Velox image signals are in their stored type** (`VeloxImageSignals`): `FormatoSignal.data.dataType` and
  `VeloxImageArray.dataType` are the file's type (uint8 to uint64, int8 to int64, float32, float64), where 0.0.3 and
  earlier returned Float32. The bytes equal RosettaSciIO's array. A consumer that read `.float32` bytes directly reads by
  `dataType` now, or calls `FormatoArray.doubles()`. The moved `VeloxEMDReader.readImageFrame` is unchanged (still Float32).
  On every public and owner file seen the stored types are uint16, int16 and float32, so no value moves where Float32 was
  exact; uint32, 64-bit and float64 images now come back exactly.
- **Velox image titles are RosettaSciIO's** (`FormatoSignal.title`, `General.title`, the new
  `VeloxImageSignals.title(of:)`): the name from `Operations` (camera, STEM detector, iDPC / dDPC, A-C / B-D, DPC, DCFI,
  Half FFT), `DetectorInformation` in files without `Operations`, or the display label of a spectrum-image file, where
  0.0.3 used `BinaryResult.Detector`. 26 of the 42 public images and 7 of the owner's 11 change title (element maps are
  titled by element, "Ceta" for the camera). `General.title`'s provenance names the rule and its JSON path. An image
  RosettaSciIO gives no title has `title == ""`, `title(of:) == nil` and no `General.title`.
- **New refusals**: a Velox file whose title rule raises in RosettaSciIO (a missing `Displays/ImageDisplay` in a
  version-11 spectrum-image file, an `Operations` entry that is not JSON, an image naming a `Detector-<n>` its metadata
  lacks) now throws from `VeloxImageSignals.init`, as RosettaSciIO's `file_reader` raises. No public or owner file is one.
- **Not yet:** Velox spectrum images as signals (step 4).

## New

- **`formato-info`** (`Examples/formato-info`, an executable target, not a product): `swift run formato-info <file>` prints
  every signal of a DM, Velox or TIFF file through the public API; the first ten minutes with the package.
- `.spi.yml` and `.github/workflows/ci.yml` (0.0.3) are in; enabling Actions and listing on the Swift Package Index are the
  owner's once the repository is public.

## Open for the consumers (the owner's decisions)

- The platform floor: macOS 27 today; the package builds unchanged at macOS 15 (checked 2026-10-15).
- libhdf5 inside apps: the resource bundle's three ad-hoc-signed dylibs and notarisation (`docs/consumers-0.0.1.md`, three
  options).

## Pin

`exact: "0.1.0"` once the owner tags it.

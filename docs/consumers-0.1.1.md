# FormatoKit 0.1.1: what the consumers change

Written 2026-10-15 by FormatoKit's session, for anyone bumping from 0.1.0. Everything in `docs/consumers-0.0.1.md` to
`docs/consumers-0.1.0.md` still holds.

**Why 0.1.1 and not 0.2.0.** Step 4 is additive: one new public type with its options, and nothing a 0.1.0 consumer calls
changes its result or its signature (the moved `VeloxEMDReader` is byte-identical, `VeloxImageSignals` returns the same
signals). A patch bump says "nothing to change unless you want the new reader". 0.2.0 stays the generality pass the owner
named (defaults as parameters, no suite names), which may break.

## New in 0.1.1 (step 4, `docs/registration-step-4.md`)

- **`VeloxSpectrumImageSignals(path:options:cancelled:)`** (FormatoEMD): a Velox file's spectrum images as `FormatoSignal`s,
  equal to RosettaSciIO 049e7d70's `rsciio.emd.file_reader(select_type="spectrum_image", lazy=False)`: the EELS spectrum images
  first (`Data/EelsSpectrumImage`, title "EELS", signal type "EELS"), then the EDS spectrum image (title "EDS", signal type
  "EDS_TEM"), each with its axes (`y`, `x`, `X-ray energy` or `Energy-loss`, and `Time` first when frames are not summed), the
  file name and the beam energy with their provenance. Eager: the whole array is in memory, as in RosettaSciIO (the owner's
  926 x 215 x 4096 uint16 SI is 1.6 GB).
- **`VeloxSpectrumImageOptions`**: RosettaSciIO's six arguments with its defaults: `firstFrame` (0), `lastFrame` (nil = the
  recorded `endFramePosition`, else the frames the first stream's markers make; 0 counts every frame, as RosettaSciIO),
  `sumFrames` (true), `sumEDSDetectors` (true), `rebinEnergy` (1), `dataType` (nil = the stream's `StreamEncoding`, uint16 in
  every file seen). Counts behave as RosettaSciIO's: an integer type wraps (a uint16 voxel of 70 000 counts reads 4464), float32
  stops growing at 2^24.

## What differs from the moved `VeloxEMDReader.readSpectrumImage` (SpectroKit's reader, unchanged)

A consumer that has both should know they are two readers on purpose:

| | `VeloxEMDReader.readSpectrumImage` (moved, SpectroKit's) | `VeloxSpectrumImageSignals` (step 4) |
|---|---|---|
| Grid | ScanSize x ScanArea, else the last integer image | the first image's (RosettaSciIO's); refused where ScanSize x ScanArea disagrees |
| Storage | CSR event store, UInt32 counts, never wraps | dense array in the stream's type, wrapping as RosettaSciIO's |
| Streams | always summed | summed, or one signal per stream |
| Frames | `.recordedDefault`, `.all`, a range | `firstFrame` / `lastFrame` with RosettaSciIO's rules (0 = every frame) |
| Refusals | a `startFramePosition` other than 1, a FrameLocationTable that disagrees, a grid larger than the markers | where RosettaSciIO raises, and its registered deviations (registration step 4 §3) |
| EELS | no | yes |

SpectroKit keeps using the moved reader; nothing in 0.1.1 asks it to switch. An app that wants RosettaSciIO's exact arrays (a
parity check, a HyperSpy round trip) uses the new type.

## Registered deviations a consumer can meet

Refused here where RosettaSciIO reads (registration step 4 §3): a first image whose shape differs from the stream's ScanSize x
ScanArea; a stream that is not one column of uint16; a channel at or beyond the bin count (RosettaSciIO's jitted loop writes
outside the voxel); frames not summed with no frame left, or with `last_frame` 0; streams of different bin counts read apart; no
`Scan.FrameTime` with frames not summed; a `StreamEncoding` that is a numpy alias rather than one of the ten names; EELS stored
in a type outside the ten, or with a non-numeric energy calibration; the first image's `PixelUnitX` null; a `DetectorName` that
is not a string; an LZF-filtered stream. One the other way: a big-endian uint16 stream is read here, where RosettaSciIO's
numba loop raises. The EELS `General.original_filename` is the file name,
where RosettaSciIO writes the path it was given.

## Small changes to what 0.1.0 already read (Gate B, registration step 4 A1)

None moves a public, planted or owner pin; each makes FormatoKit closer to RosettaSciIO on unusual files:
- A Velox metadata value written as a JSON number with many digits (Velox writes strings) is now parsed exactly; before, it
  could be one ulp off (Foundation's `NSDecimalNumber`). Image axes of such files may move by that ulp.
- Velox numbers written with Unicode decimal digits or underscores ("٣", "1_1") are read as Python reads them; before, refused.
- A unit "fm" is refused (Pint reads it as the fermi), where 0.1.0 read it as femto-metre.

## Bump

```
.package(url: "https://github.com/mac4DSTEM/FormatoKit", exact: "0.1.1")
```

No other change. The consumer check (`tools/consumer-check/run.sh`) reads one spectrum image with the defaults and with
`sumFrames: false, rebinEnergy: 4, dataType: .float32` through the public API.

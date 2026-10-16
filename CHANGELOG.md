# Changelog

Earlier releases: `docs/consumers-0.0.1.md` to `docs/consumers-0.2.0.md` (what each tag changed for a consumer) and `docs/status.md`.

## Unreleased

- Add `FormatoHDF5.BraggVectorsEMD`: write and read py4DSTEM `BraggVectors` in EMD 1.0 (vlen `{qx,qy,intensity}` float64 `_v_uncal` grid, `Rshape`/`Qshape`, calibration scalars). Peaks read from py4DSTEM 0.14.19 (`f050d207`) files bit for bit; py4DSTEM reads what Swift writes and h5py shows the same group/dataset/attribute structure (`tools/bragg-writer/generate.py`, `check.py`; check result pinned with the files' SHA-256). Atomic publish through a sibling temporary file and rename; a destination that is the source file is refused (`BraggVectorsEMDError.destinationIsSource`). `BraggAxisConvention.appImageXY` is mac4DSTEM's x = column, y = row, pinned to the app writer's swap. `extraAttributes` lets an app write its own string attributes (the app's `mac4dstem_*` attributes, sidecar model and lineage stay in the app). Malformed or truncated files throw typed `BraggVectorsEMDError`.
- `SharedHDF5` gains the write symbols (create/write for files, groups, datasets, attributes, compound/vlen/enum types) and `loadStandard()`; `HDF5Datacube` uses it. There is still one loader.

- Fix CI: the consumer check's README guard failed on the new `FormatoHDF5` README block; `tools/consumer-check/readme` now builds and runs it verbatim (on a scratch copy of the pinned `float32.h5` named `scan.h5`).
- Add `FormatoDM.DM4Datacube`: lazy memory-mapped 4D DM4 images gathered over `DM4Experiment.tagTree(path:)`.
  The default keeps RosettaSciIO's stored order, type and calibrated axes; `.appCalibratedAxes` is the app's
  scan-fastest inference with Float32 output. Bytes, shape and axes are pinned to 049e7d70 (`tools/dm4-gather`).
  New `DM4Experiment.tagTree(path:options:)`.
- Add `FormatoMIB.MIBReader`: lazy mapped processed Merlin frames, header metadata, inferred or explicit scan shapes and frame slicing, pinned to RosettaSciIO 049e7d70. Packed raw R64 (1/6/12/24-bit headers) throws the reference refusal. `MIBConvention.appScanXY` preserves the app reader’s ScanX/ScanY shape, orientation and Float32 conversion, pinned separately.

- Add `FormatoHDF5.HDF5Datacube`: lazy rank-four numeric hyperslabs, py4DSTEM EMD 1.0 calibration axes,
  scalar calibration with provenance, legacy calibration attributes, and lazy fitted/measured origin maps.
  Float32 and UInt16 cubes are pinned bit for bit to py4DSTEM 0.14.19 (`f050d207`) and h5py 3.11.0.
- Move the existing Velox dynamic bindings into FormatoHDF5 so both readers share one loader and exit barrier.
  Add the `FormatoHDF5` product and select a dataset with `HDF5Datacube(path:datasetPath:)`.

- Add `FormatoEMPAD.EMPADReader`: lazy memory-mapped Float32 EMPAD frames with footer rows dropped,
  XML scan shapes, image series, singleton squeezing, navigation and diffraction calibrations, optional
  `qCalibration`, and timestamp metadata with provenance. Malformed pairs throw `EMPADError`.
- Complete bytes, axes and mapped metadata pinned against RosettaSciIO 049e7d70 on synthetic compressed fixtures.

**Migration.** Add the `FormatoEMPAD` product and open an XML header with `EMPADReader(path:)`.
Keep the raw file unchanged while its reader or lazy signal exists.

## 0.2.1

- The platform floor drops to macOS 15 and iOS 18 (was macOS 27). The bundled HDF5 2.1.1, libsz and libaec are rebuilt with
  `MACOSX_DEPLOYMENT_TARGET=15.0` (recipe and hashes in `NOTICE`); every pin and test is unchanged.
- The pure-Swift modules (FormatoCore, FormatoDM, FormatoTIFF and the empty MRC, EMPAD, MSA) build for iOS 18. FormatoHDF5 and
  FormatoEMD load the bundled macOS libhdf5 at run time, so they are macOS-only in practice.
- Measured on macOS 27 (gate, consumer check, iOS 18 builds); not run on a macOS 15 machine. An iOS app should not depend on FormatoHDF5 or
  FormatoEMD: they copy the macOS dylibs as a resource.
- CI runs on `macos-15` with Xcode 26.0 selected and fails if Swift is older than 6.2.

**Migration.** Nothing to change in code. SpectroKit and the apps may lower their declared floor to macOS 15 (apps: iOS 18) and re-pin to 0.2.1.

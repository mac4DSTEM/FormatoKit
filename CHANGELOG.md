# Changelog

Earlier releases: `docs/consumers-0.0.1.md` to `docs/consumers-0.2.0.md` (what each tag changed for a consumer) and `docs/status.md`.

## 0.4.0 (unreleased)

libhdf5 (HDF5 2.1.1 with libsz and libaec) is now three binary targets, dynamic-framework XCFrameworks, instead of a bundled resource folder. An app
that embeds the kit gets them embedded and signed with its own Developer ID by Xcode at archive time; the resource copy stayed ad-hoc signed and failed
Hardened Runtime in a release build. The binaries are the same vendored arm64 files (sha256 in `NOTICE`), with only install names and the load commands
between them rewritten. The readers still `dlopen` libhdf5 and the search order is unchanged.

- Add binary targets `FormatoLibHDF5`, `FormatoLibSZ`, `FormatoLibAEC` (`FormatoHDF5` depends on them, macOS only). Release assets: the three
  `<Name>.xcframework.zip` files of `tools/xcframework/build.sh`, attached to the release `0.4.0`; their checksums are in `Package.swift` (written by a release run of the script). A consumer that links with `-dead_strip_dylibs` loses the framework's load command; `bundledLibraryPath` then falls back to the host's `Frameworks` folder.
- `FormatoHDF5Library.bundledLibraryPath` returns the binary inside `FormatoLibHDF5.framework` (the loaded image, else the host's `Frameworks` folder
  or the folder of the executable); nil when the framework is not found.
- Remove the `Resources/hdf5` resource (and the `FormatoKit_FormatoHDF5` resource bundle). The vendored files moved to `tools/xcframework/vendored/`.
- `FORMATO_LOCAL_XCFRAMEWORKS=1` (set by `tools/test.sh` and the consumer check) points the binary targets at `dist/xcframeworks`, built by `tools/xcframework/build.sh`.

**Migration.** An app that embeds FormatoKit: link `FormatoHDF5` (or `FormatoEMD`, which depends on it) as before; Xcode now also embeds
`FormatoLibHDF5.framework`, `FormatoLibSZ.framework` and `FormatoLibAEC.framework` in `Contents/Frameworks` and signs them with the app's identity (check
that their Embed setting is "Embed & Sign" and remove any build phase that copies `FormatoKit_FormatoHDF5.bundle`). An app that ships its own
`Frameworks/libhdf5.dylib` still has it found first. A package consumer is unchanged except that resolving the package downloads the three zips from the
release; nothing in the public API changed apart from the path `bundledLibraryPath` returns (it no longer ends in `hdf5/libhdf5.dylib`). The libraries
are macOS-only: on iOS the package builds and a Velox read refuses, as before.

## 0.3.1 (2026-10-16)

Acquisition metadata completed against RosettaSciIO 049e7d70: the Velox microscope and stage, and, for DM, MRC, TIFF FEI SEM and Velox, the stage, beam
current, working distance, operator, specimen and the EELS, X-ray and CL groups. All additions are optional fields of `AcquisitionMetadata` and
`VeloxMetadata`, read by `.rosettaSciIO` only; `.app` is unchanged. Coverage by format and field: `docs/parity.md`, "Acquisition metadata coverage".

Added fields.
- `VeloxMetadata`: `instrumentClass` (`Instrument.InstrumentClass`), `stageXMeters`, `stageYMeters`, `stageZMeters` (each `Stage.Position` coordinate alone).
- `AcquisitionMetadata`: `instrumentModel`, `stageTiltAlphaDeg`, `stageTiltBetaDeg`, `stageRotationDeg`, `stageX`, `stageY`, `stageZ`, `beamCurrentNA`,
  `workingDistanceMM`, `operatorName`, `sampleDescription`, `collectionAngleMrad`, `convergenceAngleMrad`, and the dictionaries `signalNumbers` /
  `signalTexts` (keys are RosettaSciIO's metadata paths: `Detector.EELS.frame_number`, `.aperture_size`, `.spectrometer`; `Detector.EDS.azimuth_angle`,
  `.elevation_angle`, `.solid_angle`, `.live_time`, `.real_time`; CL `Spectrometer.*` and `Detector.*` keys, `Signal.format`; `Spectrum_image.*`).
  They are not in `AcquisitionMetadata.Field`. Helpers `pythonRound` and `numpyDegrees`.
- Read per format: DM (stage, probe current, operator, specimen, EELS angles, EELS/X-ray/CL/SI groups, signal-group acquisition dates); MRC (FEI
  128-byte header stage); TIFF FEI SEM (stage, rotation, working distance, beam current, user); Velox EMD and Velox TIFF XML (`InstrumentClass` as the
  microscope, stage). Each reading's `note` names the unit conversion.

Changed behaviour (`.rosettaSciIO`, the default).
- Velox `instrument` (EMD and TIFF XML) is `InstrumentClass` (RosettaSciIO's microscope); the stored `InstrumentModel` is `instrumentModel`.
- DM dwell and exposure follow RosettaSciIO's signal-type chain (EELS: its acquisition time; X-ray: neither; CL: the DigiScan sample time); the DM date
  and time take the last source that parses (DataBar, SI, then the signal group; CL ends with DataBar again), as the mapping order has it.
- Test pins: `tools/acq-metadata` regenerated; its oracle hands mapped functions HyperSpy's slugified keys; new synthetic fixtures.

**Migration.** Additive: new optional fields, nothing removed. Two defaults move under `.rosettaSciIO`: the Velox `instrument` (use `instrumentModel` for
the old value, or `.app`) and the DM dwell/exposure of an EELS, X-ray or CL image. Code that dumps `VeloxMetadata` by reflection gains four fields; the
inherited golden `velox-tiny-reader.txt` went from 175 to 179 lines (`instrumentClass`, `stageX/Y/ZMeters`), updated on purpose in two commits of their own.

## 0.3.0 (2026-10-16)

New readers: EMPAD, 4D HDF5 datacubes, Merlin MIB, a lazy 4D DM4 gather and the MRC image reader; acquisition metadata for DM, MRC, TIFF and Velox
EMD; Velox image selection and the Velox TIFF pixel size as named options; and writing: the py4DSTEM Bragg-vector EMD writer and the HDF5
root-attribute file layer. The libhdf5 XCFramework is NOT in 0.3.0 (the asset upload is still pending); libhdf5 is still the bundled resource.

- Add `FormatoHDF5.HDF5RootAttributes`, `HDF5FileIdentity` and `HDF5FileError`: the file layer of a small HDF5 sidecar whose content is root-group
  string attributes. Writes fixed-length UTF-8 null-padded scalars with library-version bounds (V18, LATEST); reads with named refusals (variable-length,
  non-scalar, over the cap, non-UTF-8, embedded NUL, dense attribute storage, permission denied); publishes only over the file that was checked
  (device and inode), by exclusive rename when nothing was there; builds its scratch file in the item-replacement directory. `SharedHDF5` gains the
  file-access, string-padding, object-header and error-stack symbols (still the one loader). Round-trip and h5py pins (`tools/hdf5-write`).
- Add `FormatoHDF5.BraggVectorsEMD`: write and read py4DSTEM `BraggVectors` in EMD 1.0 (vlen `{qx,qy,intensity}` float64 `_v_uncal` grid, `Rshape`/`Qshape`, calibration scalars). Peaks read from py4DSTEM 0.14.19 (`f050d207`) files bit for bit; py4DSTEM reads what Swift writes and h5py shows the same group/dataset/attribute structure (`tools/bragg-writer/generate.py`, `check.py`; check result pinned with the files' SHA-256). Atomic publish through a sibling temporary file and rename; a destination that is the source file is refused (`BraggVectorsEMDError.destinationIsSource`). `BraggAxisConvention.appImageXY` is mac4DSTEM's x = column, y = row, pinned to the app writer's swap. `extraAttributes` lets an app write its own string attributes (the app's `mac4dstem_*` attributes, sidecar model and lineage stay in the app). Malformed or truncated files throw typed `BraggVectorsEMDError`.
- `SharedHDF5` gains the write symbols (create/write for files, groups, datasets, attributes, compound/vlen/enum types) and `loadStandard()`; `HDF5Datacube` uses it. There is still one loader.
- Add `FormatoMRC.MRCReader` (lazy MRC / MRC2014 images and stacks as RosettaSciIO 049e7d70 reads them: little-endian header, nm axes, squeezed
  size-1 axes, the 128-byte FEI pixel size; modes 0, 1, 2, 6; modes 4 and 12 refused by name) and the named option `MRCAppImage` (the first
  consumer's Float32 reading: signed mode 0, machine stamp honoured, Angstrom, stacks refused). Both pinned bit for bit.
- Add `FormatoTIFF.TIFFVeloxCalibration` and `TIFFReadOptions.veloxCalibration` (default false = RosettaSciIO, which reads no tag 34683): the
  Velox XML pixel size cross-checked against tags 65450-65452, pinned to the consumer's reader.
- Add `FormatoEMD.VeloxImageSelection`: the consumer's object rule (HAADF first, `DetectorIndex`, EDX exclusion) and its axes, pinned to its reader.
- Add acquisition-metadata readers returning `FormatoCore.AcquisitionMetadata`: `AcquisitionMetadata.dm(_:)` / `.dm(numbers:strings:)`
  (FormatoDM), `.mrc(data:)` / `.mrc(path:)` (FormatoMRC), `.tiff(data:)` / `.tiff(path:)` (FormatoTIFF: Velox XML tag 34683, FEI SEM INI,
  DM tag stream 65027) and `.velox(_:)` (FormatoEMD). Each takes an `AcquisitionMetadataConvention`: `.rosettaSciIO` (the default) follows
  RosettaSciIO 049e7d70's mapping for every field it maps; `.app` is the first consumer's rule set, pinned to its source (macTEM cb6e164),
  including its nil-for-zero and unit rules, the FEI1/FEI2 extended-header record and its `unread` fields. Pins and the generator: `tools/acq-metadata`.
  Also: `VeloxImageInfo.resolvedDetector` / `.detectorType`. `FormatoTIFF` now depends on `FormatoDM`;
  `FormatoMRC` gains `MRCError`.
- Add to `FormatoCore`: public `AcquisitionMetadata` and `MetadataReading` (nine acquisition fields, nil when not recorded, with notes and second copies), `GuardedXML` (bounded XML parsing for file-carried documents), and `FormatoFileWrite.write(_:to:)` (scratch file then replace, `FormatoWriteError`). `formatoDisplayFileName` equals the app's copy and is pinned by a test.
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

**Migration.** Nothing breaks: every change is additive and the defaults equal 0.2.1's. Add the `FormatoEMPAD`, `FormatoMIB`, `FormatoMRC` and
`FormatoHDF5` products as you need them. `FormatoTIFF` now depends on `FormatoDM` (it reads DigitalMicrograph tag streams), so a consumer that links
`FormatoTIFF` links `FormatoDM` too; no import changes. `TIFFReadOptions.init` gained `veloxCalibration: Bool = false` (a defaulted parameter: source
compatible, not binary compatible). The test-support target `FormatoAcquisitionPins` is not a product. Keep a raw file unchanged while its EMPAD or MIB
reader or lazy signal exists.

## 0.2.1

- The platform floor drops to macOS 15 and iOS 18 (was macOS 27). The bundled HDF5 2.1.1, libsz and libaec are rebuilt with
  `MACOSX_DEPLOYMENT_TARGET=15.0` (recipe and hashes in `NOTICE`); every pin and test is unchanged.
- The pure-Swift modules (FormatoCore, FormatoDM, FormatoTIFF and the empty MRC, EMPAD, MSA) build for iOS 18. FormatoHDF5 and
  FormatoEMD load the bundled macOS libhdf5 at run time, so they are macOS-only in practice.
- Measured on macOS 27 (gate, consumer check, iOS 18 builds); not run on a macOS 15 machine. An iOS app should not depend on FormatoHDF5 or
  FormatoEMD: they copy the macOS dylibs as a resource.
- CI runs on `macos-15` with Xcode 26.0 selected and fails if Swift is older than 6.2.

**Migration.** Nothing to change in code. SpectroKit and the apps may lower their declared floor to macOS 15 (apps: iOS 18) and re-pin to 0.2.1.

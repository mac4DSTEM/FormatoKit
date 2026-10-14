# FormatoKit 0.0.1: what the consumers change

Written 2026-10-15 by FormatoKit's first session, for SpectroKit's, mac4DSTEM's and macTEM's sessions. Each consumer's switch is
its own reviewed lane in its own session; nothing here was done in their repositories. Facts about the apps were read at their
HEADs, mac4DSTEM `0efd8013` and macTEM `82c31f32`, read-only; recheck at the bump.

## What moved

SpectroKit 0.3.0's readers left `SpectroCore` (registration step 1, §1):

| SpectroKit 0.3.0 | FormatoKit 0.0.1 | Module |
|---|---|---|
| `Sources/SpectroCore/Data/HDF5Types.swift`: `HDF5Serial`, `hid_t`, `herr_t`, `hsize_t` | `Sources/FormatoHDF5/HDF5Types.swift` | `FormatoHDF5` |
| `Sources/SpectroCore/Data/VeloxEMDReader.swift`: `VeloxEMDReader`, `VeloxEMDError`, `VeloxMetadata`, `VeloxDetectorInfo`, `VeloxEnergyAxis`, `VeloxScanTransformation`, `VeloxImageInfo`, `VeloxImageElementType`, the stream types | `Sources/FormatoEMD/VeloxEMDReader.swift` | `FormatoEMD` |
| `Sources/SpectroCore/Data/DM4Experiment.swift`, `DM4Error.swift`: `DM4Experiment`, `DM4ImageObject`, `DM4Image`, `DM4Axis`, `DM4ImageRole`, `DM4EELSSpectrumImage`, `DM4EDSSpectrumImage`, `DM4EDSDetectorTags`, `DM4Error` | `Sources/FormatoDM/` | `FormatoDM` |
| `SpectroCancelled`, `SpectroCancellation` (they stay in SpectroCore for its own code) | `FormatoCancelled`, `FormatoCancellation` (`check` is public) | `FormatoCore` |

Output is byte-identical: the 121 moved test names green, the golden's reader lines identical, and a scratch SpectroKit 0.3.0
built against FormatoKit runs its 190 staying `SpectroCoreTests` names and all six golden scenarios green (registration A2).
New beside the moved API, additive: `FormatoCore`'s data model (`FormatoSignal`, `FormatoLazySignal`, `FormatoAxis`,
`FormatoMetadata`, `FormatoUnits`), `DMFile` and `VeloxImageSignals` (a file's contents as signals, RosettaSciIO's way).

**Behaviour a consumer can see** (all registered):
- 51 declarations that were `package` in SpectroKit 0.3.0 are `public` (SpectroKit's staying code uses them across the new
  package boundary): `DM4EDSSpectrumImage` and its fields, `DM4EDSDetectorTags` and its fields, `DM4Experiment.readEDSSpectrumImage(path:index:)` and `(data:index:)`,
  `DM4ImageObject.eds`, `.dataOrderSwapped`, `.dataOffset`, `.dataByteCount`; `VeloxEMDReader.readSpectrumImage(frames:cancelled:progress:)`,
  `.isVeloxEMD(path:)`, `.elementSelection(fromSettingsJSON:)`, `.storedElementSelection()`; `VeloxSpectrumImage`,
  `VeloxEventStore`, `VeloxStreamGeometry`, `VeloxFrameSelection`, `VeloxScanImage`, `VeloxStreamInfo` and the fields of
  them SpectroKit reads. mac4DSTEM's `tools/velox-parity` compiles with `-package-name spectrokit` to reach
  `readSpectrumImage` and `markersPerFrame`: `readSpectrumImage` is now public; `markersPerFrame` is still `package`.
- **libhdf5 ships inside FormatoHDF5** (HDF5 2.1.1 + libsz + libaec, arm64, the files mac4DSTEM vendors at `5ba712a0`, sha256
  in `NOTICE`), as a resource bundle `FormatoKit_FormatoHDF5.bundle`. The Velox reader's lookup is SpectroKit's plus one
  entry before the bare name: `MAC4DSTEM_HDF5_PATH`, the host app's `Frameworks/libhdf5.dylib` (two forms), **the shipped
  copy**, `libhdf5.dylib`. An app that embeds its own (both apps do) loads its own, as before. A package or tool with nothing
  set now works with no setup. **Open for the apps (the owner's decision, on the board):** an app that links FormatoHDF5 also
  carries the resource bundle with three ad-hoc-signed dylibs inside; notarisation may object to unsigned code in
  `Resources/`. Options: sign them in a build phase, strip the bundle's `hdf5/` folder in a build phase (the app's own copy
  is found first), or a later FormatoKit product split (the dylibs in an opt-in product).
- The quit barrier's one stderr line says `FormatoKit: HDF5Serial's quit barrier passed its bound ...` (was `SpectroKit:`).
- **One HDF5 lock per process.** `HDF5Serial` is now FormatoHDF5's. A process that links FormatoKit's `HDF5Serial` AND an
  older SpectroKit's (0.1.0 to 0.3.0 still define their own) has two locks and two quit barriers around one non-thread-safe
  libhdf5: the race the lock exists to prevent. **Bump SpectroKit to 0.4.0 and add FormatoKit 0.0.1 in the same change**;
  never one without the other.

## SpectroKit 0.4.0 (its session's lane)

Measured by the dry run (registration A2; the scratch copy and its log are named in `docs/status.md`):
1. `Package.swift`: `dependencies: [.package(url: "https://github.com/mac4DSTEM/FormatoKit", exact: "0.0.1")]` (a path
   dependency until the owner pushes and tags); `SpectroCore` depends on the products `FormatoCore`, `FormatoDM`,
   `FormatoEMD`, `FormatoHDF5`. Remove the `SpectroHDF5ExitProbe` executable target and `SpectroKitTests`' dependency on it.
2. Delete `Sources/SpectroCore/Data/{HDF5Types,VeloxEMDReader,DM4Experiment,DM4Error}.swift`.
3. `SpectroCancellation.swift`: `public typealias SpectroCancelled = FormatoCancelled` and
   `public typealias SpectroCancellation = FormatoCancellation`, so a consumer's `catch is SpectroCancelled` keeps working
   and one error type crosses both kits. Keep `spectroDisplayFileName` (SpectroKit's own code uses it).
4. Imports: every SpectroCore and SpectroEDX file that names a reader type imports the Formato module it comes from
   (`MemberImportVisibility` is on). The dry run used `@_exported import` of the four modules in one SpectroCore file, which
   also keeps consumers' `import SpectroCore` seeing `DM4Experiment` and the rest; whether 0.4.0 re-exports (source
   compatible for consumers) or not (each consumer imports FormatoDM / FormatoEMD / FormatoHDF5 itself) is that lane's
   decision, stated in its `consumers-0.4.0.md`.
5. Tests: delete the nine moved test files (`tools/step-1/names.sh` in FormatoKit lists them) and the probe; the other 190
   `SpectroCoreTests` names, `RankThresholdTests`, the EELS tests and the full golden stay, green in the dry run. The
   `VeloxEventStore: CSRSpectrumStore` extension in `SpectrumImageOpening.swift` stays and compiles as it is.
6. `tools/test.sh`: the libhdf5 search can go (FormatoKit ships it), or stay as an override. `tools/consumer-check`: its
   reader checks (Velox, DM4 demo, DM4 errors, tag tree, EELS reader, barrier) are FormatoKit's to carry now; keep the
   SpectroEELS checks. `tools/velox-metadata-parity` and `tools/eels-reader` generate fixtures that now live in FormatoKit
   (`Tests/README.md` there names each origin).
7. `NOTICE`: the readers' and HDF5's sections point at FormatoKit.

## mac4DSTEM

It pins SpectroKit **0.1.0** exactly and links only `SpectroCore` (DSTEMCore, DSTEMSession, the app). Its switch is to
SpectroKit 0.4.0 and FormatoKit 0.0.1 together (the lock rule above). What it uses from the moved files:
- `HDF5Serial` (run, acquire, release, installExitBarrier) and `hid_t`/`herr_t`/`hsize_t`: `Core/Data/H5Reader.swift`,
  `Core/Data/BraggVectorEMDWriter.swift`, and the tools `dm4-parity-probe`, `hdf5-exit-race-test` → `import FormatoHDF5`.
- `DM4Error`: `Core/Data/DM4Reader.swift`, `Session/SessionGates.swift`, `tools/dm4-robustness-test` → `import FormatoDM`.
- `DM4Experiment.list`, `SpectroCancellation.task`: `Core/Data/GMSFourDRegistration.swift` → `import FormatoDM` (and
  `FormatoCore`, or the SpectroKit typealias).
- `VeloxEMDReader` and its types: `tools/velox-parity`, `tools/autoid-velox-check` → `import FormatoEMD`; velox-parity's
  `-package-name spectrokit` trick is no longer needed for `readSpectrumImage`.
- Products: add `FormatoHDF5`, `FormatoDM`, `FormatoEMD` (and `FormatoCore`) to `Package.swift` and the Xcode project's
  package product dependencies wherever `SpectroCore` is linked; bump both pins.
- `tools/lib/sources.manifest` (`spectrokit_module`) builds `--target SpectroCore` from `.build/checkouts/SpectroKit`: it must
  also build FormatoKit's four targets from `.build/checkouts/FormatoKit` and link their objects (and the FormatoHDF5
  resource bundle, or keep `MAC4DSTEM_HDF5_PATH`). Comment-only paths: `hdf5-exit-race-test/main.swift:6` and `run.sh:8`,
  `velox-parity/run.sh:5`.
- libhdf5: the app embeds its own three dylibs (found first); the resource bundle note above applies.

## macTEM

It pins SpectroKit **0.2.0** exactly and links `SpectroCore` through TEMCore. What it uses from the moved files:
- `VeloxEMDReader`, `.images()`, `.readImageFrame`, `VeloxEMDError`, `VeloxImageInfo`, `VeloxImageElementType`,
  `VeloxDetectorInfo`, `SpectroCancelled`: `Sources/TEMCore/Data/VeloxImageReader.swift`, `AcquisitionMetadata+Velox.swift`,
  `tools/velox-image-parity` → `import FormatoEMD` (and `FormatoCore`, or the typealias).
- `DM4Experiment.list`, `.readImage`, `.tagTree(data:)`, `DM4ImageObject`, `DM4Axis`, `DM4Image`, `DM4Error`:
  `Data/ImageOpening.swift`, `AcquisitionMetadata+Read.swift`, `AcquisitionMetadata+TIFF.swift`, `tools/dm4-reader-parity`,
  `tools/metadata-parity` → `import FormatoDM`.
- `HDF5Serial`, `installExitBarrier`, `hid_t` and friends: `Data/SidecarHDF5.swift`, `Data/SessionSidecarFile.swift` →
  `import FormatoHDF5`. `tools/lib/copies.manifest` line 27 (SidecarHDF5 adapted from mac4DSTEM's writer) is unaffected.
- **Scripts that name SpectroKit source paths break:** `tools/lib/sources.manifest:32-38,45` lists `HDF5Types.swift`,
  `SpectroCancellation.swift`, `VeloxEMDReader.swift`, `DM4Error.swift`, `SpectroFileName.swift`, `DM4Experiment.swift` under
  `$sk/Sources/SpectroCore/...` (they are now under FormatoKit's `Sources/Formato*/`, and the cancellation and file-name
  helpers are `FormatoCancellation.swift` and `FormatoFileName.swift` in `FormatoCore`); `tools/lib/fetch-spectrokit.sh:16`
  probes `Sources/SpectroCore/Data/VeloxEMDReader.swift`; `tools/metadata-parity/run.sh` mutates `DM4Experiment.swift` by
  path.
- FormatoKit's step 2 (`FormatoTIFF`) ports macTEM's FEI / TIA metadata walker (`AcquisitionMetadata+TIFF.swift`,
  `TIFFImageReader.swift`) and its parity harnesses; macTEM's later switch to it is its own lane.

## Pin

`exact: "0.0.1"` once the owner tags it. The API is 0.0.x: it may still move, and every move is in the next consumers note.

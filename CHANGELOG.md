# Changelog

## 0.11.0 (2026-10-22)

A TIFF written by tifffile with its default metadata opens, and the scan, time and optics facts the apps asked for are exposed read-only. Additive; no byte a reader returned before changes, except the files below that were refused before.

- **tifffile's shaped series (FormatoTIFF).** `TIFFSignals` and `FormatoLoader.load` read a TIFF whose first page carries tifffile's own description (`{"shape": [...]}`, which `tifffile.imwrite(array)` stores; also `axes`, `name`, `truncated` and user keys, and the old `shape=(...)`). The rule is tifffile 2026.9.20's `series_shaped` with `check_shape`, `reshape_axes` and `pyramidize_series(reduced=True)`: the shape is the described one and is not squeezed (a length-1 dimension stays), an axis it does not name is "Q" and RosettaSciIO's name for it is "None", pages stored as one IFD with the data after it, appended series (one signal each, each with its own first page's metadata), a reduced image one pyramid step below the previous level joins it. A description tifffile cannot use (not a multiple of the page, bad JSON) falls to the generic rule, as it does. A description it raises on (no `shape` list, an axes code RosettaSciIO has no name for, data past the end of the file) is refused. A shape whose last two dimensions are not a page's rows and columns (a trailing 1) reads through the flat element order. Pinned on 48 tifffile-written files (`tools/shaped-tiff/pins.py`; `Tests/FormatoTIFFTests/Fixtures/shaped`, `shaped-pins.json`): bytes, shapes, axes, metadata and refusals equal to RosettaSciIO 049e7d70. Still refused by name: SubIFD series, OME, generic pyramids. `docs/open-items.md` item 3 is closed; the benchmark generator writes tifffile's default again.
- **DM scan pixel size (FormatoDM).** `DM4EELSSpectrumImage` and `DM4EDSSpectrumImage` carry `xAxis` and `yAxis`, the scan calibration (origin, scale, units as the file writes them, nil where it wrote none). Equal to the bit to RosettaSciIO's scan axes of the committed DM fixtures (`tools/dm-scan/pins.py`); the 4D scans' navigation axes of `DM4Datacube` are pinned the same way.
- **Velox spectrum image: live and real time, optics, pixel size (FormatoEMD, FormatoCore).** `VeloxEMDReader.spectrumImageMetadata()` returns the Metadata of the first `Data/SpectrumImage` group (nil if none), where a Velox file keeps the totals of the scan: `superXDetectors[i].liveTimeColumn0` and `.realTimeColumn0` in seconds. `VeloxMetadata.segmentTimes` (per enabled X-ray segment), `commonLiveTimeSeconds` and `commonRealTimeSeconds` (where every enabled segment states the same) read them. They are not in the signals' metadata, which stays RosettaSciIO's key for key (the parity test compares the key sets). RosettaSciIO maps neither for a spectrum image: exact against planted files only. `AcquisitionMetadata.velox(spectrumImage:)` gives a spectrum image's high tension, magnification, camera length, instrument, stage, start and pixel size under the same rules as an image entry (camera length, magnification and beam energy equal to the bit to RosettaSciIO's returned mapping on planted files; the study's SI file read 94 000x, 125 mm, 200 kV). New `AcquisitionMetadata.pixelSize` (`PixelSize`: rows, columns, unit as stored) from Velox `BinaryResult.PixelSize`, `.rosettaSciIO` convention only, equal to RosettaSciIO's axis scales after the conversion they went through (images and the SI). Planted files: `Tests/FormatoEMDTests/Fixtures/times` (`tools/velox-times/pins.py`).
- Tests: 21 new in the unit target (12 shaped TIFF, 1 loader, 2 DM, 6 Velox) and one parity test (`testShapedSeriesFilesAgreeWithRosettaSciIO`); the refuter file `tf_stack2.tif` is now read, not refused.
- Not done, as before: the GMS EDS `.dm4` geometry (no file).

**Migration.** None required. `AcquisitionMetadata` gains the field `pixelSize` (nil from every reader but Velox `.rosettaSciIO`), so a consumer that compares a whole `AcquisitionMetadata` with a value it built itself sees a difference for a Velox file; `DM4EELSSpectrumImage` and `DM4EDSSpectrumImage` gain two stored properties, so code that built one itself (their initialisers are internal; none could) is unaffected. A TIFF that threw "the file carries tifffile's shaped description" now opens; code that treated that error as "skip this file" will now get signals.

## 0.10.0 (2026-10-22)

New product `FormatoPeek` for Quick Look and Finder-style previews: what a file looks like and says without reading the file. Additive; no existing reader changes.

- `Peek.thumbnailFrame(url:maxPixels:)` returns one decimated frame (`Peek.Frame`: width, height, row-major `Float` pixels, the source size, the stride, a `kind` of `.image`, `.diffractionPattern`, `.virtualImage` or `.spectrum`, where in the file it came from). `Peek.summary(url:)` returns the header facts (`Peek.Summary`: format, title, size in pixels, scan size for 4D, pixel size and unit, data type, acquisition date, detector, instrument, voltage, camera length, magnification). Neither reads more than one frame: an image is read one row at a time, every `stride`-th row (stride = ceil(longer side / maxPixels)), the columns decimated in memory; the pixels are the file's own, point sampled, never averaged. A stack or cube is entered at the centre of its leading axes.
- Formats: DM3/DM4 (the first two-dimensional image object GMS lists, else the first stack entered at its centre, else a spectrum), Velox EMD (the image `VeloxImageSelection` chooses, HAADF first, never the spectrum cube), TIFF (first greyscale series), MRC (middle section of a stack), MSA/EMSA (the spectrum, binned to the largest value per bin), py4DSTEM-style HDF5 (a stored virtual image beside the cube if there is one, else the centre scan position's diffraction pattern). EMPAD and MIB are refused by name (`Peek.PeekError`); a consumer shows a pattern from its own reader.
- Measured on this Mac, release: the 1.66 GB Velox spectrum image of the study peeks in 0.36 s with 22 MB resident (11 MB peak footprint). `formato-peek <file> [maxPixels]` (Examples) prints both.
- `VeloxEMDReader.contents(path:)` and `VeloxContents` (FormatoEMD): what a Velox file holds, counted from its group names with one HDF5 open and nothing decoded (image groups, single spectra, EDS spectrum streams, EELS spectrum images), nil for a file that is not Velox. macTEM uses it to open a file into every room that has data in it. The three Velox study files (a HAADF + EDS file, a 16 x 16 EDS file, an EELS + EDS file) hold images and spectrum streams together, and `isVeloxFile` says yes to all of them.
- Tests: a planted gradient (1000 * row + column) at stride 1 and 4, and, for DM, Velox, TIFF, MRC, MSA and the py4DSTEM fixtures, equality with the same file read whole by the format's own reader and cut at the same stride; refusals; a footprint test on the big Velox file (skips without the data).

**Migration.** None; add the `FormatoPeek` product where you want it. An app extension links the three libhdf5 xcframeworks through it (FormatoHDF5), so measure the extension's bundle growth.

## 0.9.1 (2026-10-21)

Tests and documentation only; no source change and no byte moves.

- Exactness tests for the MIB reader rewritten in 0.9.0 (934 ms to 35 ms). The pixel codes (1, 6, 12, 24 bit, 8, 16 and 32 bit stored), the header sizes the fixtures carry and multi-frame files were already pinned byte for byte against RosettaSciIO (`pins.json`, 18 fixtures); added: every one-index slice along every axis of every fixture equals the matching slab of the RosettaSciIO bytes (crossing frame, row and flip boundaries), and an odd 513-byte header (16- and 32-bit pixels at odd addresses, the unaligned path) gives the bytes of the 384-byte file for U08, U16 and U32. The 0.8.x reader gave the same bytes, so these tests cannot fail against it: the rewrite changed speed only; they pin the new copy and byte-swap paths.
- The 0.9.0 Migration line saying SpectroKit needs no bump is corrected: apps pin FormatoKit 0.9.1 with SpectroKit 0.8.1.
- Added `docs/status.md`.

**Migration.** None.

## 0.9.0 (2026-10-21)

The 0.9.0 audit against RosettaSciIO: the parity table rewritten from the 38 plugins on disk (`docs/parity.md`), a benchmark against RosettaSciIO (`docs/benchmarks.md`), and the study-path gaps filled. Bytes read by existing readers are unchanged.

- Velox single spectra: `VeloxSpectrumSignals(path:timeZone:policy:)` returns `Data/Spectrum` as RosettaSciIO's `select_type="single_spectrum"` does: the stored counts transposed, a `Stack` axis for more than one spectrum, the `Energy` axis in keV from the detector's dispersion and offset, title "EDS", signal type `EDS_TEM`, the file name, date, time and time zone, and the metadata mapping (beam energy, camera length, magnification, microscope, stage, number of frames, detector fields). Pinned on 15 planted files under four time zones and on RosettaSciIO's public Velox files. Not mapped: `Sample.elements`.
- Velox files whose `Version.format` is "DevelopersKit" are accepted everywhere (RosettaSciIO's `is_EMD_Velox`); `VeloxEMDReader.hasVeloxVersion(path:)` is that check alone, true for a file with only single spectra.
- `FormatoMSA` is no longer empty: `MSAReader` and `MSAWriter` (`.msa`, `.ems`, `.mas`, `.emsa`), read and written byte for byte as RosettaSciIO's `msa` plugin (11 public files, 66 planted texts, 19 synthetic signals; deviations in `docs/parity.md`).
- New product `Formato`: `FormatoLoader.sniff(path:)` (extension confirmed by the first bytes) and `FormatoLoader.load(path:)` (DM objects, Velox spectra then images then spectrum images, TIFF series, MRC, MSA); EMPAD, MIB and HDF5 4D files throw `FormatoLoadError.useDedicatedReader`. `formato-info` now uses it.
- Speed: reading a Merlin MIB was 934 ms for 1024 frames of 256x256 (RosettaSciIO 29 ms): an `ISO8601DateFormatter` was built for each of the first 10 000 frame headers, and every pixel was appended to a `Data` one at a time. Now 35 ms (header timestamps read directly, pinned to the formatter over a 2000-2100 sweep; pixel runs copied and byte-swapped in place). MSA read of 65 536 points: 111 ms to 17 ms. The header split no longer goes through `components(separatedBy:)`.
- `tools/benchmarks/` (driver and the kit's `formato-bench`), `tools/velox-spectrum/pins.py`, `tools/msa/pins.py`.
- Not done, with reasons (`docs/open-items.md`): Velox live/real times and GMS EDS geometry (need Paul's files), the app asks that each need their own pins, and the slower-than-RosettaSciIO read path of DM, TIFF and 2048² Velox images (1.2 to 2x; cause not yet isolated).

**Migration.** Additive. `VeloxEMDReader.isVeloxFile`/`isVeloxEMD` now answer true for "DevelopersKit" files, which were refused before: an app that routes `.emd` files on them will open those files. Nothing else changes for a consumer. SpectroKit 0.8.x already accepts FormatoKit `0.4.0..<1.0.0`, so its source needs nothing from this release; the suite rule is still that the two are bumped together, and an app pins FormatoKit 0.9.1 with SpectroKit 0.8.1 (the 0.8.1 line corrects this sentence).

## 0.8.0 (2026-10-21)

The I/O the apps still carried moves into the kit. Bytes are unchanged everywhere; the new paths are pinned to `HDF5Reader` and to the stand-alone BraggVectors writer.

- Speed: `SharedHDF5.loadStandard()` is cached for the process (a failure is not cached). It was 53 % of a single-pattern `HDF5Reader.readDataset` (environment, bundle paths, four `dlopen`, 60 `dlsym` on every call). `HDF5SlabReader(url:path:)` holds the file and dataset open for many small reads: `read(start:count:)` and an allocation-free `read(start:count:into:)`; `close()` or `deinit` releases them. Release build, one 1x1x4 float32 slab: `HDF5Reader.readDataset` 39 us per call, `HDF5SlabReader` 0.79 us (0.69 us into a caller buffer); the investigation measured 197 us per call before the cache.
- `HDF5Reader.walk(from:maximumObjects:)`: the link walk with object identity. Every link below a group, depth first, each with its kind, link kind (`hard`, `soft`, `external`) and the object identity (`H5Oget_info_by_name3`); a group reached by a second hard link, or a cycle back to an ancestor, is listed but not entered again, and soft links are listed but not followed. Replaces the app's `HDF5LegacyProbe.linkInfo` walk.
- `HDF5Reader.attribute` reads h5py's bool (a one-byte enum with values 0 and 1) as the integers 0 and 1 (before: `unsupportedType`; another one-byte enum still is).
- `HDF5WriteSession.writeBraggVectors(peaks:scan:detector:inRoot:nodeName:convention:groupAttributes:)`: the BraggVectors object (shape bundle and `_v_uncal` peak grid) written into the session's own file next to a calibration, results and copied objects; same layout as `BraggVectorsEMD.write`, which now shares the code; a failure removes the half-built node. `HDF5PendingFile.sameFile` is public (a destination check against a second protected path, the sidecar). A datacube export already goes through `EMDDatacubeWriter`; the app's comment "no kit writes a 4D datacube" is stale.
- `EMPADReader(path:qCalibration:preferScanResolution:)`: with `true`, `scan_parameters/scan_resolution_x/y` win over `pix_x/pix_y` (default `false`, RosettaSciIO's order).
- MRC: mode 12 (half float) no longer uses `Float16`, which does not exist on x86_64 macOS; FormatoMRC builds for both architectures (macTEM's Developer ID archive was arm64-only). The conversion is exact.
- Not done, with reasons: lineage / marks records, header-less MIB, learned-detector pieces (stay in the app, as agreed); the DM4 lazy 4D gather and more-than-four-dimension objects, the Velox live/real times and GMS EDS geometry, and the Velox allocation bounds (each is a registration-sized change with its own pins; left for 0.9); `Package.swift` has no sibling-kit dependency, so there were no ranges to widen.

**Migration.** Additive. mac4DSTEM: switch `H5Reader`'s single-pattern read onto `HDF5SlabReader` and delete `HDF5LegacyProbe` (link walk with `walk(from:)`, `QR_flip` with `attribute`); move the sidecar's peak-grid write onto `writeBraggVectors` inside `HDF5NewFile.write` (the sidecar-parity run, about 35 GB, stays the app session's gate). macTEM: the archive can be universal.

## 0.7.0 (2026-10-21)

The reader asks the two apps still carried shims for, and the two 0.6.1 follow-ups. Every change is pinned to the previous
reader's bytes or to h5py / RosettaSciIO (`tools/dm4-gather/make_dm3.py` re-emits DM4 fixtures as DM3).

- `DM4Datacube`: contiguous fast path (row copies; typed Float32 conversion per row; one source offset per row instead of a per-element decode). `AlMgSi_4D_EDX.dm4` (float32 48x64x128x128, 201 MB) read whole in 0.035 s with the app layout and 0.089 s stored order, against the app reader's 0.10 s (and the kit's own 0.76 s before). DM3 files are accepted (header version 3 or 4). New `storage:` option, `.readIntoMemory`, reads the object's pixel bytes once at open (network or removable volumes) and survives the file changing. New `layout` (`DM4DatacubeLayout`: stored shape, permutation, `scanFastest`, stored and output type) so a consumer does not repeat the unit-domain rule. A declared data length of 0 is tolerated when the dimensions fit the file; a wrong non-zero length still refuses.
- `HDF5Reader`: `chunkShape(of:)`, `descendants(of:)` (recursive listing with kinds, depth and count limits), `readBooleans` (h5py's one-byte enum), and float16 datasets are read as float32 (before: refused by name; `datasetInfo` still reports `unsupported("float16")`).
- `HDF5WriteSession.copyObject(from:_:to:replace:)`: H5Ocopy of a group or dataset from another file (attributes and layout kept), the way a result moves into a new file without the space of replaced datasets.
- `BraggVectorsEMD.write` builds in the item-replacement directory like the other writers (sandbox-safe), falling back beside the destination.
- `EMPADReader`: `scan_parameters scan_resolution_x/y` give the scan under any raw file name (after `pix_x/pix_y`, before the `scan_x/y` name rule); `init(rawPath:scanSize:)` opens a raw file with no XML (name, explicit size, or a square scan from the file's length); `rawPath` is exposed.
- `MIBReader`: `pixelCode` (`U08` / `U16` / `U32`); the app convention takes any header size from 384 to 65536 (RosettaSciIO's convention still 384 and 768 only).
- 0.6.1 follow-ups: `EMDDatacubeWriter.write` checks the shape before forming any product of it (a short or huge shape throws `invalidArgument` instead of trapping); a PNG compressed-zlib round-trip test and `package` access to `adler32`.
- Not done, with reasons: lineage / marks records (two different app formats, design note, archived in the suite's private folder); header-less MIB (needs the app's width/height fallback, no reference); a public `SharedHDF5` or planting API (tests keep using h5py-written fixtures); vlen and enum writes, and in-place space reclamation (`copyObject` into a new file is the route); 3D-to-4D reshape of a DM object such as `small_datacube.dm4` (rank 3, the app reshapes by its own load specification).

**Migration.** Additive. mac4DSTEM: delete the shims marked `delete at FormatoKit 0.6.0` that this covers and switch `DM4Reader` onto `DM4Datacube(.appCalibratedAxes, storage: .readIntoMemory)` for non-local volumes (`.mapped` elsewhere), reading `layout` instead of repeating the unit-domain rule; MIB with `.appScanXY` and EMPAD acquire-mode headers lose their fallbacks; a result copy uses `HDF5NewFile` plus `copyObject`. `HDF5Reader.readDataset` of a float16 dataset now returns float32 instead of throwing.

## 0.6.0 (2026-10-20)

The format-level half of the apps' session files and exports moved into the kit: the EMD "scientific bundle" writers and the
PNG with text chunks. What an app stamps into a file (its schema keys, a map's provenance, its lineage) stays the app's and is
passed in as attributes. Design: design note, archived in the suite's private folder.

- Add to `HDF5WriteSession`: `setVariableLengthTextAttribute`, `writeText` (scalar variable-length text dataset, UTF-8 or ASCII), `writeBool` (h5py's bool enum), `createDataset` (no data written, for a file filled by slabs) and `writeSlab` (a hyperslab into an existing numeric dataset).
- Add `HDF5NewFile.write` and `HDF5PendingFile`: build a new HDF5 file under a scratch name and publish it by atomic rename over the item that was checked; a destination that is the source is refused (`HDF5FileError.destinationIsSource`). The pending form is kept across `await`s with no handle or lock held between calls.
- Add the EMD 1.0 (py4DSTEM) writers, on a session: `writeEMDFileHeader`, `createEMDRoot`, `writeEMDCalibration` (`EMDCalibration`, with origin maps, rotation convention, `_target_paths`; `EMDBooleanStorage`: h5py enum by default, the first consumer's uint8 as an option), `writeEMDScalarMap` (`RealSlice`) and `writeEMDRGBAMap` (`Array`) with caller-supplied group attributes and metadata entries.
- Add `EMDDatacubeWriter`: a float32 4D `DataCube` written a band of scan rows at a time (or whole), chunked one pattern per chunk, with a calibration, axes and the caller's attributes.
- Add `FormatoPNG` (FormatoCore): `encode` (8-bit gray, 16-bit gray, RGB, RGBA, with `tEXt` / `iTXt` chunks), `inserting` (text chunks into a PNG another encoder made), `textEntries` (read back, CRCs checked), `crc32`.
- Pinned: the first consumer's own output (mac4DSTEM Core c47a2b7a at its kit pins, run offline by `tools/emd-bundle/oracle/run.sh`; macTEM 53f612a `PNGChunks` by `tools/png/oracle.sh`) equals the kit's objects, attributes and dataset bytes; h5py and py4DSTEM 0.14.19 (`tools/emd-bundle/check.py`), Pillow 12.3.0 and zlib (`tools/png/check.py`) read the kit's files.
- `HDF5FileError` gains `destinationIsSource`.
- Not moved, with reasons in the design note: the two apps' session lineage / marks records (two different formats, not one shared), macTEM's source identity, the datacube export's reduction and calibration re-reference.

**Migration.** Source-breaking only for an exhaustive `switch` over `HDF5FileError` (already needs a `default` since 0.5.0). Otherwise additive. mac4DSTEM can replace `writeCalibratedDataCubeFile`, `writeScientificBundle`, `writeCalibration`, `writeResultMap`, `writeRGBAResultMap` and its private HDF5 write library with these calls (its reduction, re-reference and `mac4dstem_*` keys stay and become attributes); a result save becomes `HDF5AppendWriter.append` with `replace: true` instead of rebuilding the file. macTEM's `PNGChunks` becomes `FormatoPNG.inserting`. Pass `EMDBooleanStorage.uint8` to keep the app's `QR_flip` bytes; integer attributes are int64 and `UUID` / `authoring_user` are optional in `EMDFileHeader`.

## 0.5.0 (2026-10-20)

- Add `HDF5Reader` (FormatoHDF5): low-level read of any HDF5 file through the shared loader and `HDF5Serial`: `exists`, `kind(of:)`, `children(of:)`, `attributeNames(of:)`, `attribute(_:of:)`, `datasetInfo`, `readDataset` (hyperslab, as `FormatoArray`), `readStrings`. Compound, enum, array and vlen data, references, float16 datasets and attributes of rank 2 or more are refused by name. Pinned exact to h5py 3.16.0 (`tools/hdf5-append/generate.py`).
- Add `HDF5AppendWriter.append(to:mode:body:)` with `HDF5WriteSession` (`createGroup`, `writeDataset` with `chunk` and `replace`, `setAttribute`, `deleteLink`, `exists`). Default `.atomicCopy` copies the file, writes the copy and publishes it over the checked original (any failure leaves the original byte-identical); `.inPlace` is not atomic. Unrelated content is unchanged; h5py reads the appended files equal to base plus operations. No compression filters, resizing or space reclamation. Note: `.inPlace` `replace: true` unlinks the old dataset before the new one is written.
- Add `TIFFAppImage` (FormatoTIFF): the first consumer's reading of one 2D TIFF as a Float32 calibrated image, the named option beside `TIFFSignals`. Calibration order FEI SEM (PixelWidth on x, where tifffile swaps non-square axes), Velox, Digital Micrograph tags, ImageJ; BigTIFF, extra pages, stacks, compression, tiles, WhiteIsZero, palettes and unequal colour channels are refused by name. Pinned bit for bit to macTEM cb6e164's reader on 149 byte-built files. Known difference: a tag whose value lies outside the file, or of an unknown type, throws `truncated` here where the consumer ignores it.
- `HDF5FileError` gains `notFound`, `wrongKind`, `alreadyExists`, `invalidPath`, `unsupportedType`, `limitExceeded`, `invalidArgument`.

**Migration.** Source-breaking only for an exhaustive `switch` over `HDF5FileError`: add a `default` case. Otherwise additive. mac4DSTEM can move `H5Reader` and the sidecar append onto `HDF5Reader` / `HDF5AppendWriter`; macTEM's `TIFFImageReader` becomes `TIFFAppImage.read`. Float16 attributes are read; float16 datasets are not.

## 0.4.0 (2026-10-20)

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

Consumer notes for 0.0.1 to 0.2.0 are archived.

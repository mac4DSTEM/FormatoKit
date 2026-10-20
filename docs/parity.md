# Parity with RosettaSciIO

The checklist that makes "complete" a measured claim (suite ROADMAP, "Kits", phase 4). Started 2026-10-15 from RosettaSciIO
049e7d70's own format list (its 38 `rsciio/*/specifications.yaml`, the source of its supported-formats table). Updated at
every tag (last: 0.4.0, 2026-10-20). Since 0.2.0 FormatoKit's own refusals marked as policies (unconverted Velox
units, the spectrum-image grid check, TIFF vendor branches, the DM string limit) are parameters (`docs/registration-0.2.0.md`). "Pinned" means a gate compares FormatoKit with RosettaSciIO bit for bit on that format's files; "read" means a
reader exists without that gate.

## The formats

Priority: **A** the owner's data needs it (the order of the format lanes), **B** common in materials TEM, **C** other
instruments and techniques, out of scope until someone asks.

| RosettaSciIO plugin | Extensions | RosettaSciIO writes | FormatoKit module | State | Priority |
|---|---|---|---|---|---|
| DigitalMicrograph | dm3, dm4 | no | `FormatoDM` | **pinned** (step 1): every object as a signal; 106 public signals and the owner's 40 bit for bit; the moved `DM4Experiment` API; lazy 4D gather `DM4Datacube` (stored order and app layout, pinned) | A |
| EMD, Velox | emd | no | `FormatoEMD` | **pinned** for images as signals (step 1; stored type and titles, step 3) and for spectrum images as signals (step 4: EDS from the streams and EELS, every option); the moved spectrum-stream API as SpectroKit uses it; the detectors in RosettaSciIO's order (0.0.3); single spectra (`Data/Spectrum`) not read | A |
| EMD, NCEM / Berkeley | emd | yes | `FormatoEMD` | not read | B |
| EMD, prismatic | emd | no | — | not read | C |
| TIFF | tif, tiff | yes | `FormatoTIFF` | **pinned** (step 2) for FEI, Gatan DM tags, ImageJ and plain files, uncompressed strips: 31 public and planted series and the owner's 6 Ceta TIFFs bit for bit; the tag walker equal to tifffile; Zeiss SEM, TVIPS, Olympus SIS, JEOL SightX, Hamamatsu streak, compression and tiles refused by name | A |
| TIA | ser, emi | no | `FormatoTIFF` or its own module | not read | B |
| MRC | mrc, ali | no | `FormatoMRC` | **pinned**: `MRCReader` (lazy; modes 0 uint8, 1, 2, 6; header little-endian whatever the stamp; nm axes; size-1 axes squeezed; FEI 128-byte pixel size in float32; complex64 and float16 refused: no `FormatoDataType`), bit for bit at 049e7d70 on synthetic files; `MRCAppImage` is the named consumer option (signed mode 0, stamp honoured, Angstrom, stacks refused, Float32) pinned to macTEM cb6e164; acquisition metadata: see the section below | B |
| MRCZ | mrc, mrcz | yes | `FormatoMRC` | not read | C |
| EMPAD | xml (+ raw) | no | `FormatoEMPAD` | **pinned**: mmap Float32 frames, footer removal, scan/series shapes, squeezed axes, both XML navigation calibrations, diffraction calibration and timestamp metadata; synthetic full-byte pins at 049e7d70 | A |
| py4DSTEM / EMD 1.0 (py4DSTEM f050d207, h5py 3.11.0) | h5, hdf5, emd | — | `FormatoHDF5` | **pinned** for explicit rank-four numeric datasets: stored bytes and shape, hyperslabs, R/Q axes, flip, rotation, ellipse, probe semiangle, lazy origin maps. Compressed Float32 and big-endian UInt16 synthetic files; uniform generic dimension vectors and scalar attributes checked with h5py; nonlinear coordinates refused | A |
| py4DSTEM BraggVectors / EMD 1.0 (py4DSTEM f050d207 0.14.19, emdfile 0.0.15, h5py 3.11.0) | h5, hdf5, emd | — | `FormatoHDF5` | **read and write, pinned**: the `_v_uncal` vlen `{qx,qy,intensity}` float64 peak grid, `Rshape`/`Qshape`, the calibration scalars (`Q/R_pixel_size/units`, `QR_flip`, `QR_rotation(_degrees)`, `qx0/qy0_mean`, `a`, `b`, `theta`, `probe_semiangle`). Peaks read bit for bit from py4DSTEM-written files; what Swift writes is read back by py4DSTEM (`tools/bragg-writer/check.py`, result pinned with the files' SHA-256) and h5py shows the same group, dataset, dtype and attribute structure as a py4DSTEM-written file. Reference axes are primary (`qx` = detector row); `BraggAxisConvention.appImageXY` is the mac4DSTEM image convention (x = column, y = row), pinned to the app writer's swap. Atomic publish (sibling temporary file, rename), destination = source refused. Origin maps, `_v_cal` and mac4dstem_* attributes (a hook; the app owns them) are not written; non-finite peaks are refused on write | A |
| QuantumDetector (Merlin) | mib | no | `FormatoMIB` | **pinned**: processed U08 (1/6-bit), U16 (12-bit), U32 (24-bit), header metadata, explicit/trigger/timestamp shapes, interrupted lines, frame slices and singleton squeeze. Packed R64 raw headers at all four depths are refused, as in rsciio. Named `appScanXY` option pins ScanX/ScanY, unflipped orientation and Float32 conversion to app c809679c | B |
| Arina (Dectris) | h5 | no | — | not read | B |
| HSPY | hspy, hdf5 | yes | `FormatoHDF5` | not read; with the sidecar | B |
| ZSPY | zspy | yes | — | not read | C |
| MSA | msa, ems, mas, emsa | yes | `FormatoMSA` | empty | B |
| Bruker | bcf, spx | no | — | not read | B |
| EDAX | spd, spc, lsd | no | — | not read | B |
| JEOL | asw, img, map, pts, eds | no | — | not read | B |
| Blockfile (NanoMegas) | blo | yes | — | not read | B |
| TVIPS | tvips | yes | — | not read | C |
| DENS | dens | no | — | not read | C |
| Delmic | h5, hdf5 | no | — | not read | C |
| DigitalSurf | sur, pro | yes | — | not read | C |
| Hamamatsu | img | no | — | not read | C |
| Image (Pillow) | png, bmp, gif, jpeg, … | yes | — | not read | C |
| Impulse | csv | no | — | not read | C |
| JobinYvon | xml | no | — | not read | C |
| netCDF | nc | no | — | not read | C |
| NeXus | nxs | yes | — | not read | C |
| numpy | npy | yes | — | not read | C |
| PantaRhei | prz | yes | — | not read | C |
| Phenom | elid | no | — | not read | C |
| Protochips | csv | no | — | not read | C |
| Quadstar | sac, sbc | no | — | not read | C |
| Renishaw | wdf | no | — | not read | C |
| Ripple | rpl | yes | — | not read | C |
| Semper | unf | yes | — | not read | C |
| Tofwerk | h5 | no | — | not read | C |
| Topspin | app5 | no | — | not read | C |
| TriVista | tvf | no | — | not read | C |
| USID | h5, hdf5 | yes | — | not read | C |

Totals at 0.3.1 (42 rows: RosettaSciIO's plugins and formats, plus the two py4DSTEM rows): 8 pinned (DigitalMicrograph, Velox EMD, TIFF, MRC, EMPAD,
py4DSTEM EMD 1.0, py4DSTEM BraggVectors, Merlin), 1 empty (MSA), 33 not read.

## Reader options (RosettaSciIO 049e7d70's `file_reader` arguments, for the formats FormatoKit holds)

| Plugin | Argument | FormatoKit |
|---|---|---|
| DigitalMicrograph | `lazy` | always lazy (`FormatoLazySignal`, positioned reads); `load()` is the eager array, registered equal (L1) |
| | `order`, `optimize`, `chunks` | no: C order as stored; dask chunking has no counterpart |
| EMD (Velox) | `lazy` | images lazy per frame (L1); spectrum images eager, as RosettaSciIO's `lazy=False` (its `lazy=True` sparse COO path, whose float counts beyond 2^24 differ, is not ported); the moved spectrum-stream reader decodes eagerly into CSR |
| | `select_type="images"` | `VeloxImageSignals`: stored type and RosettaSciIO's titles (step 3) |
| | `select_type="spectrum_image"`, `first_frame`, `last_frame`, `sum_frames`, `sum_EDS_detectors`, `rebin_energy`, `SI_dtype` | `VeloxSpectrumImageSignals` with `VeloxSpectrumImageOptions` (step 4): all six, RosettaSciIO's defaults, pinned on 10 public, 12 planted and 6 SpectroKit files over ten option sets. The moved `VeloxEMDReader.readSpectrumImage(frames:)` keeps SpectroKit's rules |
| | `select_type="single_spectrum"` | no |
| | `load_SI_image_stack` | the default only (the first frame of an SI file's images) |
| | `dataset_path`, `stack_group` (NCEM / Berkeley EMD) | no: NCEM EMD is not read |
| TIFF | `lazy` | always lazy (L1) |
| | `force_read_resolution`, `multipage_as_list`, `hamamatsu_streak_axis_type` | no: refused branches, or the default |
| EMPAD | `lazy`, `q_calibration` | always memory-mapped; `EMPADReader(path:qCalibration:)`, XML calibration by default |
| | `remove_nans` | default false only: preserves all stored Float32 bits |
| Writers (EMD NCEM, TIFF) | `file_writer` | no writing yet |

## Inside the pinned formats: what is not yet equal

- **TIFF vendor branches not ported:** Zeiss SEM (`sem`), TVIPS, Olympus SIS, JEOL SightX, Hamamatsu streak (11 of the
  public files); `force_read_resolution`; `multipage_as_list`. Each is refused by name.
- **TIFF layouts:** compression (LZW, Deflate, JPEG, PackBits: imagecodecs in Python), tiles, planar 2, palettes applied,
  YCbCr, bit depths other than 8/16/32/64. Refused by name.
- **TIFF tags tifffile drops or reads elsewhere:** unknown types are kept by the walker (tifffile drops them); pointer tags
  keep their stored field (tifffile reads the structure). The Velox XML 34683 and TIA tags are read as stored, not
  interpreted (no RosettaSciIO rule to port).

- **DM types refused by name:** complex64 and complex128 (types 3, 13), packed complex (27, 28, 5), RGB (8, 23), bool (14):
  RosettaSciIO reads them (47 of the public signals). Next DM lane.
- **DM metadata mapping:** step 1 maps the title, the file name, the signal type and the beam energy. RosettaSciIO's mapping
  also covers date and time, stage tilts, magnification, camera length, the EELS and EDS detector fields, exposure, the CL
  fields and the intensity calibration: each to be added with its pins.
- **DM post-processing:** RosettaSciIO's `to_signal1D` for a spectrum image and `squeeze` are HyperSpy's step; FormatoKit
  returns the file reader's dictionary, as RosettaSciIO's `file_reader` does.
- **DM EDS axis names:** RosettaSciIO names an EDS energy axis "x" (its `("EDS", "EDX")` test never matches its own "EDS_TEM");
  FormatoKit does the same on purpose (amendment A4.2). A fix belongs upstream first.
- **DM big-endian files** are refused by name (the Gate B refuter generated some); none exists in the public set.
- **Malformed DM files RosettaSciIO raises on** and FormatoKit reads with defaults: a calibration without `Units`, no
  `Calibrations`, no `ImageTags`, a `source` group without `Tags at creation`; and more calibration groups than dimensions
  (RosettaSciIO takes the last n, FormatoKit the first n); empty or array-only `spim` / `spim.eels` / `Monarc Spectrometer`
  groups; tag names holding "."; strings over 4 KiB (registration A5). The moved DM walk does not expose these; a later
  registered change of it can.
- **Velox images: stored type and titles (equal since step 3).** Every public, planted and owner image in its stored type
  and with RosettaSciIO's title (`Operations`, `DetectorInformation`, the label maps); `docs/registration-step-3.md`. Left:
  an `Operations` kind or `Displays/ImageDisplay` stored as one dataset instead of a group is refused (Python iterates
  its JSON in written order); no file seen has one.
- **Velox compound images** (FFT, DPC) are refused; RosettaSciIO returns them complex.
- **Units outside FormatoUnits** (m and s with SI prefixes, their inverses, dimensionless) refuse the image: Pint also
  reads "px", "Å", "nanometre" and more (registration A5, F7).
- **Velox spectrum images (equal since step 4).** EDS and EELS spectrum images as RosettaSciIO's `select_type="spectrum_image"`
  returns them, every option, the counts wrapping in the stream's type as its jitted loop does (`docs/registration-step-4.md`).
  Left, registered deviations (refused here where RosettaSciIO reads): a first image whose grid differs from ScanSize x
  ScanArea; a stream that is not one uint16 column; a channel at or beyond the bin count (RosettaSciIO writes outside the
  voxel); frames not summed with no frame left or `last_frame` 0; streams of different bin counts read apart; no FrameTime with
  frames not summed; numpy dtype aliases as `StreamEncoding`; EELS in a type outside the ten or with string calibrations. Not
  ported: `lazy=True`, `select_type=None` / `"single_spectrum"`, `load_SI_image_stack`.
- **Velox detector order (equal since 0.0.3):** `VeloxMetadata.detectors` follows the written order of the `Detectors` keys,
  as RosettaSciIO's `json.loads`, so the energy axis and the detector-metadata match take the same entry (registration step 1
  A7). Left: a key written twice in one object reads its first value here and its last in Python (no file seen has one).
- **Velox metadata mapping:** step 1 maps the file name and the beam energy; RosettaSciIO also maps the camera length,
  magnification, instrument, stage, detector and EDS fields.
- **Lazy reading:** registered equal to eager (gate L1) for DM (positioned reads) and Velox images (per frame). Not yet
  memory-mapped; no chunked HDF5 reads beyond the moved reader's blocks.
- **Writing:** none for RosettaSciIO's formats. FormatoKit writes only `BraggVectorsEMD` (py4DSTEM EMD 1.0), `HDF5RootAttributes` (a sidecar's root string
  attributes) and `FormatoFileWrite` (a Foundation file replace helper); see the sections below.

## Merlin conventions

`MIBReader` defaults to RosettaSciIO `file_reader` at 049e7d70: fastest-first `navigationShape`, Python frame slices, singleton squeezing then a flip of the penultimate axis, integer pixels and timestamp/exposure metadata. Malformed/trailing partial frames are refused rather than silently truncated. Timestamp inference accepts UTC timestamps with up to nine fractional digits. No writable mmap, dask chunks or raw unpacking.

`MIBConvention.appScanXY` uses the original reader at c809679c: a required ScanX/ScanY companion, 1x1 / 2x2 / 2x2G assemblies, unsqueezed scan axes, no flip, and Float32 conversion (including UInt32 rounding). Slicing/explicit navigation are refused in this convention. Both references refuse raw R64. `tools/mib/generate.py` compiles the pinned app initializer and pixel reader with an identity crop/bin view, records its output bytes, and pins rsciio data, axes and mapped metadata. All fixtures are synthetic, compressed and under 1 MB together.

## Acquisition metadata and file writing (FormatoCore)

`AcquisitionMetadata` / `MetadataReading` carry high tension, magnification, camera length, detector, dwell, exposure,
date, instrument and mode with rules (a) to (g) stated in the source header. They are not a RosettaSciIO structure:
each format reader compares its values with rsciio's metadata (see the DM, MRC, TIFF and Velox rows) and states where
the nil and unit rules differ. `GuardedXML` has no rsciio counterpart (rsciio parses unguarded); `FormatoFileWrite.write`
is a Foundation helper. `formatoDisplayFileName` equals the app's `displayFileName` (test `testDisplayFileNameEqualsTheAppsCopy`).

## Acquisition metadata (round 4, `tools/acq-metadata`)

Every reader below takes a convention. **`.rosettaSciIO`** (default): RosettaSciIO 049e7d70's `mapping` applied the way HyperSpy applies
it, for every field it maps (no positivity rule, its tag choices and mode tests, its unit arithmetic); a field it does not map is read by
the consumer's rule and labelled `AcquisitionMetadata.unvalidatedNote`. **`.app`**: the consumer's reader, compiled unchanged from macTEM
cb6e164 and pinned. Pins: synthetic files written byte by byte (`generate.py`), RosettaSciIO's returned mapping, the consumer's output.

| Format | RosettaSciIO maps | `.rosettaSciIO` differs from `.app` by |
|---|---|---|
| DM (`AcquisitionMetadata.dm`) | beam energy, camera length, magnification, dwell, camera exposure, mode, microscope, date, time | a stack-builder image is read from `source.Tags at creation` instead of the direct tags; zero and negative values are kept; camera length is `STEM Camera Length` in every non-TEM mode (SEM included) and `Indicated Magnification` for TEM diffraction; the mode is STEM / SEM / TEM; the dwell and exposure follow the signal type (EELS: its acquisition time; X-ray: neither; CL: the DigiScan sample time; an image: the DigiScan sample time, else the detector exposure) and the exposure has no second copy; from 0.3.1 also the stage, probe current, operator, specimen and the EELS, X-ray (EDS), CL and SI groups (`signalNumbers`/`signalTexts`, keyed by RosettaSciIO's metadata path; the last parsing date source wins, as the mapping order has it); the instrument is untrimmed. Date and time are joined into one stamp; dateutil's guessing is not ported (the layouts in the source header only). |
| MRC (`.mrc`) | magnification, exposure, stage tilts and position of the 128-byte per-section FEI header (NEXT = 128 KiB) | `.app` reads the FEI1/FEI2 extended-header record by bitmask (HT, camera length, dwell, detector, date, instrument, mode); `.rosettaSciIO` reads neither (RosettaSciIO does not) and ignores the machine stamp. |
| TIFF, FEI SEM INI (`tiff`) | `mapping_fei`: HV, dwell, date, time, system type, stage x/y/z/rotation/tilt, working distance, beam current, user | zero HV and dwell are kept; the date goes through the kit's dateutil port (day-first above 12 as the app); the detector is unmapped and labelled. |
| TIFF, Velox XML (tag 34683) | none (no plugin reads the tag); the same schema's EMD mapping | acceleration voltage and camera length (every mode) are the EMD mapping's `float(x) / 1e3` and `* 1e3`, unguarded; from 0.3.1 the microscope is `Instrument/InstrumentClass` (the model in `instrumentModel`) and the stage is the EMD mapping's; the other values keep the app's rules and are labelled. |
| EMD, Velox (`velox`) | beam energy, camera length (every mode), `StemMagnification` as magnification, `InstrumentClass` as microscope, stage tilts and position | `.rosettaSciIO`: the microscope is `InstrumentClass` (0.3.1; `VeloxMetadata.instrumentClass`), the stored model is `instrumentModel`, labelled; stage tilts (radians to degrees, 3 decimals) and position (6 decimals) as RosettaSciIO rounds them (position needs all three coordinates). Magnification, camera length, exposure and mode are read (the app leaves them `unread`); `.app` reads none of the 0.3.1 fields. |

## Acquisition metadata coverage (0.3.1)

For each format FormatoKit reads: what RosettaSciIO 049e7d70 maps into `metadata` (its `original_metadata` to `metadata` mapping, applied as HyperSpy
applies it) against what `AcquisitionMetadata` (`.rosettaSciIO` convention) or the reader's own signal metadata exposes. **R** = read and pinned to
RosettaSciIO; **N** = RosettaSciIO maps it, the file can carry it, FormatoKit does not read it; **-** = RosettaSciIO maps nothing for this format
(or the file does not carry it); **L** = read by the consumer's rule and labelled `unvalidated`. EMPAD and MIB have no `AcquisitionMetadata`: their
RosettaSciIO `metadata` is returned whole on the signal (pinned, `docs/parity.md` rows above). The 4D HDF5 (py4DSTEM EMD 1.0) reader has no
RosettaSciIO plugin to compare with: its calibrations are the file's (`R/Q_pixel_size`, `probe_semiangle`), not acquisition metadata.

| Field | DM | MRC (FEI 128 B) | TIFF FEI SEM | TIFF Velox | EMD Velox | EMPAD | MIB |
|---|---|---|---|---|---|---|---|
| beam energy | R | - | R | R | R | - | - |
| magnification | R | R | - | L | R | - | - |
| camera length | R | - | - | R | R | - | - |
| convergence angle | R (EELS signal) | - | - | - | - | - | - |
| collection angle | R (EELS signal) | - | - | - | - | - | - |
| dwell time | R (image, CL, EELS scan) | - | R | L | L | - | R |
| exposure time | R (image, EELS) | R | - | L | R | - | - |
| microscope | R | - | R | R (`InstrumentClass`) | R (`InstrumentClass`) | - | - |
| detector | L | - | L | L | L | - | - |
| date, time | R | - | R | L | R (time zone: the Mac's) | R | R |
| acquisition mode | R | - | - | L | R (code) | - | - |
| stage tilt alpha, beta | R | R | R (`StageT` as alpha) | R | R | - | - |
| stage x, y, z | R | R | R | R | R | - | - |
| stage rotation | - | - | R | - | - | - | - |
| working distance (SEM) | - | - | R | - | - | - | - |
| beam current | R | - | R | - | - | - | - |
| operator | R | - | R | - | - | - | - |
| specimen description | R | - | - | - | - | - | - |
| probe area | - | - | - | - | - | - | - |
| EELS acquisition time, frame count, aperture, spectrometer | R | - | - | - | - | - | - |
| EDS (TEM) elevation, azimuth, solid angle, live and real time | R (X-ray signal) | - | - | - | per detector in the spectrum-image readers | - | - |
| CL spectrometer, detector, grating, wavelengths, frames, integration time, format; SI mode and drift | R (CL signal) | - | - | - | - | - | - |
| Velox EDS number of frames, detector gain/offset | - | - | - | - | read by the spectrum-image readers (`VeloxSpectrumImageSignals`) | - | - |

"Probe area" is mapped by none of the RosettaSciIO plugins compared here. Conversions follow RosettaSciIO per format and are named in each reading's
`note` (DM stage position stored value x 1e-3; Velox degrees to 3 decimals and metres to 6; MRC and the FEI INI as stored): RosettaSciIO's own units
are not uniform across formats. Edges: the DM signal-type groups are keyed by RosettaSciIO's spelling of the tag names (spaces, as DM writes them);
array-valued tags (CCD read area, pixel size as a pair, binning pair) are not in the kit's scalar tag maps and are not read. DM EELS scan dwell is
`seconds x 1e6` in `dwellUS` (the pin divides back; exact for dyadic times). RosettaSciIO's other TIFF vendor mappings (JEOL SightX, Zeiss SEM, TVIPS)
are out of scope: the kit refuses those branches by name. The Velox `.emd` reader reads each stage coordinate alone since 0.3.1.

**Still missing at 0.3.1.** (1) Array-valued DM tags (CCD read area, pixel size as a pair, binning pair): the kit's tag maps are scalar. (2) DM signal-group tag names are matched in DM's own spelling, not slug-equivalent; a differently spelled tag is missed (checking needs a real vendor file). (3) RosettaSciIO's other TIFF vendor mappings (JEOL SightX, Zeiss SEM, TVIPS): refused by name. (4) Probe area: mapped by none of the compared plugins. (5) EMPAD and MIB have no `AcquisitionMetadata` (their RosettaSciIO `metadata` is returned on the signal, pinned). (6) 4D HDF5 / EMD 1.0: no RosettaSciIO plugin to compare with.

## Image readers (round 4)

- **MRC** `MRCReader` equals RosettaSciIO's `file_reader` (data bytes, dtype, shape, axes names, sizes, scales and offsets bit for bit) on 17
  synthetic files (`tools/acq-metadata/generate.py`): float32/int16/uint16/uint8 images, a stack, origins, zero cell lengths and samplings, a squeezed
  y axis (the axes shift as RosettaSciIO's do), an FEI header, a non-FEI extended header; mode 3, a big-endian file read as little-endian and a
  truncated file raise in both. Not read: modes 4 and 12 (read by RosettaSciIO; the data model has no complex or float16 type), the DE movie
  files, `navigation_shape`, `metadata_file`. `MRCAppImage` is the consumer's option.
- **TIFF, Velox pixel size** `TIFFReadOptions.veloxCalibration` (default off): RosettaSciIO reads no calibration from tag 34683, so the default
  axes equal its (uncalibrated) axes on all 11 pinned files; with the option the Velox XML pixel size is read as the consumer reads it
  (unit attributes as stored, cross-checked against tags 65450-65452, FEI SEM tags first, a refused XML falls through). Pinned to macTEM cb6e164.
- **EMD, Velox object rule** `VeloxImageSelection` (consumer option; RosettaSciIO returns every image): `choose` and `axes(of:)` pinned to macTEM
  cb6e164 on 7 synthetic images and 5 subsets. Its axes differ from `VeloxImageSignals`: the y unit is `PixelUnitY` (RosettaSciIO uses `PixelUnitX`)
  and the origin is in pixels.

## HDF5 root attributes (round 4)

`HDF5RootAttributes` has no RosettaSciIO counterpart (RosettaSciIO's HSPY writer is a different layout). It is pinned by h5py 3.16.0
(`tools/hdf5-write/generate.py`): files h5py writes (fixed-length UTF-8 and ASCII scalars, an empty text, 30 000 bytes) read back equal; files h5py
writes that the reader must refuse (variable-length, array, integer, embedded NUL, non-UTF-8, dense storage, not HDF5) are refused by name; and h5py
reads the golden file this writer produced as fixed-length, exactly as long as the text, character set UTF-8, null padding, scalar, no groups.

The golden file `kit-written.h5` is compared with a fresh write by size, the HDF5 signature, the superblock version byte and the attributes read back
(HDF5 stamps times into checksummed headers, so the bytes are not equal); the byte-level layout is pinned through h5py's reading of it
(`kit-written.h5py.json`). To regenerate the golden on purpose (a changed layout), run
`FORMATO_WRITE_GOLDEN=1 swift test --filter HDF5RootAttributesTests` and then `tools/hdf5-write/generate.py` for the h5py pins; the run that regenerates it compares the golden with itself, so
run the suite again without the variable. The regenerated files are committed on their own with the reason.

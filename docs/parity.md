# Parity with RosettaSciIO

The checklist that makes "complete" a measured claim (suite ROADMAP, "Kits", phase 4). Started 2026-10-15 from RosettaSciIO
049e7d70's own format list (its 38 `rsciio/*/specifications.yaml`, the source of its supported-formats table). Updated at
every tag (last: the 0.2.0 candidate, 2026-10-15). Since 0.2.0 FormatoKit's own refusals marked as policies (unconverted Velox
units, the spectrum-image grid check, TIFF vendor branches, the DM string limit) are parameters (`docs/registration-0.2.0.md`). "Pinned" means a gate compares FormatoKit with RosettaSciIO bit for bit on that format's files; "read" means a
reader exists without that gate.

## The formats

Priority: **A** the owner's data needs it (the order of the format lanes), **B** common in materials TEM, **C** other
instruments and techniques, out of scope until someone asks.

| RosettaSciIO plugin | Extensions | RosettaSciIO writes | FormatoKit module | State | Priority |
|---|---|---|---|---|---|
| DigitalMicrograph | dm3, dm4 | no | `FormatoDM` | **pinned** (step 1): every object as a signal; 106 public signals and the owner's 40 bit for bit; the moved `DM4Experiment` API | A |
| EMD, Velox | emd | no | `FormatoEMD` | **pinned** for images as signals (step 1; stored type and titles, step 3) and for spectrum images as signals (step 4: EDS from the streams and EELS, every option); the moved spectrum-stream API as SpectroKit uses it; the detectors in RosettaSciIO's order (0.0.3); single spectra (`Data/Spectrum`) not read | A |
| EMD, NCEM / Berkeley | emd | yes | `FormatoEMD` | not read | B |
| EMD, prismatic | emd | no | — | not read | C |
| TIFF | tif, tiff | yes | `FormatoTIFF` | **pinned** (step 2) for FEI, Gatan DM tags, ImageJ and plain files, uncompressed strips: 31 public and planted series and the owner's 6 Ceta TIFFs bit for bit; the tag walker equal to tifffile; Zeiss SEM, TVIPS, Olympus SIS, JEOL SightX, Hamamatsu streak, compression and tiles refused by name | A |
| TIA | ser, emi | no | `FormatoTIFF` or its own module | not read | B |
| MRC | mrc, ali | no | `FormatoMRC` | empty | B |
| MRCZ | mrc, mrcz | yes | `FormatoMRC` | not read | C |
| EMPAD | xml (+ raw) | no | `FormatoEMPAD` | **pinned**: mmap Float32 frames, footer removal, scan/series shapes, squeezed axes, both XML navigation calibrations, diffraction calibration and timestamp metadata; synthetic full-byte pins at 049e7d70 | A |
| py4DSTEM / EMD 1.0 (py4DSTEM f050d207, h5py 3.11.0) | h5, hdf5, emd | — | `FormatoHDF5` | **pinned** for explicit rank-four numeric datasets: stored bytes and shape, hyperslabs, R/Q axes, flip, rotation, ellipse, probe semiangle, lazy origin maps. Compressed Float32 and big-endian UInt16 synthetic files; uniform generic dimension vectors and scalar attributes checked with h5py; nonlinear coordinates refused | A |
| QuantumDetector (Merlin) | mib | no | `FormatoEMPAD` or its own | not read | B |
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
- **Writing:** none.

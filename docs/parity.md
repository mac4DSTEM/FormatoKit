# Parity with RosettaSciIO

The coverage table of the kit against RosettaSciIO's public API, rewritten by the 0.9.0 audit (2026-10-21) from source on disk:
the 38 plugins of RosettaSciIO 0.14.0 (`References/python/rsciio`, `rsciio/*/specifications.yaml`, each `file_reader` and `file_writer`
signature, each `tests/test_*.py`). The kit's pins stay at RosettaSciIO `049e7d70` (0.14.1.dev96, `References/rsciio-venv`): it is
a development commit that differs from the 0.14.0 release on disk. For the formats the kit holds the differences are: Velox (049e7d70
reads FFT/DPC stacks frame by frame and adds `EelsSpectrumImage`, which 0.14.0 lacks), EMPAD (049e7d70 takes the scan size from a
`scan_xxx_yxx.raw` file name when `pix_x`/`pix_y` are absent; 0.14.0 takes `scan_parameters/scan_resolution_x/y`; the kit has both, since
0.7.0), TIFF (049e7d70 also accepts the Greek mu U+03BC in units); plus unrelated plugins (Bruker, EDAX, Blockfile, JobinYvon, Quadstar,
Renishaw, TriVista, `hspy`/`zspy`, and test files). The single-spectrum, MSA, DM, MRC and MIB code are identical in both. "Pinned" means a gate compares FormatoKit with RosettaSciIO on that format's files (D17: numerics are
held to the tolerance the Python package's own tests use; readers, I/O, indices and metadata are exact); "read" means a reader exists
without that gate.

**Totals (the 38 plugins; `emd` is one plugin with the Velox variant read and NCEM, prismatic, DE5 missing): 2 present, 5 partial,
31 missing.** Present: MIB, MSA. Partial: DigitalMicrograph, EMD, TIFF, MRC, EMPAD. By priority of the 31 missing: 0 study, 10 useful, 21 not planned.
Beside the 38 the kit has rows with no RosettaSciIO plugin (below): py4DSTEM EMD/BraggVectors, the EMD bundle writers, `HDF5Reader`, PNG
text chunks, the TIFF app image.

Priority: **study** the owner's study path (the TEM study, the two apps' open kit asks); **useful** common in electron-microscopy
work or a 4D-STEM/EDS source; **not planned** other techniques or no consumer (reason in the note). State: **present** = the plugin's
default reader (and writer where it writes) pinned, deviations listed; **partial** = reads with the refusals listed; **missing**.
The tolerance column is the counterpart's own test file and the kind of comparison it uses (NumPy `allclose` defaults are rtol 1e-7,
atol 0; where a test passes its own, "explicit" is stated: calibrations are 1e-5 there). Readers are held exact here, stricter than
every one of these, as D17 prescribes for readers.

## The 38 plugins

| Plugin | Extensions | Writes | Kit symbol | State | RosettaSciIO test and tolerance | Priority | Note |
|---|---|---|---|---|---|---|---|
| DigitalMicrograph | dm3, dm4 | no | `FormatoDM` `DMFile`, `DM4Datacube` | **partial** | test_digitalmicrograph.py: allclose, approx, array_equal, explicit rtol/atol/decimal in places | study | complex, RGB, bool, big-endian refused; metadata mapping partial; scan pixel size of EELS/EDS spectrum images (`xAxis`, `yAxis`, 0.11.0) and of 4D scans pinned to the bit; a rank-3 stack with "Scan shape X/Y" tags reads as 4D (py4DSTEM's reshape, planted, exact); more than four dimensions and a DM3 pixel array declaring length 0 refused by name |
| EMD | emd, de5 | yes | `FormatoEMD` `VeloxImageSignals`, `VeloxSpectrumImageSignals`, `VeloxSpectrumSignals` (0.9.0) | **partial** | test_emd_ncem.py, test_emd_prismatic.py, test_emd_velox.py: allclose, almost_equal, array_equal, deep_almost_equal (allclose), equal, explicit rtol/atol/decimal in places | study | Velox: images, spectrum images (live and real time per detector from the SI group, 0.11.0), single spectra, "DevelopersKit" accepted; compound FFT/DPC, `lazy=True` SI, `load_SI_image_stack`, `Sample.elements` not. NCEM/Berkeley EMD, prismatic and DE5: missing (useful) |
| TIFF | tif, tiff | yes (some dims) | `FormatoTIFF` `TIFFSignals`, `TIFFAppImage` | **partial** | test_tiff.py: allclose, deep_almost_equal (allclose), equal, explicit rtol/atol/decimal in places | study | uncompressed strips; FEI, Gatan, ImageJ, plain, tifffile shaped series (0.11.0); OME, SubIFD series, generic pyramids, Zeiss SEM, TVIPS, Olympus SIS, JEOL SightX, Hamamatsu, compression, tiles refused by name |
| MRC | mrc, ali | no | `FormatoMRC` `MRCReader`, `MRCAppImage` | **partial** | test_mrc.py, test_mrcz.py: almost_equal, array_almost_equal, array_equal, deep_almost_equal (allclose), equal, explicit rtol/atol/decimal in places | study | modes 0,1,2,6,12 and 4 refused (complex); DE movie options (`virtual_images`, `external_images`, `scan_file`), `navigation_shape`, `metadata_file` missing |
| EMPAD | xml | no | `FormatoEMPAD` `EMPADReader` | **partial** | test_empad.py: allclose | study | `remove_nans` default false only |
| QuantumDetector | mib | no | `FormatoMIB` `MIBReader` | **present** | test_quantumdetector.py: allclose | study | R64 raw refused as rsciio does; header-less MIB missing (app ask) |
| MSA | msa, ems, mas, emsa | yes (some dims) | `FormatoMSA` `MSAReader`, `MSAWriter` (0.9.0) | **present** | test_msa.py: allclose, deep_almost_equal (allclose) | study | read and write byte-pinned; deviations in the MSA section |
| Arina | h5 | no | — | **missing** | test_arina.py:  | useful | Dectris Arina 4D detector HDF5; a 4D-STEM source |
| Blockfile | blo | yes (some dims) | — | **missing** | test_blockfile.py: allclose, deep_almost_equal (allclose), equal, explicit rtol/atol/decimal in places | useful | NanoMegas ASTAR 4D-STEM blockfile (read and write) |
| Bruker | bcf, spx | no | — | **missing** | test_bruker.py: allclose, array_equal, deep_almost_equal (allclose), explicit rtol/atol/decimal in places | useful | BCF/SPX EDS spectrum images; a study-adjacent EDS source |
| Delmic | h5, hdf5 | no | — | **missing** | test_delmic.py: allclose, almost_equal | not planned | cathodoluminescence SEM HDF5 |
| DENS | dens | no | — | **missing** | test_dens.py: allclose | not planned | heating-holder log (DENSsolutions) |
| DigitalSurf | sur, pro | yes | — | **missing** | test_digitalsurf.py: allclose, explicit rtol/atol/decimal in places, isclose | not planned | surface profilometry |
| EDAX | spd, spc | no | — | **missing** | test_edax.py: allclose, equal, explicit rtol/atol/decimal in places | useful | SPD/SPC EDS |
| Hamamatsu | img | no | — | **missing** | test_hamamatsu.py: allclose, explicit rtol/atol/decimal in places | not planned | streak camera; TIFF branch refused by name |
| HSPY | hspy, hdf5 | yes | — | **missing** | test_hspy.py: allclose, array_almost_equal, array_equal, deep_almost_equal (allclose), equal | useful | HDF5 layout of HyperSpy; with the sidecar; needs compound/vlen HDF5 support |
| Image | png, bmp, dib, gif, jpeg, jpe, jpg, msp, pcx, ppm, pbm, pgm, xbm, spi | yes (some dims) | — | **missing** | test_image.py: allclose | useful | PNG/JPEG via Pillow; `FormatoPNG` writes PNG with text chunks only |
| Impulse | csv | no | — | **missing** | test_impulse.py: allclose, explicit rtol/atol/decimal in places | not planned | in-situ holder CSV (Protochips Impulse) |
| JEOL | asw, img, map, pts, eds | no | — | **missing** | test_jeol.py: allclose | useful | ASW/PTS/EDS/IMG JEOL TEM and SEM |
| JobinYvon | xml | no | — | **missing** | test_jobinyvon.py: allclose, explicit rtol/atol/decimal in places, isclose | not planned | Raman XML |
| MRCZ | mrc, mrcz | yes (some dims) | — | **missing** | test_mrcz.py: almost_equal, array_almost_equal, deep_almost_equal (allclose), equal | not planned | blosc-compressed MRC; no consumer |
| netCDF | nc | no | — | **missing** | no test file | not planned | netCDF; no consumer |
| NeXus | nxs | yes | — | **missing** | test_nexus.py: allclose, almost_equal, array_equal, isclose | not planned | NeXus; no consumer |
| numpy | npy | yes | — | **missing** | test_numpy.py: allclose, array_equal | useful | npy; trivial, needed for interchange |
| PantaRhei | prz | yes | — | **missing** | test_pantarhei.py: allclose, almost_equal, deep_almost_equal (allclose) | not planned | PantaRhei; no consumer |
| Phenom | elid | no | — | **missing** | test_phenom.py:  | not planned | Phenom SEM ELID |
| Protochips | csv | no | — | **missing** | test_protochips.py: allclose, equal, explicit rtol/atol/decimal in places | not planned | in-situ holder CSV logs; would be useful with a time-series consumer |
| Quadstar | sac, sbc | no | — | **missing** | test_quadstar.py: allclose, explicit rtol/atol/decimal in places | not planned | mass spectrometry |
| Renishaw | wdf | no | — | **missing** | test_renishaw.py: allclose, explicit rtol/atol/decimal in places, isclose | not planned | Raman WDF |
| Ripple | rpl | yes (some dims) | — | **missing** | test_ripple.py: allclose, array_equal | not planned | Lispix RPL; legacy |
| Semper | unf | yes (some dims) | — | **missing** | test_semper.py: allclose, equal | not planned | Semper UNF; legacy |
| TIA | ser, emi | no | — | **missing** | test_tia.py: allclose, almost_equal, array_equal, equal, explicit rtol/atol/decimal in places | useful | SER/EMI, FEI TIA; older FEI TEM data |
| Tofwerk | h5 | no | — | **missing** | test_tofwerk.py: allclose, approx, array_equal | not planned | ToF mass spectrometry |
| Topspin | app5 | no | — | **missing** | test_topspin.py:  | not planned | NMR |
| TriVista | tvf | no | — | **missing** | test_trivista.py: allclose, explicit rtol/atol/decimal in places, isclose | not planned | Raman TVF |
| TVIPS | tvips | yes | — | **missing** | test_tvips.py: allclose, explicit rtol/atol/decimal in places | useful | TVIPS 4D-STEM frames (read and write) |
| USID | h5, hdf5 | yes | — | **missing** | test_usid.py: allclose | not planned | scanning-probe/PFM HDF5 layout |
| ZSPY | zspy | yes | — | **missing** | test_zspy.py: allclose, array_equal, equal | not planned | Zarr; no Zarr reader in Swift, HSPY covers the use |

## Rows with no RosettaSciIO plugin

| Counterpart | Kit | State |
|---|---|---|
| h5py low-level | `HDF5Reader`, `HDF5AppendWriter`, `HDF5SlabReader` | pinned exact to h5py 3.16.0; compound, other enum, array and vlen data, references, external links not supported |
| py4DSTEM EMD 1.0 4D datacube (py4DSTEM f050d207) | `HDF5Datacube` | pinned for explicit rank-four numeric datasets; nonlinear coordinates refused |
| py4DSTEM BraggVectors | `BraggVectorsEMD`, `HDF5WriteSession.writeBraggVectors` | read and write pinned; origin maps and `_v_cal` not written |
| EMD 1.0 bundle writers | `EMDDatacubeWriter`, `writeEMDCalibration`, maps | write pinned |
| PNG with text chunks | `FormatoPNG` | write pinned; no interlacing, palette |
| TIFF app image (named option) | `TIFFAppImage` | pinned to macTEM cb6e164 on 149 cases |
| `rsciio.load` (extension guess then plugin check) | `FormatoLoader.sniff/load` (product `Formato`, 0.9.0) | extension plus first bytes; 4D formats named, not loaded |

## MSA (0.9.0)

`MSAReader` is `parse_msa_string`/`file_reader`; `MSAWriter` is `file_writer`. Pinned on RosettaSciIO's 11 public MSA files and 66 planted
texts (keywords with unit suffixes, exponents with spaces, bad numbers, repeated TITLE/COMMENT, `TIME` and `DATE` strptime edges, XY
data, CR/LF/CR-only newlines, Latin-1), read bit for bit (data, axis, mapped metadata in DTBox's tree order, keywords in order); the
writer's bytes equal RosettaSciIO's for the public files and planted texts read and written back (`Y`, `XY`, `format=None`, own
separator, with and without the original keywords) and for 19 synthetic signals (TEM and SEM EDS, EELS, CL, long titles, dates, float32
and integer data, NaN, Latin-1 and non-Latin-1 text, UTF-8). Test tolerance in RosettaSciIO: `assert_allclose` defaults; the kit is exact.
Registered deviations: (1) a numeric keyword that does not convert stays a string in RosettaSciIO and breaks HyperSpy later; the read is
refused when it is `XPERCHAN` or `OFFSET`; (2) the writer checks `format` before opening the file (RosettaSciIO truncates first);
(3) RosettaSciIO's writer rewrites its module-level keyword table for an SEM signal, which changes every later read and write in that
process; the kit does not; (4) metadata numbers print as Python floats (a Python int metadata value would print without `.0`); an
axis scale or offset of exactly 1 or 0 on a spectrum read from a file that has no `XPERCHAN` or `OFFSET` prints as the int RosettaSciIO's
reader defaults to; (5) the header comment names `creator` (default "FormatoKit"), not RosettaSciIO's version; (6) `General.time` is
never written (RosettaSciIO tests `"General.item"`, a typo, as RosettaSciIO does; kept).

## Reader options (RosettaSciIO 049e7d70's `file_reader` arguments, for the formats FormatoKit holds)

| Plugin | Argument | FormatoKit |
|---|---|---|
| DigitalMicrograph | `lazy` | always lazy (`FormatoLazySignal`, positioned reads); `load()` is the eager array, registered equal (L1) |
| | `order`, `optimize`, `chunks` | no: C order as stored; dask chunking has no counterpart |
| EMD (Velox) | `lazy` | images lazy per frame (L1); spectrum images eager, as RosettaSciIO's `lazy=False` (its `lazy=True` sparse COO path, whose float counts beyond 2^24 differ, is not ported); the moved spectrum-stream reader decodes eagerly into CSR |
| | `select_type="images"` | `VeloxImageSignals`: stored type and RosettaSciIO's titles (step 3) |
| | `select_type="spectrum_image"`, `first_frame`, `last_frame`, `sum_frames`, `sum_EDS_detectors`, `rebin_energy`, `SI_dtype` | `VeloxSpectrumImageSignals` with `VeloxSpectrumImageOptions` (step 4): all six, RosettaSciIO's defaults, pinned on 10 public, 12 planted and 6 SpectroKit files over ten option sets. The moved `VeloxEMDReader.readSpectrumImage(frames:)` keeps SpectroKit's rules |
| | `select_type="single_spectrum"` | `VeloxSpectrumSignals` (0.9.0): `Data/Spectrum` as RosettaSciIO returns it (Stack and Energy axes, the HyperSpy mapping, date and time under any time zone), pinned on 15 planted files and the public ones; read only from a `Spectrum` or `SpectrumStream` file as RosettaSciIO does |
| | `load_SI_image_stack` | the default only (the first frame of an SI file's images) |
| | `dataset_path`, `stack_group` (NCEM / Berkeley EMD) | no: NCEM EMD is not read |
| TIFF | `lazy` | always lazy (L1) |
| | `force_read_resolution`, `multipage_as_list`, `hamamatsu_streak_axis_type` | no: refused branches, or the default |
| EMPAD | `lazy`, `q_calibration` | always memory-mapped; `EMPADReader(path:qCalibration:)`, XML calibration by default |
| | `remove_nans` | default false only: preserves all stored Float32 bits |
| MSA | `lazy`, `encoding` | `MSAReader.read(path:encoding:)`; lazy is not supported by RosettaSciIO either; `encoding` latin-1 (default) or UTF-8 |
| | writer `format`, `separator`, `encoding` | `MSAWriter.encode/write`, byte-pinned (`Y`, `XY`, own separator, UTF-8) |
| Writers (EMD NCEM, TIFF) | `file_writer` | no writing yet |

## Inside the pinned formats: what is not yet equal

- **TIFF shaped series (equal since 0.11.0).** tifffile's `series_shaped` (the description `{"shape": [...]}` that `imwrite(array)` stores, with
  `axes`, `name`, `truncated` and any user keys, or the old `shape=(...)`), `check_shape`, `reshape_axes`, the contiguous (one IFD, the data
  after it) and appended-series cases, and `pyramidize_series(reduced=True)`: 48 tifffile-written files under `Tests/FormatoTIFFTests/Fixtures/shaped`
  (`tools/shaped-tiff/pins.py`, `shaped-pins.json`), every dtype the layout takes in both byte orders, classic and BigTIFF, 2D to 5D,
  RGB and RGBA, truncated, several series, a pyramid; bytes, shapes, axes, metadata and every refusal equal to RosettaSciIO's. A shaped
  series is not squeezed, so a length-1 dimension stays and an unnamed axis ("Q") is named "None", as RosettaSciIO names it. A description
  tifffile cannot use (not a multiple of the page, bad JSON) falls to the generic rule, as it does; one it raises on (no `shape` list, an axes
  code RosettaSciIO has no name for, data past the end of the file) is refused. Left, refused by name: SubIFD series, OME, a description
  in a second ImageDescription tag (`description1`).
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
  FormatoKit does the same on purpose. A fix belongs upstream first.
- **DM big-endian files** are refused by name (a review generated some); none exists in the public set.
- **Malformed DM files RosettaSciIO raises on** and FormatoKit reads with defaults: a calibration without `Units`, no
  `Calibrations`, no `ImageTags`, a `source` group without `Tags at creation`; and more calibration groups than dimensions
  (RosettaSciIO takes the last n, FormatoKit the first n); empty or array-only `spim` / `spim.eels` / `Monarc Spectrometer`
  groups; tag names holding "."; strings over 4 KiB. The moved DM walk does not expose these; a later
  deliberate change of it can.
- **Velox images: stored type and titles (equal since step 3).** Every public, planted and owner image in its stored type
  and with RosettaSciIO's title (`Operations`, `DetectorInformation`, the label maps). Left:
  an `Operations` kind or `Displays/ImageDisplay` stored as one dataset instead of a group is refused (Python iterates
  its JSON in written order); no file seen has one.
- **Velox compound images** (FFT, DPC) are refused; RosettaSciIO returns them complex.
- **Units outside FormatoUnits** (m and s with SI prefixes, their inverses, dimensionless) refuse the image: Pint also
  reads "px", "Å", "nanometre" and more.
- **Velox spectrum images (equal since step 4).** EDS and EELS spectrum images as RosettaSciIO's `select_type="spectrum_image"`
  returns them, every option, the counts wrapping in the stream's type as its jitted loop does.
  Left, deliberate deviations (refused here where RosettaSciIO reads): a first image whose grid differs from ScanSize x
  ScanArea; a stream that is not one uint16 column; a channel at or beyond the bin count (RosettaSciIO writes outside the
  voxel); frames not summed with no frame left or `last_frame` 0; streams of different bin counts read apart; no FrameTime with
  frames not summed; numpy dtype aliases as `StreamEncoding`; EELS in a type outside the ten or with string calibrations. Not
  ported: `lazy=True`, `load_SI_image_stack`; `select_type=None` is `FormatoLoader.load` (spectra, images, spectrum images in RosettaSciIO's order).
- **Velox detector order (equal since 0.0.3):** `VeloxMetadata.detectors` follows the written order of the `Detectors` keys,
  as RosettaSciIO's `json.loads`, so the energy axis and the detector-metadata match take the same entry (since 0.0.3).
  Left: a key written twice in one object reads its first value here and its last in Python (no file seen has one).
- **Velox metadata mapping:** the image path maps the file name and the beam energy; `VeloxSpectrumSignals` (0.9.0) maps every field
  RosettaSciIO's `_get_mapping` maps for a single spectrum except `Sample.elements`. The images and spectrum images keep the narrower
  mapping (camera length, magnification, instrument and stage are in `AcquisitionMetadata.velox`; for a spectrum image
  `AcquisitionMetadata.velox(spectrumImage:)` from `VeloxEMDReader.spectrumImageMetadata()`, 0.11.0, camera length, magnification and beam
  energy to the bit against RosettaSciIO's returned mapping). **Live and real time of a spectrum image (0.11.0):** RosettaSciIO maps none
  (asserted by `tools/velox-times/pins.py`); `VeloxMetadata.segmentTimes` (seconds per enabled X-ray segment) and `commonLiveTimeSeconds`/`commonRealTimeSeconds` (where every enabled segment states the same),
  read from the Metadata of the first `Data/SpectrumImage` group (`VeloxEMDReader.spectrumImageMetadata()`), where they are the totals of the scan (the stream's columns hold one frame); not in the signals' metadata, which stays RosettaSciIO's. Exact
  against planted files, no RosettaSciIO value to compare; unvalidated beyond the one owner file's order of magnitude.
  **Pixel size (0.11.0):** `AcquisitionMetadata.pixelSize` (rows, columns, unit as stored) from `BinaryResult.PixelSize`, `.rosettaSciIO`
  only; equal to RosettaSciIO's axis scales after the conversion they went through.
- **Lazy reading:** registered equal to eager for DM (positioned reads) and Velox images (per frame). Not yet
  memory-mapped; no chunked HDF5 reads beyond the moved reader's blocks.
- **Writing:** none for RosettaSciIO's formats. FormatoKit writes only the EMD 1.0 bundle writers (`EMDDatacubeWriter`, calibration, maps), `FormatoPNG`, `BraggVectorsEMD` (py4DSTEM EMD 1.0), `HDF5RootAttributes` (a sidecar's root string
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

## Peek (0.10.0)

`Peek` has no RosettaSciIO counterpart. Its dimensions, axes, data types and acquisition fields are the readers' own (compared with them, exact); its pixels are the file's, point sampled at `stride = ceil(longer side / maxPixels)` (pixel (i, j) = source (i * stride, j * stride)), so there is no tolerance: a planted gradient (1000 * row + column) pins the closed form at stride 1 and 4, and every format is compared with the same file read whole by its own reader and cut at the same stride (`Tests/FormatoPeekTests`). A stack or cube is entered at the centre of its leading axes; a spectrum is binned to the largest value per bin. Budget: the 1.66 GB Velox spectrum image peeks in 0.36 s with 22 MB resident.

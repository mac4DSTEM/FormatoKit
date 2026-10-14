# Parity with RosettaSciIO

The checklist that makes "complete" a measured claim (suite ROADMAP, "Kits", phase 4). Started 2026-10-15 from RosettaSciIO
049e7d70's own format list (its 38 `rsciio/*/specifications.yaml`, the source of its supported-formats table). Updated at
every tag. "Pinned" means a gate compares FormatoKit with RosettaSciIO bit for bit on that format's files; "read" means a
reader exists without that gate.

## The formats

Priority: **A** the owner's data needs it (the order of the format lanes), **B** common in materials TEM, **C** other
instruments and techniques, out of scope until someone asks.

| RosettaSciIO plugin | Extensions | RosettaSciIO writes | FormatoKit module | State | Priority |
|---|---|---|---|---|---|
| DigitalMicrograph | dm3, dm4 | no | `FormatoDM` | **pinned** (step 1): every object as a signal; 106 public signals and the owner's 40 bit for bit; the moved `DM4Experiment` API | A |
| EMD, Velox | emd | no | `FormatoEMD` | **pinned** for images as signals (step 1, Float32); the spectrum stream read and parity-checked in SpectroKit's history (moved API) | A |
| EMD, NCEM / Berkeley | emd | yes | `FormatoEMD` | not read | B |
| EMD, prismatic | emd | no | — | not read | C |
| TIFF | tif, tiff | yes | `FormatoTIFF` | empty: **step 2** (FEI / Thermo Fisher and TIA tags, Gatan 65027, ImageJ), from macTEM's walker | A |
| TIA | ser, emi | no | `FormatoTIFF` or its own module | not read | B |
| MRC | mrc, ali | no | `FormatoMRC` | empty | B |
| MRCZ | mrc, mrcz | yes | `FormatoMRC` | not read | C |
| EMPAD | xml (+ raw) | no | `FormatoEMPAD` | empty; with mac4DSTEM's 4D HDF5 readers when its session is ready | A |
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

## Inside the pinned formats: what is not yet equal

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
- **Velox images: stored dtype.** FormatoKit reads Float32 (exact for 8- and 16-bit integers and float32; every public and
  owner image is one of those). RosettaSciIO keeps the stored type.
- **Velox titles:** RosettaSciIO names an image from the `Operations` group (element maps, DPC, FFT, the camera's display
  name); FormatoKit uses `BinaryResult.Detector` (26 of the 42 public images and 7 of the owner's 11 differ).
- **Velox compound images** (FFT, DPC) are refused; RosettaSciIO returns them complex.
- **Units outside FormatoUnits** (m and s with SI prefixes, their inverses, dimensionless) refuse the image: Pint also
  reads "px", "Å", "nanometre" and more (registration A5, F7).
- **Float64 Velox values just above Float32's largest value** become infinity (HDF5's conversion) where NumPy's `astype`
  gives the largest Float32; the stored-dtype read of step 2 removes the difference.
- **Velox spectrum images as signals** (`select_type="spectrum_image"`, frame sums, rebinning, `SI_dtype`, the sparse
  output): the moved reader decodes the stream; the signal adapter and its pins are step 2.
- **Velox metadata mapping:** step 1 maps the file name and the beam energy; RosettaSciIO also maps the camera length,
  magnification, instrument, stage, detector and EDS fields.
- **Lazy reading:** registered equal to eager (gate L1) for DM (positioned reads) and Velox images (per frame). Not yet
  memory-mapped; no chunked HDF5 reads beyond the moved reader's blocks.
- **Writing:** none.

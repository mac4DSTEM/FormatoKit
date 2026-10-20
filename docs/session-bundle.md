# Session sidecar and scientific bundle (design note)

Not a registration. Why the module is shaped as it is, what moved from the apps, what did not, and why. Written 2026-10-20 for
0.6.0. State and pins are in `docs/status.md` and `docs/parity.md`; the API is in the doc comments.

## What an app's output file is

mac4DSTEM and macTEM each keep a **sidecar**: an HDF5 file beside the opened dataset that holds the session's products. For
mac4DSTEM it is an EMD 1.0 file (py4DSTEM's layout) with a BraggVectors object, a calibration group, result maps and a few
`mac4dstem_*` root attributes (schema, minimum reader, replay record, lineage, load specification). macTEM keeps root attributes
only (`HDF5RootAttributes`, 0.3.0). mac4DSTEM also exports a **calibrated 4D datacube** (a py4DSTEM `DataCube`) and a **scientific
bundle** (several result maps and a calibration in one EMD file).

Two kinds of code sit in the apps' writers:

- **Format code**: how an EMD file is laid out: group types and python classes, `dim` axes, the calibration group, the
  `RealSlice` / `Array` nodes, the chunking of the datacube, variable-length text, the atomic publish. This is what py4DSTEM reads
  and what any second consumer would have to repeat. It moved to the kit.
- **Meaning**: what an app stamps into the file and when (`mac4dstem_*` keys, a map's kind and provenance, the lineage graph, the
  replay record, minimum-reader rules, "preserve what the old sidecar held"). It stays in the app and arrives in the kit's writers
  as **caller-supplied attributes** (`[String: HDF5AttributeValue]`) and **metadata entries** (`[String: String]`), stored
  verbatim. The kit names no app and invents no key.

## What the kit already had (0.5.0)

`BraggVectorsEMD` (the peak grid and the scalar calibration, whole-file, atomic, `extraAttributes` hook), `HDF5Reader`,
`HDF5AppendWriter` / `HDF5WriteSession` (groups, numeric datasets, fixed-length attributes, delete), `HDF5RootAttributes`
(fixed-length root strings, temporary URL, publish), `FormatoFileWrite`. Missing for the apps' remaining writers: variable-length
text (what h5py and emdfile store), bool, a dataset created empty and filled by slabs, a way to build a fresh file and replace
the destination, and the EMD nodes themselves.

## The pieces (all in FormatoHDF5 unless noted)

| Piece | What it is | App code it replaces |
|---|---|---|
| `HDF5WriteSession` additions | `setVariableLengthTextAttribute`, `writeText`, `writeBool`, `createDataset`, `writeSlab` | the app's private `HDF5WriteLibrary` calls (about 450 lines) |
| `HDF5NewFile`, `HDF5PendingFile` | build a new file under a scratch name, publish over the item that was checked, refuse a destination that is the source; the pending form lives across `await`s with no handle or lock held between calls | `temporaryPublishURL` + `rename` in `publish`, `writeScientificBundle`, `writeCalibratedDataCube` |
| `EMDFileHeader`, `createEMDRoot` | the EMD 1.0 file identity and root group | `writeFile` / `writeScientificBundle` / datacube headers |
| `EMDCalibration`, `writeEMDCalibration` | the `Calibration` metadata group incl. origin maps, shifts, rotation convention, `_target_paths`; `EMDBooleanStorage` | `writeCalibration` |
| `EMDScalarMap`, `EMDRGBAMap`, `writeEMDScalarMap`, `writeEMDRGBAMap` | `RealSlice` and `Array` nodes with axes and a caller-named metadata group | `writeResultMap`, `writeRGBAResultMap` |
| `EMDDatacubeWriter` | the float32 4D `DataCube` written a band of scan rows at a time, chunked one pattern per chunk | `writeCalibratedDataCubeFile` (the tile loop and the export's cropping, binning and hot-pixel logic stay in the app) |
| `FormatoPNG` (FormatoCore) | PNG with `tEXt` / `iTXt` chunks, CRC-32 and Adler-32, insertion into a PNG made elsewhere, reading the text back | macTEM `ImageExport.PNGChunks` |

The apps compose them. A new sidecar: `BraggVectorsEMD.write` (peaks, with `extraAttributes` for the app's root keys), then
`HDF5AppendWriter.append` with `writeEMDCalibration(..., replace: true)` and the maps. Replacing one map is one `replace: true`
call: the old "rebuild the whole file and `H5Ocopy` everything else across" is no longer needed, because the append writer keeps
what it does not touch.

## Choices where the reference and the first consumer differ

Reference first (py4DSTEM / h5py); the app's variant is a named option, pinned to the app's own bytes:

- `QR_flip` is h5py's `bool` enum by default; `EMDBooleanStorage.uint8` writes the app's plain `uint8`. py4DSTEM reads both.
- Strings are UTF-8 variable-length everywhere (the app); py4DSTEM's own units are ASCII. UTF-8 is a superset.
- Integer attributes (`version_major`, `length`) are int64 (as `BraggVectorsEMD`), the app writes int32. Values are equal.
- `UUID` and `authoring_user` are optional in `EMDFileHeader` (the app's scientific bundle has neither).

## What did not move, and why

- **Session lineage and replay records** (mac4DSTEM `SessionLineage`, `SessionReplayRecord`; macTEM `SessionLineage`,
  `SessionMarks`). They are **not one format shared by two apps**. mac4DSTEM's is schema 2: nodes are runs with a `head`,
  frames, products, rewind and a pinned active set; the replay record is its linear projection. macTEM's is its own version 1:
  nodes are marks, a removed node is deleted (a cited one kept with a date), times are integer milliseconds, numbers are strings.
  The two share a skeleton (`id`, `kind`, `parameters`, `inputs`, `external`, the 4 MiB / 2 000-node / cycle guards) and nothing
  more; unifying them would be a change of both apps' formats, not a move of code. Their attribute names (`mac4dstem_lineage`,
  `mactem_lineage`) are the app's. Proposal for later, if a third consumer appears or the owner wants the two merged: a
  `SessionLineageGraph` in FormatoCore with the skeleton and the guards, with each app's node vocabulary kept on top.
- **SHA-256 identity** of macTEM's `SessionSourceIdentity` (the opened Float32 pixels, NFC file name, size): it identifies an
  *image a mark list belongs to*; mac4DSTEM identifies its source differently (load specification). App meaning.
- **`ResultExport` / `PreprocessExport`**: `AppState` extensions (panels, tiles, provenance records, access grants). Their format
  code is the writer calls above; `scanMapPersistenceMetadata` builds the app's provenance dictionary, which the kit takes as
  attributes.
- **The datacube export's reduction** (crop, thin, bin, hot-pixel replacement) and its calibration re-reference
  (`transformedCalibration`): numerics of the app's pipeline, with their own py4DSTEM deviation notes. Not file format.
- **Preserving unknown objects across a rewrite** and the minimum-reader refusal: app policy over the sidecar; with the append
  writer the first is automatic and the second is a read the app makes before it appends.

## Pins

The app's output is the oracle, produced offline from the app's `Core/` at `c47a2b7a` and the kits at the app's pins
(`tools/emd-bundle/oracle/run.sh`, `tools/png/oracle.sh`); nothing in an app repo is built or touched. Every object, attribute
value and dataset byte of the kit's files equals the app's (the UUID excepted; the Swift test reads them through `HDF5Reader`);
h5py compares the string encodings, dtypes, shapes and chunk layouts (`tools/emd-bundle/check.py`; HDF5 files are not byte-deterministic, so the committed `swift-*.h5` are pinned by SHA-256 to the run
h5py and py4DSTEM read, not regenerated and compared), and
py4DSTEM 0.14.19 reads the kit's files as the same objects with the same calibration, pixels and peaks
(`tools/emd-bundle/check.py`). PNG: `inserting` is byte-identical to macTEM's insertion; Pillow decodes every encoder output and
zlib its IDAT (`tools/png/check.py`).

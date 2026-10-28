# tools/step-2: the oracle pins and the planted files of FormatoTIFF

These scripts pin what RosettaSciIO and tifffile read. Python only; the Swift tests (`FormatoTIFFPinsTests`,
`PlantedTIFFTests`) read what they write. Agreement with RosettaSciIO and tifffile is agreement with an independent reading of the same
bytes, not truth; truth is a planted file.

## Run

    References/rsciio-venv/bin/python -I -B tools/step-2/make_planted.py [--out DIR]
    References/rsciio-venv/bin/python -I -B tools/step-2/pins.py [--work DIR]
    References/rsciio-venv/bin/python -I -B tools/step-2/pins.py --owner FILE [FILE ...] --out PATH [--work DIR]
    tools/step-2/owner-check.sh

Order: `make_planted.py` first (`pins.py` reads `Fixtures/planted/planted-truth.json` and stops if a planted file's sha256 differs
from it), then `pins.py`.

- `make_planted.py` writes `Tests/FormatoTIFFTests/Fixtures/planted/*.tif` and `planted-truth.json`.
- `pins.py` (default) writes `Tests/FormatoTIFFTests/Fixtures/step-2-pins.json`: every TIFF of `rsciio/tests/data/tiff/` (loose
  files, `.gz`, zip members; set `public`) and the planted files (set `planted`).
- `pins.py --owner` writes the same per-file records for the named files (set `owner`, path = basename) to PATH. PATH is scratch:
  never commit it (it holds the files' metadata, the Ceta XML included).
- `owner-check.sh` finds `$MACEM_DATA/tem/*Ceta.tif` (default `../data`), writes `.build/owner-tiff/owner-pins.json` and
  `files-abs.txt`, then runs `swift test -c release --filter FormatoTIFFPinsTests` with `FORMATO_OWNER_TIFF_PINS` and
  `FORMATO_OWNER_TIFF_FILES` set. The Swift test does not exist until the Swift lane of step 2 lands.

Both scripts stop unless `rsciio.__file__` and `tifffile.__file__` are inside `References/rsciio-venv`, the clone's HEAD is the
pin `049e7d70`, tifffile is 2026.9.20, NumPy 2.5.4, python-dateutil imports, and the installed `rsciio/tiff/_api.py`,
`utils/rgb.py`, `utils/_date_time.py` equal the clone's byte for byte. Each public loose file, `.gz` and zip is checked against
`rsciio/tests/registry.txt` (a zip member through its zip); they are unpacked (names checked, 1 GiB bound) into a fresh directory
under `--work` (default: system temp), never into the clone. Everything is built twice in the process and the script stops if
the two outputs differ; the outputs are also identical across separate runs. Output: sorted keys, indent 1, UTF-8, no times, no
absolute paths, non-finite numbers as null (the `*_bits` fields carry them). `tifffile`'s and RosettaSciIO's log notes are
silenced (the planted refusal files provoke them on purpose).

## `step-2-pins.json`

Top level: `generator`, `reference`, `versions`, `files`, `skipped_non_tiff` (`tiff/test_dm_image_um_unit.dm3` is a DM3 that
lives in the `tiff/` folder). Files: loose files by path, then `.gz`, then zip members, then the planted files in the order of
`planted-truth.json`.

| field | meaning |
|---|---|
| `set` | `public`, `planted` or `owner` |
| `path` | public: relative to `rsciio/tests/data` (a zip member `tiff/<zip>/<member>`, a gz `tiff/<name>.gz`); planted: `planted/<name>`; owner: basename |
| `container` | null, or `{kind: zip/gzip, name, sha256}` of the container; `sha256` and `bytes` of the record are of the TIFF itself |
| `bigtiff`, `byteorder` (`<`/`>`), `pages` (`len(tiff.pages)`) | tifffile's |
| `flags`, `page0_flags` | sorted `TiffFile.flags` and `pages.first.flags` |
| `in_scope`, `out_of_scope`, `out_of_scope_reasons` | the scope rule below; `out_of_scope` is the first reason, null when in scope |
| `raises` | null, or `{type, message}` of what `rsciio.tiff.file_reader(path)` raised (then `series` is empty) |
| `tifffile_raises` | null, or what `tifffile.TiffFile(path)` raised (then `tags` is empty and the reason is `tifffile-cannot-open`) |
| `tifffile_series` | tifffile's `series`: `axes`, `kind`, `shape`, `dtype`, `pages` (the number of pages of the series) |
| `tags` | every tag of page 0, see below |
| `fei_metadata` | with flag `fei`: `tiff.fei_metadata` as an ordered list `{section, key, kind (int/float/bool/str), value[, value_bits]}`; the INI parse the Swift port must equal |
| `imagej_metadata` | with flag `imagej`: `tiff.imagej_metadata`'s scalar items as `{key, kind, value[, value_bits]}` |
| `series` | one record per dict RosettaSciIO returned, see below |

**Scope rule** (the reasons in this order): `flag:sem`, `flag:tvips`, `flag:sis`,
`flag:streak` (any file flag, or any flag of any page of any series), `make:JEOL Ltd.` (page-0 Make, RosettaSciIO's own test;
tifffile 2026.9.20 has no SightX detection, its `JEOL_Header` is DM tag 65027), `compressed` (any page of any series with
Compression != 1), `tiled`, `planar-config-2`, `series-kind:<kind>` (a series whose kind is not `imagej`, `generic`, `uniform`,
or `shaped` with one page). A file the rule keeps in scope can still be refused by the container reader (a strip past the end of
the file: `strip-past-end.tif`, where RosettaSciIO raises).

**Tag** (page 0, tifffile order): `code`, `name` (tifffile's; unnamed codes are the number as a string), `type` (TIFF datatype
int), `count`, `raw_sha256` (sha256 of the `count * size(type)` value bytes as stored, from `tag.valueoffset`: inline or
external), `value_kind` (`int`, `float`, `str`, `list`, `none`, `unreadable`), `value`, `value_bits`:

- `int`: IntEnum members as plain ints; `float`: `value` (null if not finite) and `value_bits` (16 hex digits, IEEE-754 double,
  big-endian `struct.pack('>d')`); `str`: tifffile's decoded string; `list`: tifffile's tuple (a RATIONAL is `[num, den]`; a
  tag with several values a flat list), `value_bits` the same shape with a hex string for each float and null for the rest.
- `none`: tifffile's value is bytes, a dict, an array...; only `raw_sha256` counts, `value_type` names what tifffile gave
  (the FEI tag 34682 is a `dict`, 34683 in the Ceta files is a `str`, Gatan's 65027 is `bytes`).
- The single-value rule: a tag with count 1 gives a scalar, any other count a tuple, except the tags tifffile always keeps as
  tuples (273, 279, 282, 283, 324, 325, 330, 338...); RATIONAL is always a pair.

**Series** (the i-th dict of `file_reader` is `tiff.series[i]`): `tifffile_axes`, `tifffile_kind`, `dtype` (numpy name; for the
structured RGB dtype `str()` of the little-endian dtype, `[('R', 'u1'), ('G', 'u1'), ('B', 'u1')]`), `dtype_as_returned`
(`str(data.dtype)`, shows a big-endian file's byte order), `shape` (the returned array's: an RGB series has no sample axis),
`data_sha256` (of `np.ascontiguousarray(data)` converted to little-endian, C order, structured fields included), `axes`
(`name, size, scale, scale_bits, offset, offset_bits, units (str or null), navigate`), `metadata`.

**Metadata** is a list of `{key, kind (number/string/bool/other), value[, value_bits], source}` in this order: the keys of the
returned `metadata` that are set, in the order `General.original_filename`, `General.date`, `General.time`,
`Signal.signal_type`, `Signal.quantity`, `Signal.Noise_properties.Variance_linear_model.gain_factor` and `.gain_offset`
(`source`: the tag that gave them: `DateTime`, `65022`, `65025`, `65024`; null for the filename and the signal type), then
every target of the returned `mapping` applied to `original_metadata` as HyperSpy does (the value at the dotted source path,
then the function; a function returning None means no entry; `source` is the mapping's key, e.g. `fei_metadata.Beam.HV`). A FEI
file lists `General.date` and `General.time` twice (from DateTime, then from `User.Date`/`User.Time`): the later is HyperSpy's.

## `planted-truth.json`

Top level `generator`, `reference`, `versions`, `files`. Per file: `file`, `sha256`, `bytes`, `bigtiff`, `byteorder`, `kind`
(`read` or `refusal`), `in_scope`, `pages`, `note`, `tags` (per page, hand-derived from the bytes written: `code`, `type`, `count`,
`raw_hex`, `value` as a person reads it, `value_bits` for floats, `name`), `strip_offsets`, `strip_counts`; for `read`:
`series` (the expected `tifffile_axes`, `shape`, `dtype` (`rgb8`/`rgba16` are FormatoCore's names), `pixels` (nested lists, an
RGB pixel a list of samples; `pixel_bits_f32` for the float file), `data_sha256`, `axes`, `metadata`) and
`tifffile_ignores_tags`; for `refusal`: `refusal` `{reason, tag, value, message_names}`; and always `reading` (the `pins.py` record
of the same bytes: tifffile's and RosettaSciIO's readings, their exceptions included) and `disagreements` (hand-written truth
versus that reading; empty for all 20 files, the script prints any and the run is not silent about them).

| file | what it plants |
|---|---|
| `be-u16-3strips.tif`, `le-u16-3strips.tif` | 3 x 5 uint16, `1000*r + c`, RowsPerStrip 1 (3 strips), MM and II. BE: RATIONAL 300/7, Software with a NUL in the middle, DateTime `%Y:%m:%d %H:%M:%S`. LE: DateTime `%Y/%m/%d %H:%M` |
| `bigtiff-f32.tif` | little-endian BigTIFF 2 x 3 float32 with -0.0, 1e-38 (float32 subnormal), 3.5, float32(0.1), -2.5, float32 max; private LONG8 and SLONG8 tags |
| `rgb8.tif`, `rgba16.tif` | 2 x 2 RGB uint8 (MM), RGBA uint16 (II, ExtraSamples 2) |
| `stack-i16.tif` | two pages 2 x 3 int16, negative values: generic series `IYX` |
| `imagej-micron.tif` | the spec's ImageJ description, two IFDs with contiguous planes, XRes = YRes = 4/1: `ZYX`, 0.25 um, z 0.5 |
| `imagej-virtual.tif` (extra) | one IFD, `images=2`, the second plane follows the first strip: tifffile's "virtual" ImageJ rule, `len(pages)` 1 but 2 planes |
| `imagej-micron-asym.tif` (extra) | XRes 4/1, YRes 2/1: tells the height/width cross-over apart |
| `dm-tags.tif` | the spec's 6 DM tags (units equal, scales equal, offsets -1.5 and 0.0) |
| `dm-tags-stack.tif` (extra) | two pages; all of 65003-65011 with distinct values, a latin-1 micro sign in 65004, 65022/65024/65025 (quantity, gain offset, gain factor) |
| `fei-helios.tif` | the spec's INI (PixelWidth = PixelHeight) |
| `fei-helios-asym.tif` (extra) | every key of `mapping_fei`, PixelWidth != PixelHeight |
| `fei-irbeam.tif` (extra) | no `[Scan]`: the `IRBeam.HFW / Image.ResolutionX` fallback, x != y |
| `tag-zoo.tif` (extra) | one private tag per classic datatype (65100-65112) for the tag walker |
| `datetime-slash-description.tif` (extra) | slash DateTime plus an ImageDescription: RosettaSciIO sets no date or time (see below) |
| `unknown-tag-type.tif` (extra) | tag 65200 of datatype 99: tifffile drops it from the page |
| `lzw.tif`, `tiled.tif`, `strip-past-end.tif` | the refusals: Compression 5; TileWidth/TileLength and tile offsets; a StripOffsets at 100000 in a 150-byte file |

## What RosettaSciIO and tifffile do that is easy to miss (found while writing these)

- tifffile's tag value for ASCII is `rstrip(b'\0')`, decode UTF-8 else cp1252, then `.strip()`: it does not cut at the first NUL
  (`be-u16-3strips.tif` tag 305 reads `"planted\0junk"`). `bytes2str` (cut at the first NUL, same decoding) is what the FEI INI
  and the Zeiss reader use, on the whole tag.
- `read_fei_metadata`'s `astype` order is int, float, **bool** (`true`/`false`, case-insensitive, stripped), str, not int, float,
  str. Python's `int()` and `float()` accept `_`, signs, `inf`, `nan`; `str.splitlines()` splits on more than `\n`; a line that
  starts with `[` is a section whatever follows (`line[1:-1]`); a line without `=` is skipped.
- `General.date`/`General.time` from the slash `DateTime` form are only set when the file has no ImageDescription
  (`datetime-slash-description.tif`).
- A tag of unknown datatype is dropped by tifffile (logged), not kept as bytes.
- ImageJ series with `images` > 1 and one IFD, or with data contiguous from page 0, are read as a block from the first page's
  data offset (`isvirtual`); `imagej-micron.tif` and `imagej-virtual.tif` plant both layouts.

# Registration of step 2: FormatoTIFF (tier 1)

Written 2026-10-15, 01:15 CEST, before any Swift line of step 2, by FormatoKit's session (continued on the owner's
instruction of 00:55, relayed by the suite coordinator). The model is `docs/registration-step-1.md`; its definitions
(FormatoCore's array, axis, metadata with provenance, lazy = eager) hold here unchanged unless this file says otherwise.
A change after code starts is a dated amendment at the end (§11).

## 1. What step 2 makes

1. **A TIFF container reader** in `FormatoTIFF` (`TIFFFile`): the header (classic TIFF and BigTIFF, little- and
   big-endian), every IFD in the main chain, every tag of each IFD with its code, type, count and value (numbers as
   Double or integers, ASCII as a string, undefined/byte as bytes), and the pixel data of a page: uncompressed
   (Compression 1), strips, planar configuration 1 (contiguous), samples per pixel 1, 3 or 4, 8/16/32/64-bit unsigned,
   signed or IEEE float (SampleFormat 1, 2, 3). The tag walker is public: a consumer reads a private tag (Thermo Fisher's
   Velox XML 34683, TIA's tags, Gatan's 65027) from it as it is stored. Anything else (compression, tiles, planar 2,
   other bit depths, a palette applied, YCbCr) is refused by name with the tag that says so.
2. **TIFF files as signals**, ported from RosettaSciIO 049e7d70's `rsciio/tiff/_api.py` `file_reader` with its defaults
   (`force_read_resolution=False`, `multipage_as_list=False`), over tifffile 2026.9.20's views it relies on (`series`,
   `flags`, `fei_metadata`, `imagej_metadata`, the page tags):
   - **Series** (tifffile's `TiffFile.series`, the subset in scope): an ImageJ file (page 0's ImageDescription parses as
     an ImageJ description) gives one series of `images` pages shaped by its `frames`, `slices`, `channels` (axes in
     tifffile's order T, Z, C, then Y, X, S); otherwise the pages are grouped by tifffile's generic rule (same shape,
     type and samples) in first-seen order, a group of one page is `YX` (or `YXS`), of more is `IYX` (or `IYXS`). The
     pins say which files fall in this subset; a file outside it is refused.
   - **Data** as stored (C order, little-endian, the series' pages concatenated). RGB and RGBA (photometric 2, samples 3
     or 4) are RosettaSciIO's structured RGB: FormatoCore gains the element types `rgb8`, `rgba8`, `rgb16`, `rgba16`
     (one element = one pixel, the samples interleaved as stored), so shape and bytes equal RosettaSciIO's structured
     array (§3.1).
   - **Axes**: RosettaSciIO's `_parse_scale_unit` for the branches in scope: **FEI** (tifffile flag `fei`: an FEI_SFEG
     34680 or FEI_HELIOS 34682 tag, parsed as tifffile's `read_fei_metadata` INI with its `astype`), its pixel size
     from `Scan.PixelWidth/PixelHeight` or else `IRBeam.HFW / Image.ResolutionX` (units "m"), else uncalibrated; the
     **default** branch with **Gatan DM** tags (65003-65011: units, scales, offsets) and **ImageJ** (`unit=micron` gives
     "µm" with the scale from X/YResolution, `spacing` the z scale); `_order_axes_by_name` exactly, with RosettaSciIO's
     cross-over (the "height" axis takes the "x" entries, "width" the "y" entries); names from tifffile's axis codes by
     RosettaSciIO's `axes_label_codes` ("height", "width", "image series", "depth", "time", ...); navigate: all but the
     last two; units `None` where RosettaSciIO leaves them so (FormatoAxis gains nothing: `None` is stored as "" and the
     pins say which axes were None, §3.1).
   - **Out of step 2, refused by name** (their own branches, a later lane each): Zeiss SEM (`sem`), TVIPS, Olympus SIS,
     JEOL SightX, Hamamatsu streak, `force_read_resolution`, `multipage_as_list`, and compressed or tiled files.
   - **Metadata**, each entry with its tag (and INI section) as provenance: `General.original_filename`,
     `Signal.signal_type` (""), `General.date` and `General.time` from DateTime (`%Y:%m:%d %H:%M:%S`, else
     `%Y/%m/%d %H:%M`), the DM intensity calibration (`Signal.quantity` from 65022,
     `Signal.Noise_properties.Variance_linear_model.gain_factor/gain_offset` from 65025/65024), and RosettaSciIO's
     FEI mapping (`mapping_fei`): beam energy (`Beam.HV * 1e-3`), stage x/y/z/rotation/tilt, working distance (`* 1e3`),
     dwell time, beam current (`* 1e9`), microscope, date and time (`dateutil.parser`'s parse of `User.Date` and
     `User.Time`: ported for the formats the pins hold, refused otherwise), authors.
3. **Lazy = eager** (step 1's L1): `TIFFFile`'s lazy array reads a slab's rows by positioned reads within the strips; it
   equals the eager array bit for bit on every pinned signal.
4. **What step 2 does not claim.** Velox XML 34683 and TIA's tags are read as stored by the tag walker, not interpreted:
   RosettaSciIO does not interpret them, so they have no oracle here; macTEM's walker keeps interpreting them until a
   registration with its own reference moves that. TIA's `.ser`/`.emi` files are RosettaSciIO's `tia` plugin, another
   format and lane. Writing TIFF is not in step 2.

## 2. The oracle and the pins

- RosettaSciIO 049e7d70 as in step 1 (`References/rosettasciio-049e7d70`, `References/rsciio-venv`), plus
  **tifffile 2026.9.20** installed into that venv (the version macTEM's metadata parity pins; recorded in
  `References/rsciio-venv-freeze.txt`). `pins.py` for step 2 stops unless both versions are the pinned ones.
- **Pins before code**: `tools/step-2/pins.py` writes `Tests/FormatoTIFFTests/Fixtures/step-2-pins.json`. Per file: its
  sha256, tifffile's flags, its page count, every tag of page 0 (code, name, type, count, the value as tifffile returns
  it, numbers with their bit patterns), and for each series RosettaSciIO returns: dtype (the structured RGB dtype named),
  shape, the sha256 of the data's bytes (C order, little-endian), every axis (name, size, scale and offset bits, units
  or null, navigate), and the metadata of §1.2 with its source.
- **Files**: every TIFF of RosettaSciIO's public `tiff/` test data (the loose files, the `.gz` and the zips, each checked
  against `registry.txt` and unpacked into scratch), and the owner's six Ceta TIFFs under `$MACEM_DATA/tem` (owner mode,
  never committed, numbers cited with their log; their manifest lines get FormatoKit's use).
- **Committed subset**: the small public files (under 100 kB) are copied into `Tests/FormatoTIFFTests/Fixtures/` so the
  gate runs on them without References; the rest run when References are present.

## 3. Definitions

### 3.1 FormatoCore additions

- `FormatoDataType` gains `rgb8`, `rgba8`, `rgb16`, `rgba16` (byte sizes 3, 4, 6, 8): one element is one pixel, its
  samples interleaved as stored (little-endian per sample). `doubles()` returns the samples interleaved (count ×
  components values). A source-breaking addition for a consumer that switches exhaustively over the enum; 0.0.x, noted
  in `docs/consumers-0.0.2.md`.
- An axis whose units RosettaSciIO leaves `None` is stored with `units` "" and the pins compare `None` with "".

### 3.2 The container

- A TIFF is refused when the header is not `II*\0`, `MM\0*`, or BigTIFF `II+\0`/`MM\0+` with offset size 8, when an IFD
  or a tag's data lies outside the file, when the IFD chain loops, or when a tag type is unknown (its value is kept as
  bytes and the tag marked so, never guessed). Tag values follow the TIFF 6.0 and BigTIFF types: BYTE, ASCII (cut at the
  first NUL, as tifffile's `bytes2str`), SHORT, LONG, RATIONAL (two LONGs, kept as the pair), SBYTE, UNDEFINED, SSHORT,
  SLONG, SRATIONAL, FLOAT, DOUBLE, LONG8, SLONG8, IFD8.
- Pixel data: StripOffsets, StripByteCounts, RowsPerStrip (default: the image height); each strip holds
  `rows × width × samples × bytes` bytes, the last strip fewer; a strip shorter than that is refused (truncated).
  Big-endian samples are swapped to little-endian.

### 3.3 FEI INI and ImageJ description, as tifffile parses them

- `read_fei_metadata`: the tag's bytes decoded, split into lines, each stripped; `[Section]` starts a section; `key=value`
  splits at the first `=`, both stripped; the value through tifffile's `astype` (int, then float, then the string;
  ported with its exact order and the cases the pins hold).
- `imagej_description_metadata`: lines `key=value`, value tried as int, float, bool ("true"/"false"), else string;
  valid only with an `ImageJ` (or `SCIFIO`) key.

## 4. Planted truth

`tools/step-2/make_planted.py` writes small TIFFs with known content, independent of RosettaSciIO and tifffile's readers
(written with Python's `struct`, byte by byte): an uncompressed 3 × 5 uint16 image in II and in MM byte order with
three strips; a BigTIFF float32 image; an RGB8 and an RGBA16 image; a two-page int16 stack; an ImageJ file with
`unit=micron`, X/YResolution 4/1 (scale 0.25 µm) and `spacing=0.5`; a DM-tagged file (65003 "nm", 65009 2.5, 65006
-1.5); an FEI_HELIOS file with `[Scan] PixelWidth=1.5e-09`; and refusals (LZW compression, tiles, a strip past the end).
The Swift tests state the planted values as literals.

## 5. Gates

- **P2 (pins)**: every in-scope series of every pinned file equal to RosettaSciIO's (data sha256, dtype, shape, every
  axis field bit for bit, the metadata with its source tail); every page-0 tag equal to tifffile's (code, type, count,
  value); a file outside the scope refused by name, and the refusal reason named in the test.
- **L2**: lazy slabs equal the eager array on every pinned signal.
- **Planted**: §4's literals.
- **The owner's six Ceta TIFFs**: `tools/step-2/owner-check.sh`, never a gate.
- The gate is `tools/test.sh`; Swift Testing only.
- Every new test broken once (§6); one Gate B refuter on the frozen commit.

## 6. Planned mutants

1. Big-endian samples not swapped. 2. RowsPerStrip default height → 1. 3. The last strip's short length ignored.
4. ASCII value not cut at the first NUL. 5. RATIONAL as numerator only. 6. The height/width cross-over of
`_order_axes_by_name` undone. 7. ImageJ `unit=micron` → "um". 8. FEI `IRBeam` fallback divided by ResolutionY for x.
9. DM 65009 assigned to x instead of y. 10. FEI `astype` float before int. 11. ImageJ series axes order Z before T.
12. RGB element stored as planar. 13. A tiled file read as strips. 14. beam energy `* 1e3`. 15. lazy slab row offset
off by one.

## 7. Validation

None. Agreement with RosettaSciIO and tifffile, and planted files.

## 8. Licence

GPL-3.0. RosettaSciIO's rules (GPL-3.0-or-later) and tifffile's parsing rules (BSD-3-Clause, Christoph Gohlke) are ported
and credited in `NOTICE`; macTEM's walker (GPL-3.0) is the seed and is credited where its code or tests are used.

## 9. Data read

The owner's six Ceta TIFFs (`tem/Camera Ceta * Ceta.tif`): their existing manifest lines gain FormatoKit's use.

## 10. Not in step 2

Compression (LZW, Deflate, JPEG, PackBits), tiles, planar 2, palettes applied, the Zeiss / TVIPS / Olympus / JEOL /
Hamamatsu branches, force-read resolution, pages as a list, the Velox XML and TIA tags' meaning, writing.

## 11. Amendments

(none yet)

**A1 (2026-10-15, 01:55, the pins and the first runs).** What tifffile and RosettaSciIO do at the pins, found by
`tools/step-2/pins.py` (45 files: 25 public, 20 planted) and the first test runs; none moves a registered number:
1. *ASCII values.* §3.2's "cut at the first NUL" is `bytes2str`, which only the INI parsers use. A tag's ASCII value loses
   its trailing NULs only, decodes as UTF-8 or else cp1252, and is stripped; an embedded NUL stays. The walker does so.
2. *`astype`* tries int, float, bool ("true"/"false" in any case), then the string: §3.3 omitted the bool.
3. *The slash DateTime form* is tried only when the page has no ImageDescription (RosettaSciIO tries the JEOL description
   first and gives up); a planted file pins it.
4. *Unknown tag types.* tifffile drops a tag of a type it does not know; the walker keeps it as bytes (more, never less),
   and the comparison of tag codes leaves those out.
5. *Pointer tags.* For EXIF 34665, GPS 34853, Interoperability 40965 and TVIPS 37706, tifffile's `valueoffset` is the
   structure it reads, not the stored field; the walker keeps the stored field, and the raw comparison leaves them out.
6. *Lines.* Python's `splitlines` splits "\r\n" as one break; Swift's `\r\n` is one Character, so the INI and ImageJ parsers
   split on `Character.isNewline` (the public FEI Helios files use "\r\n"; the planted ones "\n").
7. *ImageJ virtual stacks.* With fewer pages than images, the images are read contiguously after page 0's data, as
   tifffile's `series_imagej` does; a planted file pins it.
8. *The owner's six Ceta TIFFs* are 8-bit RGB renders, one page each, with the Velox XML in tag 34683 and the resolution
   tags 65450-65452: RosettaSciIO gives them uncalibrated height and width axes and no date.
Result: 45 files; 31 series bit-identical (data, shape, element type, every axis field, metadata with source) and their
page-0 tags equal to tifffile's; 14 refused by name (11 out of scope, 3 RosettaSciIO raises on); lazy slabs equal on all.

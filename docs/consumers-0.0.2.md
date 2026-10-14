# FormatoKit 0.0.2: what the consumers change

Written 2026-10-15 by FormatoKit's session, for whoever bumps from 0.0.1 (nobody imports FormatoKit yet; SpectroKit 0.4.0
is the first). Everything in `docs/consumers-0.0.1.md` still holds.

- **New: FormatoTIFF** (registration step 2). `TIFFFile(path:)` reads any classic or BigTIFF file's directories and tags
  (`TIFFDirectory`, `TIFFTag`, `TIFFTagValue`), so a consumer reads a private tag as stored: Thermo Fisher's Velox XML in
  34683, the resolution tags 65450-65452, Gatan's 65027, TIA's. `TIFFSignals(path:)` gives a file's series as FormatoCore
  signals the way RosettaSciIO does (FEI, Gatan DM tags, ImageJ, plain; uncompressed strips), and refuses the other
  vendors (Zeiss SEM, TVIPS, Olympus SIS, JEOL SightX, Hamamatsu streak) and compressed or tiled pages by name.
  macTEM's TIFF walker can move onto it in its own lane: the container and the RosettaSciIO-defined calibrations are
  here; the Velox XML's meaning (macTEM's calibration from 34683) is still macTEM's, read from `TIFFFile`'s tags.
- **Source-breaking for an exhaustive switch:** `FormatoDataType` gains `rgb8`, `rgba8`, `rgb16`, `rgba16` (RosettaSciIO's
  structured RGB, one element per pixel), and `components`; `FormatoArray.doubles()` returns every sample of a colour
  array (count × components values). A `switch` over `FormatoDataType` without `default` needs the four cases.
- **Behaviour:** none of the step-1 readers changed. The Velox adapter's Python `float()` rule moved into FormatoCore
  (package API), unchanged.

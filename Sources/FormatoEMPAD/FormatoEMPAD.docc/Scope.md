# Scope

The EMPAD reader follows RosettaSciIO 049e7d70's `empad.file_reader`: little-endian Float32 frames,
130 rows by 128 columns, with the two footer rows omitted. The scan uses XML `pix_x/pix_y`, falling back
to `scan_xN_yN.raw`; `scan_parameters.series_count` describes an image series. Singleton axes are squeezed.

Both legacy `optics.get_full_scan_field_of_view` (a numeric pair) and modern `full_scan_field_of_view.x`
with `scale_factor` calibrate navigation. Diffraction uses `calibrated_pixelsize * 1e9` in 1/nm or an explicit
`qCalibration` override. Uncalibrated diffraction uses scale 1, offset -64 and empty units (RosettaSciIO's `None`).
Title, original filename, signal type and timestamp date/time carry provenance in FormatoCore metadata.
Raw XML metadata is not exposed as a separate tree.

Slabs copy only the requested pixels from a read-only mmap; the mapping outlives the reader if its signal is retained.
Files must remain unchanged during use. Length is checked before mapping and again before each read, but concurrent
external mutation of a mapped file is unsupported. Missing companions, malformed XML, nonpositive or overflowing
shapes, invalid numeric calibrations and incorrect raw lengths throw `EMPADError`. Unlike RosettaSciIO's eager
reader, trailing raw bytes are refused. Arbitrary Python literal expressions in XML are refused. Repeated XML scalar paths retain their last value.

The committed synthetic pair and complete byte/axis/metadata pins are produced by `tools/empad/generate.py`
under the pinned FormatoKit venv with `../tools/memcap.sh`. Tests inflate the small gzip fixtures in a temporary directory;
no Python dependency is needed to run them. NaN, infinity and signed-zero bits are preserved; `remove_nans` is not ported.
4D HDF5 reading remains future work.

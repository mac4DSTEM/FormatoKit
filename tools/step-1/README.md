# tools/step-1: the oracle pins

`pins.py` reads the pinned RosettaSciIO (commit `049e7d70`, `docs/registration-step-1.md` section 2) and writes what it
returns, so the Swift tests (gates P1 and U1) compare against numbers that exist before the Swift code. Python only.
Agreement with RosettaSciIO is agreement with an independent reading of the same bytes, not truth.

## Run

    References/rsciio-venv/bin/python -I -B tools/step-1/pins.py [--work DIR]
    References/rsciio-venv/bin/python -I -B tools/step-1/pins.py --owner FILE [FILE ...] --out PATH [--work DIR]

- Default mode writes `Tests/FormatoCoreTests/Fixtures/step-1-pins.json` (public files) and `units-pins.json`.
- `--owner` writes the same per-file records for the files named on the command line (`.dm3`/`.dm4`, and `.emd` that are
  Velox; others are listed under `skipped`) to PATH. PATH is scratch: never commit it. The path of each file is recorded as
  its basename only. A file where the oracle's own checks fail (see "stops" below) gets `oracle_check_failed` instead of
  signals.
- `--work DIR` (an existing directory, default the system temp dir) is where each public zip is unzipped, into a fresh
  directory made for it. The clone is never written to.
- The script stops unless `rsciio.__file__` is inside `References/rsciio-venv`, the clone's HEAD is the pin, and the
  installed `digitalmicrograph/_api.py`, `emd/_api.py`, `emd/_emd_velox.py`, `utils/_units.py`, `utils/hdf5.py` equal the
  clone's, byte for byte. Each public file and zip is checked against `rsciio/tests/registry.txt`. It builds everything twice
  in the process and stops if the two outputs differ. Output: sorted keys, indent 1, UTF-8, no times, no absolute paths,
  non-finite numbers as `null` (the `*_bits` field carries them).
- Stops (in `--owner` mode the file gets `oracle_check_failed` instead): an axes count different from the array's rank, a DM
  `ImageList` listing whose length differs from the signals rsciio returned, an h5py image listing whose length differs from
  the Velox signals rsciio returned.

## The venv has no `sparse`

rsciio's `_read_data` reads the images of a Velox SpectrumStream file, then raises `ModuleNotFoundError` if `sparse` is not
importable, before the spectrum stream is read. With `sparse` absent `file_reader(..., select_type="images")` therefore
raises on every file that has a `Data/SpectrumImage` group. Inside the single `file_reader` call, `pins.py` makes that one
`find_spec("sparse")` answer "present" and makes `_read_spectrum_stream` do nothing (`sparse_stub`); the image path runs
unchanged. Those files carry `"spectrum_stream_not_read": true`. With `sparse` installed the stub does nothing.

## `step-1-pins.json`

Top level: `generator`, `reference`, `versions` (python, numpy, h5py, pint), `set`, `files`, `skipped_non_velox_emd`
(every loose `.emd` of `emd/` whose root `Version` is not `format: "Velox"`, with the format found, null when there is no
`Version`).

Files are in a fixed order: DM sorted by path, then loose `.emd`, then zip members. Each file record:

| field | meaning |
|---|---|
| `set` | `public` or `owner` |
| `path` | public: relative to `rsciio/tests/data`; zip members are `emd/<zip file name>/<member name>`; owner: basename |
| `format` | `dm` or `velox` |
| `sha256`, `bytes` | of the file |
| `raises` | null, or `{type, message}` of what rsciio raised (then `signals` is empty) |
| `spectrum_stream_not_read` | Velox only, see above |
| `signals` | rsciio's returned signals, in order |

Each signal:

| field | meaning |
|---|---|
| `dm_index` (DM) | the ONE-BASED position in `ImageList` (rsciio's `TagGroup<k>` is `k = index - 1`), derived as SpectroKit's `truth.py` does: parse with `DigitalMicrographReader`, take the `ImageList` groups not listed in `Thumbnails.N.ImageIndex` |
| `velox_image_id` (Velox) | the name of the `Data/Image/<id>` group (h5py order); the run stops unless h5py lists the same number of groups with a rank-3 `Data` and a `Metadata` dataset as rsciio returns signals |
| `title`, `signal_type` | `metadata.General.title`, `metadata.Signal.signal_type` (null when rsciio does not set it, as for Velox) |
| `dtype` | numpy name (`float32`, `complex64`, `bool`, ...); for a structured dtype (DM RGBA) `str(dtype)` |
| `dtype_str` | numpy `dtype.str` (`<f4`, `|u1`), null for structured; shows the byte order rsciio returned |
| `shape` | the returned array's shape, unsqueezed (the `squeeze` in rsciio's `post_process` belongs to HyperSpy, not applied) |
| `data_sha256` | sha256 of the data in C order, little-endian: `np.ascontiguousarray(data).astype(dtype.newbyteorder('<')).tobytes()` |
| `axes` | rsciio's axes in array order (`index_in_array` is checked to be the list position): `name` (str or null), `size`, `scale`/`offset` as float (null if not finite) and `scale_bits`/`offset_bits` (16 lowercase hex digits of the IEEE-754 double, big-endian `struct.pack('>d')`), `units` exactly as rsciio gives it, `navigate` |
| `axes_sizes_match_shape` | whether the axes' `size` list equals `shape` (false for DM test_fft_packed_complex8.dm4) |
| `metadata` | list of `{key, kind, value[, value_bits], source}`; keys in this order, present only when rsciio sets them: `General.title`, `General.original_filename`, `Signal.signal_type` (DM only), then `Acquisition_instrument.TEM.beam_energy` and `Acquisition_instrument.SEM.beam_energy`. A beam energy is rsciio's returned `mapping` applied to `original_metadata` as HyperSpy does (value at the dotted source path, through the function if there is one); `source` is the mapping's key, as rsciio writes it (DM: `ImageList.TagGroup0...`, always `TagGroup0` because rsciio keeps one image at a time in `original_metadata`; stack-builder files read `...ImageTags.source.Tags at creation.Microscope Info.Voltage`). Numbers have `value_bits`; `kind` is `number` or `string` |
| DM: `data_offset`, `data_size` | where the pixel block is in the file and its length, from rsciio's parser |
| DM: `data_bytes_equal_file` | whether the little-endian bytes above equal the file's block at that offset (true for plain little-endian numeric types, RGBA and bool here; false where rsciio rebuilds the array, the packed-complex FFT) |
| Velox: `data_f32_sha256` | sha256 of `np.ascontiguousarray(data).astype('<f4').tobytes()`; null for complex |
| Velox: `float32_exact` | whether the conversion to float32 and back loses nothing (integers: exact value check; floats: byte equality); null for complex |

## `units-pins.json`

Top level: `generator`, `reference`, `versions`, `sweep` (seed 20261015, numpy `default_rng`; draw order: `10**uniform(-13,
4, 400)`, `integers(1, 8193, 400)` for "m", then the same with 200 for "s"), `records`.

Every record is the output of RosettaSciIO's own function, called by the script (no unit table is retyped):

- `fn: "convert_scale_units"`: `FeiEMDReader._convert_scale_units(<dummy self>, value, units, factor)`, with `factor` exactly
  what the caller passes (the function halves it); `out`, `out_units`.
- `fn: "convert_units"`: `rsciio.utils._units.convert_units(value, units, to_units)`; `out`, `out_units` (= `to_units`).
- `value`/`out` as float (null if not finite) and `value_bits`/`out_bits`; `units` may be `""` or null; `value_text` is the
  string the file held when the Velox JSON stores the number as a string. An exception is recorded as `raises:
  {type, message}` (none occurred).
- `case`: `public-velox` (the arguments the public Velox image path hands to the two functions, recorded while reading every
  public Velox file with `select_type="images"`, deduplicated), `sweep` (400 "m" and 200 "s" values with factors for
  `convert_scale_units`; each value also through `convert_units` m to m, mm, µm (U+00B5), nm, pm and s to s, ms, µs, ns),
  `planted` (the cases of registration section 4 and a few neighbours: zero, NaN, `""`, `1/nm`, `None`).

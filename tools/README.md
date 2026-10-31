# tools

Scripts that generate and pin the test fixtures, check the public API from outside the package, build libhdf5 and time
the kit against the Python packages. Run every command from the repository root. The tests never run Python: they read
the committed fixtures (`Tests/*/Fixtures`), so `swift test` needs none of this.

## Python environment

One environment, `tools/requirements.txt`: RosettaSciIO `049e7d70`, py4DSTEM `f050d207`, tifffile 2026.9.20, NumPy 2.5.4,
h5py 3.16.0, Pint 0.26.1 and every dependency, at exact versions (the file says how to build it). The generators run
with its interpreter, isolated (`References/venv/bin/python -I -B tools/...`), and stop if the reference they import is
not the pinned one.

One path convention: everything a generator reads outside the repository is under `References/` at the repository root
(not tracked; in a worktree, a link to the main checkout's):

| Path | What |
|---|---|
| `References/venv` | the environment of `tools/requirements.txt` |
| `References/rosettasciio-049e7d70` | the pinned RosettaSciIO clone (its public test data and `registry.txt`) |
| `References/py4DSTEM-f050d207` | the pinned py4DSTEM clone |

Some scripts also read a pinned clone of a consumer app (located by `MACEM_SUITE`, the folder holding the app
checkouts) or of pyEELSMODEL by commit; they say which.

The committed fixtures were written before the one environment, in two (RosettaSciIO's, Python 3.14; py4DSTEM's,
Python 3.12, with h5py 3.11.0, NumPy 2.5.0 and emdfile 0.0.15, the versions its fixtures record). The scripts only
changed where they look; a fixture is regenerated in `References/venv` when its generator next runs, and one that
changes is its own commit. The py4DSTEM-side fixtures (`4d/`, `bragg/` and the two `check-result.json`) were
regenerated in `References/venv` on 2026-10-31 and now record h5py 3.16.0, NumPy 2.5.4 and emdfile 0.0.16.

Two sources of run-to-run change are pinned: the emdfile writers (`hdf5-4d`, `bragg-writer`) replace the random root `UUID` with one
derived from the fixture path, and `velox-spectrum/pins.py` names the time zones on a fixed summer day.

## Fixture generators

Each writes or pins files under `Tests/*/Fixtures/`; `Tests/Fixtures/README.md` lists every fixture and the script that
names it. A regenerated fixture that changes is its own commit, with the reason and a CHANGELOG line.

| Folder | Scripts | What it writes or pins |
|---|---|---|
| `acq-metadata` | `generate.py`, `no_unit.py`, `rsciio_oracle.py`, `harness.swift` | acquisition metadata of DM4, MRC, TIFF and Velox files: RosettaSciIO's mapping and the first consumer's readers |
| `bragg-writer` | `generate.py`, `check.py`, `structure.py` | py4DSTEM BraggVectors (EMD 1.0) files and the check of the Swift-written ones |
| `dm-scan` | `pins.py` | RosettaSciIO's scan axes of the committed DM fixtures |
| `dm-velox-pins` | `pins.py`, `owner-check.sh` | RosettaSciIO's reading of every public DM and Velox test file (`dm-velox-pins.json`) and its unit conversions (`units-pins.json`); see its README |
| `dm4-gather` | `generate.py`, `make_dm3.py` | synthetic 4D DM4 and DM3 files and their byte and axis pins |
| `eels-reader` | `make_planted.py`, `truth.py` | the planted and refused EELS DM4 files and RosettaSciIO's truth for them (from SpectroKit 0.3.0) |
| `emd-bundle` | `check.py`, `oracle/` | the check of the Swift-written EMD bundles against the first consumer's writers, h5py and py4DSTEM |
| `empad` | `generate.py` | EMPAD fixtures |
| `fixture-index` | `index.py` | `Tests/Fixtures/README.md`, the index of every fixture (standard library; `--check` in CI) |
| `hdf5-4d` | `generate.py` | py4DSTEM EMD 1.0 4D datacubes |
| `hdf5-append` | `generate.py` | fixtures and h5py pins for `HDF5Reader` and `HDF5AppendWriter` |
| `hdf5-write` | `generate.py` | HDF5 root-attribute fixtures and h5py pins |
| `mib` | `generate.py`, `app-scaffold.swift` | Quantum Detectors MIB frames and refusals |
| `msa` | `pins.py` | RosettaSciIO's MSA reading of its public test files |
| `png` | `generate.py`, `check.py`, `oracle.sh` | the PNG input, the check of the Swift-written PNGs, the first consumer's text-chunk insertion |
| `shaped-tiff` | `pins.py` | tifffile-written TIFFs with the shaped description and RosettaSciIO's reading |
| `tiff-pins` | `make_planted.py`, `pins.py`, `owner-check.sh` | the planted TIFFs and RosettaSciIO's and tifffile's reading of every public and planted TIFF (`tiff-pins.json`); see its README |
| `units` | `pint_factors.py` | `Sources/FormatoCore/FormatoUnitsFactors.swift`, Pint's SI-prefix factors |
| `velox-axis-order` | `pin_axis_order.py` | RosettaSciIO's energy axis for the planted axis-order stream file |
| `velox-eels` | `pins.py` | a planted Velox EELS spectrum image, read by RosettaSciIO and pyEELSMODEL |
| `velox-elements` | `pins.py` | Velox `Sample.elements`, the file-level metadata groups and segment times |
| `velox-flags` | `make_velox_flags.py` | `velox-flags-planted.emd`, the two public stream flags |
| `velox-policy` | `make_policy_fixtures.py` | `policy/si-units-px.emd`, the unconverted-unit policy file |
| `velox-spectrum` | `pins.py` | planted Velox single-spectrum files and RosettaSciIO's reading |
| `velox-spectrum-image` | `make_velox_si.py`, `pins.py`, `refuter_pins.py`, `owner-check.sh` | the planted spectrum images and RosettaSciIO's spectrum-image reading of them and of the public files, and of the review files |
| `velox-times` | `pins.py` | planted Velox spectrum images with live and real times |
| `velox-tiny` | `make-tiny-fixture.py` | the tiny Velox files `VeloxEMDReaderTests` embeds (from mac4DSTEM) |
| `velox-titles` | `make_velox_titles.py`, `pins.py`, `refuter_pins.py` | the planted Velox title files, RosettaSciIO's reading of them and of the title review files |

`owner-check.sh` scripts read the owner's own data from `$MACEM_DATA` into `.build/`, never into the repository.

### Former names

Fixtures written before 2026-10-31 name their generator by its old folder in their `generator` field until they are
regenerated: `tools/step-1` is `dm-velox-pins` (and `units` for `pint_factors.py`), `tools/step-2` is `tiff-pins`,
`tools/step-3` is `velox-titles`, `tools/step-4` is `velox-spectrum-image`. The `set` labels inside those pins
(`step-3-planted`, `step-4`, ...) are kept as written.

## Package checks

```sh
tools/test.sh                   # the gate: swift test -c release, warning-checked
tools/consumer-check/run.sh     # separate packages that compile and run against the public API only
tools/build-docs.sh             # the DocC site
tools/xcframework/build.sh      # the libhdf5 xcframeworks
```

## Benchmarks

`tools/benchmarks/bench.py` (with `References/venv`) and `docs/benchmarks.md`.

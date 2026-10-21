# FormatoKit

File formats for electron microscopy: Velox EMD, GMS DM3/DM4, py4DSTEM HDF5/EMD, MRC, TIFF, MIB, EMPAD, PNG chunks. Pure Swift, no UI, standalone; the suite's rules are in `../CLAUDE.md`. Start with `README.md`,
`docs/parity.md` and the task.

## Reference
RosettaSciIO `049e7d70` (signals, axes, units, metadata, and where it raises) in `References/rsciio-venv`. libhdf5 is shipped as three signed xcframeworks (`dist/xcframeworks`, built by `tools/xcframework`); one process-wide lock `HDF5Serial`. Fixtures are generated from it (`tools/*/pins.py`) and committed under `Tests/*/Fixtures/`; a difference inside
the reference's own tolerance is agreement, outside it a bug. Readers, I/O, indices and metadata exact.

## Build and test
```sh
swift build
swift test -c release --parallel --skip FormatoKitParityTests   # per-session gate: the fast unit target
swift test -c release --parallel   # full suite with FormatoKitParityTests: before a tag and in the nightly (Debug is many times slower)
tools/consumer-check/run.sh    # a separate package that compiles against the public API
```
Never `swift build --build-tests -c release` (fails on this toolchain). Real-data tests skip when the data is absent.

## Modules
`FormatoCore`, `FormatoHDF5` (the loader, lock, hyperslabs, writers), `FormatoEMD` (Velox), `FormatoDM`, `FormatoMRC`, `FormatoTIFF`, `FormatoMIB`, `FormatoEMPAD`, `FormatoMSA`.

## Rules of the kit
- Public API only; nothing names an app or an app type; error messages never say "mac4DSTEM" or "macTEM".
- Rows and columns, not x and y. Every accelerated path keeps the CPU float64 path as its reference (D16).
- A new or changed number gets a test against the reference at its upstream tolerance, and a row in `docs/parity.md`.
- Readers are exact against the reference; bytes, shapes, axes and metadata, never a tolerance. The HDF5 loader is cached once per process; handles are never held across an `await`.
- The warning check in `tools/test.sh` stays: the package builds with zero warnings.

## Closeout
`swift test -c release` green; `CHANGELOG.md` entry with a Migration paragraph where a consumer must change something;
version bumped in the entry; one commit on `main` whose last paragraph is the hand-off. Paul tags with
`../macEM-suite/tools/ship.sh` (tag = CHANGELOG top version).

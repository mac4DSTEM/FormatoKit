# FormatoKit

The macEM suite's file-format library for macOS: the Mac counterpart of [RosettaSciIO](https://github.com/hyperspy/rosettasciio).
A Swift package of readers (and later writers) for the electron-microscopy formats, one module per format over one data model,
checked bit for bit against RosettaSciIO. No UI. mac4DSTEM, macTEM and SpectroKit import it by tagged version, and anyone can
build on it. Swift 6 strict concurrency, headless, lazy where a file is large, one SwiftPM product per module.

| Module | Scope | State |
|---|---|---|
| `FormatoCore` | the data model: arrays as stored, axes, units (Pint's compact units, ported), metadata with provenance, lazy signals; cancellation | step 1 |
| `FormatoDM` | Gatan DigitalMicrograph `.dm3` / `.dm4`: listing, 2D images, EDS and EELS spectrum images, the tag tree; every object as a signal | step 1 (moved from SpectroKit 0.3.0, plus the signal adapter) |
| `FormatoEMD` | Thermo Fisher Velox `.emd`: spectrum streams (sparse), images, metadata; images as signals. Later: NCEM / Berkeley EMD | step 1 (moved from SpectroKit 0.3.0, plus the image adapter) |
| `FormatoHDF5` | the process-wide HDF5 lock and quit barrier, the shipped libhdf5. Later: hspy, the sidecar | step 1 (moved) |
| `FormatoTIFF` | FEI / Thermo Fisher and TIA TIFF metadata, ImageJ, Gatan tag 65027 | empty: step 2 |
| `FormatoMRC` | MRC / MRC2014 with FEI extended headers | empty |
| `FormatoEMPAD` | EMPAD 4D-STEM raw data; the 4D HDF5 readers | empty |
| `FormatoMSA` | EMSA/MAS spectra | empty |

`docs/parity.md` is the checklist against RosettaSciIO's formats table: what reads, what is pinned, what is next.

## Requirements

macOS 27 on Apple silicon, Swift 6.2 tools. **libhdf5 is inside the package** (HDF5 2.1.1 with libsz and libaec, arm64, as a
resource of `FormatoHDF5`), so `swift build` and `swift test` need nothing installed. A host app that embeds its own libhdf5
in `Frameworks/` is served first; `MAC4DSTEM_HDF5_PATH` overrides both. iPadOS is not claimed yet.

## Licence

GPL-3.0 (`LICENSE`, `NOTICE`). The DM and Velox readers were moved from **SpectroKit** 0.3.0 (GPL-3.0, itself extracted from
mac4DSTEM). The signal adapters port **RosettaSciIO**'s rules (GPL-3.0-or-later, the HyperSpy developers), which is also the
oracle every reader is checked against; `FormatoUnits` ports what RosettaSciIO does with **Pint** (BSD-3-Clause) and carries
Pint's conversion factors. HDF5, libaec and libsz are BSD-style (`Licenses/`). One GPL part makes the package GPL-3.0: an app
built on it must be GPL-compatible.

## Build and test

```sh
tools/test.sh                      # the gate: swift test -c release, warning-checked, stamps .build/last-green
tools/last-green.sh                # the last green commit and whether HEAD equals it
tools/step-1/names.sh              # the 121 test names moved from SpectroKit 0.3.0 are all here
tools/step-1/owner-check.sh        # the owner's files against RosettaSciIO (needs the suite's data/ folder)
python3 -I tools/step-1/mutants.py # break-once proof on a copy of HEAD
```

The oracle is not in the repository: `References/rosettasciio-049e7d70` (the pinned clone) and `References/rsciio-venv`;
`docs/registration-step-1.md` §2 says how they are pinned. Without them the pins test runs on the committed public file only.

## Status

`docs/status.md`. No tag yet; the first (0.0.1) is the owner's.

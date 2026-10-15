# CLAUDE.md — start here

FormatoKit: the macEM suite's file-format library, the Mac counterpart of RosettaSciIO: readers (later writers) for the EM
formats, one module per format over one data model, checked bit for bit against RosettaSciIO, imported by tagged version by
SpectroKit, mac4DSTEM and macTEM. GPL-3.0 (README.md says which parts come from where). Modules: `FormatoCore` (the data
model, units, cancellation), `FormatoDM`, `FormatoEMD`, `FormatoHDF5` (step 1), `FormatoTIFF` (step 2), and `FormatoMRC`,
`FormatoEMPAD`, `FormatoMSA` (empty, their scope in a doc comment). Rules only here; state in `docs/status.md`.

## Read first

1. The suite's `../CLAUDE.md` (board, tiers, how we work) and `../ROADMAP.md`, "Kits" and "Kits: the execution plan" (phase 3).
2. `docs/registration-step-1.md`, `docs/registration-step-2.md` and `docs/registration-step-3.md` with their amendments:
   what each step made, the definitions, the gates.
3. `docs/status.md` (what is live, the hand-off) and `docs/parity.md` (against RosettaSciIO's formats table).
4. `../SpectroKit/CLAUDE.md`: the model for a kit repo, and where the readers came from.

## Hard rules

- **SpectroKit, mac4DSTEM and macTEM are read-only from here**: `git -C ../<repo> --no-optional-locks show <rev>:<path>` or
  `git archive` into a scratch folder, never their working trees. Never build, test or write in them.
- **Registration before code** for anything tier 1: `docs/registration-<step>.md` with the definitions, the pins, the planted
  truth, the gates and the planned mutants, committed before the first Swift line; a change after code starts is a dated
  amendment with its reason.
- **The moved readers change only on purpose.** `DM4Experiment.swift`, `DM4Error.swift`, `VeloxEMDReader.swift` and
  `HDF5Types.swift` differ from SpectroKit 0.3.0 only as registration §1.1 and its amendments say (access, imports, the three
  renames, the barrier's line, the shipped libhdf5 candidate). The 121 moved test names (`tools/step-1/names.sh`) and the
  golden's 175 lines change only on purpose.
- **The gate is `tools/test.sh`** (`swift test -c release "$@"`, warning-checked). Never `swift build --build-tests -c
  release` (fails on this toolchain). The only allowed warning is Swift Build's "not stripping binary because it is signed"
  for the three shipped dylibs in release.
- **Green stamp**: a full, passing `tools/test.sh` on a clean tracked tree writes `.build/last-green`; `tools/last-green.sh`
  prints it and whether HEAD equals it.
- **Hook**: `.claude/settings.json` runs `tools/hooks/no-sleep-poll.sh` before every Bash call (no sleep of 30 s or more, no
  sleep in a loop, no `killall`, no `pkill` without `-P <pid>` or a scratchpad path: kill your own jobs by pid). Proof:
  `tools/hooks/test-no-sleep-poll.sh`, also run by CI (`.github/workflows/ci.yml`).
- **A reference for every number.** RosettaSciIO at `049e7d7070e84779b499adaf3295beee9facb004` in the gitignored
  `References/rosettasciio-049e7d70`, installed from that clone into `References/rsciio-venv` (Python 3.14.7, NumPy 2.5.4,
  h5py 3.16.0, Pint 0.26.1, tifffile 2026.9.20; `References/rsciio-venv-freeze.txt`). Oracles run as `References/rsciio-venv/bin/python -I -B`.
  Pins are generated before the Swift code that reads them (`tools/step-1/pins.py`, `tools/step-2/pins.py`, `tools/step-3/pins.py`); a difference is a failure of the port,
  never a tolerance to widen. Agreement with RosettaSciIO is agreement, not truth: truth is a planted file.
- **libhdf5 ships inside** `FormatoHDF5` (mac4DSTEM's vendored 2.1.1 at `5ba712a0`, sha256 in `NOTICE`): change it only with a
  registration, the three files together.
- **Public API only, no app types.** What a consumer reads is `public`; what one module needs from another is `package`.
  Nothing names an app type; error messages never say "mac4DSTEM", "macTEM" or "ACOM".
- **Tests are Swift Testing** (the owner's standard for the kits, 2026-10-15): `import Testing`, `@Test`, `#expect`; never XCTest.
- **Rigour follows risk** (`../CLAUDE.md`): tier named in every commit; tier 1 is registration, every new test broken once
  (`tools/step-1/mutants.py [--step 2|3]`), one Gate B refuter on the frozen commit, Gate D when a cause is unproven, a fixture.
- **The owner's data** lives in `../data`, read as `$MACEM_DATA`: never copied or committed; numbers measured on it are cited
  with their log; a manifest line in `../data/README.md` per file used; never a gate.
- **Pushing, tagging and creating the remote are the owner's.** One session per repo; `main` only; commit by explicit paths at
  every green checkpoint. At each tag, `CHANGELOG.md` says what each consumer changes (a Migration paragraph; `docs/consumers-*.md` up to 0.2.0).
- **Names** (the suite's standard): the library is domain + `Kit`, modules carry its prefix (`Formato*`).
- **Suite board**: this repo's row is `lanes/formatokit`; how a session opens and closes it is in `../CLAUDE.md`.

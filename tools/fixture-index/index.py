#!/usr/bin/env python3
"""Writes Tests/Fixtures/README.md: one row per tracked fixture, with its size, its generator and its source.

    python3 -I -B tools/fixture-index/index.py           rewrite the index
    python3 -I -B tools/fixture-index/index.py --check   exit 1 if the committed index is not what this script writes

Standard library only (no venv). The fixtures are the files `git ls-files` lists under `Tests/*/Fixtures/`. Each is
matched against RULES below, first match wins; the script stops when a fixture matches no rule, or a rule names a
generator that is not in tools/, or a rule matches nothing. A new fixture therefore needs a rule here, and the index is
rewritten in the same commit (CI runs --check).
"""
import fnmatch
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "Tests" / "Fixtures" / "README.md"

RSCIIO = "RosettaSciIO 049e7d70"
RSCIIO_PUBLIC = "third party: RosettaSciIO public test data (GPL-3.0-or-later), copied unchanged"
SK030 = "SpectroKit 0.3.0 (tag 14c6acf8), byte-identical copy"
ACQ = "planted; pins " + RSCIIO + " and the consumer's readers"

# (pattern under Tests/, generator under tools/ or None, source). A pattern's `*` also crosses `/`.
RULES = [
    # FormatoCoreTests
    ("FormatoCoreTests/Fixtures/png/check-result.json", "png/check.py", "the check of the Swift-written PNGs"),
    ("FormatoCoreTests/Fixtures/png/input.png", "png/generate.py", "planted"),
    ("FormatoCoreTests/Fixtures/png/mactem-inserted.png", "png/oracle.sh", "the first consumer's text-chunk insertion"),
    ("FormatoCoreTests/Fixtures/png/swift-*.png", "png/check.py", "written by the kit, checked by the script"),
    ("FormatoCoreTests/Fixtures/refuter/*", "velox-titles/refuter_pins.py", "planted review file"),
    ("FormatoCoreTests/Fixtures/refuter-pins.json", "velox-titles/refuter_pins.py", RSCIIO),
    ("FormatoCoreTests/Fixtures/dm-velox-pins.json", "dm-velox-pins/pins.py", RSCIIO + ", Pint 0.26.1"),
    ("FormatoCoreTests/Fixtures/units-pins.json", "dm-velox-pins/pins.py", RSCIIO + ", Pint 0.26.1"),
    ("FormatoCoreTests/Fixtures/velox-titles-pins.json", "velox-titles/pins.py", RSCIIO),
    ("FormatoCoreTests/Fixtures/velox-titles-refuter-pins.json", "velox-titles/refuter_pins.py", RSCIIO),
    ("FormatoCoreTests/Fixtures/velox-spectrum-image-pins.json", "velox-spectrum-image/pins.py", RSCIIO),
    ("FormatoCoreTests/Fixtures/velox-spectrum-image-refuter-pins.json", "velox-spectrum-image/refuter_pins.py", RSCIIO),
    # FormatoDMTests
    ("FormatoDMTests/Fixtures/acq-metadata/*", "acq-metadata/generate.py", ACQ),
    ("FormatoDMTests/Fixtures/gather/*.dm3", "dm4-gather/make_dm3.py", "re-emitted from the DM4 of the same name"),
    ("FormatoDMTests/Fixtures/gather/*", "dm4-gather/generate.py", "planted; pins " + RSCIIO),
    ("FormatoDMTests/Fixtures/dm-scan-pins.json", "dm-scan/pins.py", RSCIIO),
    ("FormatoDMTests/Fixtures/demo-edx-tiny.*", None, "the first consumer's EDX demo simulator; " + SK030),
    ("FormatoDMTests/Fixtures/dm-tag65027-saved-with-DM.*", None, "a DM-saved TIFF tag stream; " + SK030),
    ("FormatoDMTests/Fixtures/eels-*.truth.json", "eels-reader/truth.py", RSCIIO + "; from SpectroKit 0.3.0"),
    ("FormatoDMTests/Fixtures/eels-*.dm4", "eels-reader/make_planted.py", "planted; from SpectroKit 0.3.0, byte-reproducible"),
    ("FormatoDMTests/Fixtures/rsciio-EELS_SI.dm4", None, RSCIIO_PUBLIC + " (`digitalmicrograph/3D/EELS_SI.dm4`); sha256 checked by `tools/eels-reader/truth.py`; from SpectroKit 0.3.0"),
    ("FormatoDMTests/Fixtures/rsciio-EELS_SI.truth.json", "eels-reader/truth.py", RSCIIO + "'s reading of its public file; from SpectroKit 0.3.0"),
    ("FormatoDMTests/Fixtures/rsciio-Mon*CL_spectrum-ccd.dm4", None, RSCIIO_PUBLIC + " (RosettaSciIO 8363d24 `digitalmicrograph/1D/`); sha256 equal to its `registry.txt`"),
    # FormatoEMDTests
    ("FormatoEMDTests/Fixtures/acq-metadata/velox-no-unit*", "acq-metadata/no_unit.py", "planted (from velox-acquisition.emd); pins " + RSCIIO),
    ("FormatoEMDTests/Fixtures/acq-metadata/*", "acq-metadata/generate.py", ACQ),
    ("FormatoEMDTests/Fixtures/image-readers/*", "acq-metadata/generate.py", ACQ),
    ("FormatoEMDTests/Fixtures/eels/*", "velox-eels/pins.py", "planted; pins " + RSCIIO + " and pyEELSMODEL eed9f072"),
    ("FormatoEMDTests/Fixtures/elements/*", "velox-elements/pins.py", "planted; pins " + RSCIIO),
    ("FormatoEMDTests/Fixtures/times/*", "velox-times/pins.py", "planted; pins " + RSCIIO),
    ("FormatoEMDTests/Fixtures/policy/*", "velox-policy/make_policy_fixtures.py", "planted"),
    ("FormatoEMDTests/Fixtures/spectra/*", "velox-spectrum/pins.py", "planted"),
    ("FormatoEMDTests/Fixtures/spectra-pins.json", "velox-spectrum/pins.py", RSCIIO + ", 4 process time zones"),
    ("FormatoEMDTests/Fixtures/velox-spectrum-image/refuter/*", "velox-spectrum-image/refuter_pins.py", "planted review file"),
    ("FormatoEMDTests/Fixtures/velox-spectrum-image/spectrokit/*", None, "copied unchanged from SpectroKit 0.4.0 (9b93fb4c), its planted stream files; sha256 in `spectrokit/PROVENANCE.md`"),
    ("FormatoEMDTests/Fixtures/velox-spectrum-image/*", "velox-spectrum-image/make_velox_si.py", "planted"),
    ("FormatoEMDTests/Fixtures/velox-titles-refuter/*", "velox-titles/refuter_pins.py", "planted review file"),
    ("FormatoEMDTests/Fixtures/velox-titles-*.emd", "velox-titles/make_velox_titles.py", "planted"),
    ("FormatoEMDTests/Fixtures/velox-flags-planted.emd", "velox-flags/make_velox_flags.py", "planted"),
    ("FormatoEMDTests/Fixtures/velox-metadata-planted.*", None, SK030 + " (its `tools/velox-metadata-parity/make_fixture.py`)"),
    ("FormatoEMDTests/Fixtures/velox-stream-axis-order.emd", None, "copied from SpectroKit c5a9a5e; sha256 checked by `tools/velox-axis-order/pin_axis_order.py`"),
    ("FormatoEMDTests/Fixtures/velox-stream-axis-order.pin.json", "velox-axis-order/pin_axis_order.py", RSCIIO),
    ("FormatoEMDTests/Fixtures/velox-tiny.emd", None, "the first consumer's Velox stream fixture; " + SK030),
    # FormatoEMPADTests, FormatoMIBTests
    ("FormatoEMPADTests/Fixtures/*", "empad/generate.py", "planted; pins " + RSCIIO),
    ("FormatoMIBTests/Fixtures/app-*", "mib/generate.py", "planted; pins the first consumer's pinned reader (via `tools/mib/app-scaffold.swift`)"),
    ("FormatoMIBTests/Fixtures/*", "mib/generate.py", "planted; pins " + RSCIIO),
    # FormatoGoldenTests
    ("FormatoGoldenTests/Fixtures/velox-tiny-reader.txt", None, "lines 1-175 of SpectroKit 0.3.0's golden `velox-tiny.txt`"),
    # FormatoHDF5Tests
    ("FormatoHDF5Tests/Fixtures/4d/*", "hdf5-4d/generate.py", "py4DSTEM f050d207"),
    ("FormatoHDF5Tests/Fixtures/append/*", "hdf5-append/generate.py", "h5py 3.16.0"),
    ("FormatoHDF5Tests/Fixtures/low-level/*", "hdf5-append/generate.py", "h5py 3.16.0"),
    ("FormatoHDF5Tests/Fixtures/bragg/swift-*", "bragg-writer/check.py", "written by the kit, checked with py4DSTEM f050d207"),
    ("FormatoHDF5Tests/Fixtures/bragg/check-result.json", "bragg-writer/check.py", "py4DSTEM f050d207"),
    ("FormatoHDF5Tests/Fixtures/bragg/*", "bragg-writer/generate.py", "py4DSTEM f050d207"),
    ("FormatoHDF5Tests/Fixtures/emd-bundle/app-*", "emd-bundle/oracle/run.sh", "the first consumer's writers"),
    ("FormatoHDF5Tests/Fixtures/emd-bundle/*", "emd-bundle/check.py", "written by the kit, checked with h5py and py4DSTEM f050d207"),
    ("FormatoHDF5Tests/Fixtures/root-attributes/*", "hdf5-write/generate.py", "h5py 3.16.0"),
    # FormatoMRCTests
    ("FormatoMRCTests/Fixtures/*", "acq-metadata/generate.py", ACQ),
    # FormatoMSATests
    ("FormatoMSATests/Fixtures/public/*", "msa/pins.py", RSCIIO_PUBLIC + " (`msa`)"),
    ("FormatoMSATests/Fixtures/msa-pins.json", "msa/pins.py", RSCIIO),
    # FormatoTIFFTests
    ("FormatoTIFFTests/Fixtures/planted/*", "tiff-pins/make_planted.py", "planted; truth tifffile 2026.9.20"),
    ("FormatoTIFFTests/Fixtures/tiff-pins.json", "tiff-pins/pins.py", RSCIIO + ", tifffile 2026.9.20"),
    ("FormatoTIFFTests/Fixtures/shaped/*", "shaped-tiff/pins.py", "tifffile 2026.9.20"),
    ("FormatoTIFFTests/Fixtures/shaped-pins.json", "shaped-tiff/pins.py", RSCIIO + ", tifffile 2026.9.20"),
    ("FormatoTIFFTests/Fixtures/refuter/*", "velox-titles/refuter_pins.py", "planted review file"),
    ("FormatoTIFFTests/Fixtures/refuter-pins.json", "velox-titles/refuter_pins.py", RSCIIO + ", tifffile 2026.9.20"),
    ("FormatoTIFFTests/Fixtures/acq-metadata/*", "acq-metadata/generate.py", ACQ),
    ("FormatoTIFFTests/Fixtures/app-image/*", "acq-metadata/generate.py", "planted; pins the consumer's readers"),
    ("FormatoTIFFTests/Fixtures/image-readers/*", "acq-metadata/generate.py", ACQ),
]

HEADER = """# Test fixtures

Written by `tools/fixture-index/index.py`; do not edit by hand. A new or moved fixture needs a rule in that script, and
the index is rewritten in the same commit (CI runs `index.py --check`). A regenerated fixture that changes is its own
commit, with the reason and a CHANGELOG line.

One row per tracked file under `Tests/*/Fixtures/`: its size, the script under `tools/` that writes it (or *copied*),
and its source: the pinned reference that wrote or read it, or where a copied file comes from. {count} files.

The generators run in the one Python environment of `tools/requirements.txt` (`tools/README.md`). The tests never run
Python: they read these committed files, so `swift test` needs none of it.

Licence: every fixture is generated from this kit's own code and the pinned Python references and ships under the kit's
licence, except the {third} rows marked *third party*: keep their licence line when the files move. Nothing here is the
owner's data: real datasets are read from `$MACEM_DATA` and never copied into the repository.

The files copied from SpectroKit 0.3.0 (tag `14c6acf8`) are byte-identical to it (the moved test names and git blob ids
were checked at the move). The generators of its EELS files moved here (`tools/eels-reader`, byte-reproducible); the
others stay in SpectroKit or the first consumer, named in the rows.

| File | Size | Generated by | Source |
|---|---|---|---|
"""


def size(n):
    if n < 1024:
        return f"{n} B"
    return f"{n / 1024:.1f} KB" if n < 1024 * 1024 else f"{n / 1024 / 1024:.1f} MB"


def fixtures():
    out = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "Tests"], text=True)
    names = [p for p in out.split("\0") if p]
    return sorted(p[len("Tests/"):] for p in names if "/Fixtures/" in p and not p.startswith("Tests/Fixtures/"))


def render():
    errors = []
    for _, gen, _ in RULES:
        if gen is not None and not (ROOT / "tools" / gen).is_file():
            errors.append(f"rule names tools/{gen}, which is not a file")
    used = set()
    rows = []
    third = 0
    for path in fixtures():
        hit = next((i for i, r in enumerate(RULES) if fnmatch.fnmatchcase(path, r[0])), None)
        if hit is None:
            errors.append(f"no rule for Tests/{path}")
            continue
        used.add(hit)
        _, gen, source = RULES[hit]
        third += source.startswith("third party")
        by = f"`tools/{gen}`" if gen else "*copied*"
        rows.append(f"| `{path}` | {size((ROOT / 'Tests' / path).stat().st_size)} | {by} | {source} |")
    for i, r in enumerate(RULES):
        if i not in used:
            errors.append(f"rule {r[0]!r} matches no fixture")
    if errors:
        sys.exit("tools/fixture-index/index.py:\n  " + "\n  ".join(errors))
    return HEADER.format(count=len(rows), third=third) + "\n".join(rows) + "\n"


def main():
    text = render()
    if sys.argv[1:] == ["--check"]:
        if OUT.read_text() != text:
            sys.exit("Tests/Fixtures/README.md is not current: run python3 -I -B tools/fixture-index/index.py")
        return
    if sys.argv[1:]:
        sys.exit(__doc__)
    OUT.write_text(text)


if __name__ == "__main__":
    main()

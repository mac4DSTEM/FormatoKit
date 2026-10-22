# Status

FormatoKit 0.10.0 (2026-10-22), against RosettaSciIO 0.14.0 (38 plugins on disk: 2 present, 5 partial, 31 missing, `docs/parity.md`). Live: Gatan DM3/DM4, TIFF
and shaped-TIFF series, MRC, Merlin MIB (pinned byte for byte, including the app convention), EMPAD, MSA/EMSA, Velox EMD (images, spectrum images, single spectra,
acquisition metadata), generic HDF5 read, append and write sessions, the BraggVectors writer, `FormatoLoader.sniff/load` over them, and `Peek` (one decimated frame and the header facts of a file, for Quick Look). Timings against
RosettaSciIO: `docs/benchmarks.md`; what is open (Velox live/real times and GMS EDS geometry need Paul's files; DM and TIFF read speed): `docs/open-items.md`.

Test split (2026-10-21): the comparisons with the pinned RosettaSciIO and Pint values (`PinsTests`, `SpectrumImagePinsTests`, `UnitsTests`, `FormatoTIFFPinsTests`) and the inherited golden baseline are the `FormatoKitParityTests` target (fixtures stay in `Tests/Formato*Tests/Fixtures`, found through `FormatoKitTestSupport`); `tools/test.sh --parallel --skip FormatoKitParityTests` (or `swift test -c release --parallel --skip FormatoKitParityTests`) is the per-session gate (345 tests), plain `tools/test.sh --parallel` the full suite (360 tests, unchanged: 345 fast + 15 parity). The HDF5 exit-barrier test needs `tools/test.sh` (it sets `FORMATO_HDF5_PATH`). Mac, release, warm build: fast target 8.2 s, full suite 9.4 s through `tools/test.sh` (19.7 s before, a build included).

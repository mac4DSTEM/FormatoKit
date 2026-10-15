# tools/step-1/move-parity: gate M3 (move parity)

`docs/registration-step-1.md` section 6, M3: the readers moved from SpectroKit 0.3.0 into FormatoKit give byte-identical
outputs. `run.sh` proves it on many files by running one dump program against both code bases.

## What is compared

`dump.swift` is one program. `run.sh` adds it to two scratch copies as the executable target `reader-dump`, builds each
in release (`swift build -c release --product reader-dump`, no tests), and runs both binaries on the same file list:

| Side | Copy | Imports prepended to `dump.swift` |
|---|---|---|
| spectro | SpectroKit tag `0.3.0`, by `git archive` (never its working tree) | `SpectroCore` |
| formato | FormatoKit's committed `HEAD`, by `git archive` (never the working tree) | `FormatoDM`, `FormatoEMD`, `FormatoCore` |

Those import lines are the only difference between the two sources. The target sits inside each copied package, so the
`package` declarations of the moved readers (`readEDSSpectrumImage` in SpectroKit, `markersPerFrame`,
`streamLengthAndMarkers`, `readFrameTransformations`, `readFrameDetectorTimes`) are callable on both sides. The dump walk
is `GoldenDump`, SpectroKit 0.3.0's reflection walk as `FormatoGoldenTests` copies it: one line per scalar, floats by bit
pattern, big numeric arrays by count, exact sum and bit hash.

Per file, by extension:

- **.dm3 / .dm4:** `DM4Experiment.list(path:)` (all stored fields); for each object `readImage(path:index:)` when it is 2D
  (also for the others when under 64 MB, so the refusals are compared), `readEELSSpectrumImage` for role `.eels`,
  `readEDSSpectrumImage` for role `.eds`; and `tagTree(data:)` on the file's bytes when the file is under 64 MB.
- **.emd:** `isVeloxFile`, `isVeloxEMD`, `images()`, `readImageFrame(id:frame:)` for frame 0 and the last frame of each
  image; when `isVeloxEMD`: `readSpectrumImage()` (all stored fields, the event store included), the store's counts line,
  `summedSpectrum()`, `denseCounts()` when the dense size is under 50 M values, `markersPerFrame()`,
  `streamLengthAndMarkers()`, `readFrameTransformations()`, `readFrameDetectorTimes()`; and `storedElementSelection()`
  whenever the file is a Velox file (a small addition beyond the registered list: it also compares that call's refusals).
- For files over 1 GB the tag tree and the dense counts are skipped (the rule for tag trees is already "under 64 MB").
- Every thrown error is printed as `<call>: error <localizedDescription>` and `<call>: error-type <type>`; nothing is fatal.
  A process that crashes is recorded by an `exit status: N` last line, so a crash has to match too.

The file list (`files.tsv` in the scratch folder):

1. every committed fixture, `Tests/Formato*Tests/Fixtures/*.dm3|dm4|emd` (from the HEAD copy);
2. every RosettaSciIO public DM file under `rsciio/tests/data/digitalmicrograph/`, and every loose `.emd` under
   `rsciio/tests/data/emd/` (the non-Velox ones are in on purpose: both sides must refuse them identically);
3. the `.emd`/`.dm3`/`.dm4` inside the four public zips of `rsciio/tests/data/emd/`, each zip's sha256 first checked against
   `rsciio/tests/registry.txt` (the run stops on a mismatch), unzipped into the scratch folder;
4. with `--owner`: every `*.dm3`, `*.dm4`, `*.emd` under `$MACEM_DATA/{tem,stem-edx,eels}` (default `../data` from the
   FormatoKit root), read in place, never copied.

libhdf5: both runs export `MAC4DSTEM_HDF5_PATH` as the copy FormatoKit ships (the HEAD copy's
`Sources/FormatoHDF5/Resources/hdf5/libhdf5.dylib`); SpectroKit 0.3.0 has no bundled one.

## What is normalised

The names that differ by design, mapped in the dump to neutral tokens before it is written (`normalise` in `dump.swift`):

- `SpectroCancelled` and `FormatoCancelled` to `<Cancelled>`; `SpectroCancellation` and `FormatoCancellation` to
  `<Cancellation>`;
- the module prefixes `SpectroCore.`, `FormatoDM.`, `FormatoEMD.`, `FormatoHDF5.`, `FormatoCore.` removed (they appear in
  the `error-type` lines, which print `String(reflecting:)`).

Nothing else is normalised: not floats, not order, not error text. Not in scope: the quit barrier's stderr line (`SpectroKit:`
versus `FormatoKit:`); stderr is kept in `logs/` and compared only as information.

## Run

    tools/step-1/move-parity/run.sh [--owner] [--scratch DIR] [--jobs N] [--reuse]

`--scratch` (or `M3_SCRATCH`) is where everything goes, default `/private/tmp/formato-move-parity`: the two copies and their
build, `bin/`, `out/{spectro,formato}/<n>-<label>.txt` (the dumps that are compared), `logs/` (build logs, stderr, seconds per
file and side), `files.tsv`. A normal run deletes the copies and starts fresh; `--reuse` keeps them and their build cache
(development only). `--jobs` (default 6, at most 8) files run side by side; files of 200 MB and up run one at a time.
Output: `move-parity: N files, all byte-identical` and exit 0, or the first lines of `diff` for each differing file and exit 1.
The script writes nothing in any repository and reads the owner's data only. Needs `swift`, `git`, `unzip` and macOS 15 or later on
Apple silicon. Delete the scratch's `.build` folders after (they are build products).

## Result

Recorded 2026-10-15 (SpectroKit tag `0.3.0`; FormatoKit HEAD at the time, `f55b468`):

- without `--owner`: 151 files (10 fixtures, 128 loose public, 13 from the four zips); `move-parity: 151 files, all
  byte-identical`; 40,590 dump lines per side, 256 thrown errors printed (identically), every process exited 0, stderr
  empty; 25 s wall.
- with `--owner`: 169 files (the same 151 and 18 owner files, up to 1.7 GB); `move-parity: 169 files, all byte-identical`;
  67 s wall.
- The comparison itself was checked once: a scratch copy of FormatoKit with one character of one error message changed made
  the run exit 1 and print the differing lines of the 74 files that reach that message.

# Registration, 0.2.0: FormatoKit's own policies as parameters

Written 2026-10-15, 14:10 CEST, before any line of this change, for the 0.2.0 generality pass (every policy FormatoKit chose,
as opposed to RosettaSciIO's raises and the inherited readers' contracts, becomes a parameter whose default is the 0.1.1
behaviour). Tier 1 for P1 and P2 (a non-default path returns numbers a scientist reads), tier 2 for the rest. The design and the
classification of every refusal (which are policies, which stay: RosettaSciIO raising, memory safety, capability gaps, the
inherited contracts, hostile-file guards) were made by a design lane and are summarised here; the full table is in the 0.2.0
commit message trail and `docs/parity.md`.

## 1. What 0.2.0 makes

1. **`VeloxReadPolicy`** (FormatoEMD, public), carried by `VeloxSpectrumImageOptions.policy` and a new
   `VeloxImageSignals.init(path:policy:cancelled:)` (existing calls compile unchanged):
   - **P1 `unconvertedUnits`** (`FormatoUnconvertedUnits.refuse`, default; `.keepAsWritten`): a pixel unit FormatoUnits does
     not handle (outside m and s with SI prefixes; registration step 1 A5 F7) refuses the image by default. With
     `.keepAsWritten`, when every unit involved is the same unhandled string, the axes carry the file's numbers (`float()` only,
     no compacting, no factor) and the unit string as written. Pint raising (an overflow or underflow, two units of different
     base or power, a handled unit whose value overflows) stays a refusal under every option.
   - **P2 `spectrumImageGrid`** (`VeloxGridChoice.firstImageChecked`, default; `.firstImage`; `.scanSizeTimesArea`): the
     default is registration step 4 §3.3 (the first image's grid, refused where the stream's ScanSize x ScanArea disagrees).
     `.firstImage` is RosettaSciIO's own reading (no check). `.scanSizeTimesArea` decodes onto the stream's ScanSize x ScanArea
     when it gives a grid, else the first image's: not RosettaSciIO's number.
   - **P3 `maximumArrayBytes`** (`nil` = this machine's physical memory, default): the cap on one spectrum-image array.
   - **P8 `streamBlockValues`** (32 M values, default): the stream read's block size; no result depends on it.
2. **`TIFFReadOptions`** (FormatoTIFF), `TIFFSignals.init(path:options:)`: **P5 `vendorBranches`** (`.refuse`, default;
   `.readAsGeneric`): the vendor branches step 2 does not port (Zeiss SEM, TVIPS, Olympus SIS, JEOL SightX, Hamamatsu streak)
   are refused by name by default; `.readAsGeneric` reads such a file through the generic page path (what RosettaSciIO returns for
   a file without the vendor tag, not for that vendor). Layout refusals (compression, tiles) stay.
3. **`DMReadOptions`** (FormatoDM): **P6 `maximumStringBytes`** (4096, default): the inherited DM walk keeps a string up to this
   many bytes (a type-18 string is cut there, a UTF-16 string at or past it is absent; registration step 1 A5). Numeric arrays
   keep their fixed 4096-byte rule. The walk is inherited code: this is a registered change of it (amendment A8 of step 1), its
   default byte-identical.
4. **Not in 0.2.0** (the next pass): P4 (the 2^28 image-pixel cap of the inherited image path), P7 (a missing frame time with
   frames not summed). Hard refusals that are not policies stay as they are.

## 2. The flag

A non-default path that changes what is returned adds one metadata entry under the reserved prefix `FormatoKit.policy.`
(`FormatoMetadata.policyKeyPrefix`) whose provenance rule begins "FormatoKit policy, not RosettaSciIO's": `.units` (the unit
as written), `.grid` (the grid used and the other one), `.vendor_branch` (the branch read as generic). It appears only when the
non-default branch fired: the default output, and any file that does not reach the branch, carry no new key.

## 3. Gates

- **Default path unchanged:** no pin or fixture changes; `tools/test.sh` green with the same counts (234 + 9 step-4 signals and
  deviations, the 121 inherited names, the golden's 175 lines, every pins test); the inherited files' diff is the registered
  amendment only.
- **Tier 1, P1 and P2, against RosettaSciIO where it reads:** `.firstImage` on the planted grid file equals `step-4-pins.json`'s
  RosettaSciIO records bit for bit for O1 to O8 (O9 and O10 still refuse); `.keepAsWritten` on a planted file with "px" gives
  the literal axes (typed by hand: scale 0.5 and 0.25, offsets 1 and 2, units "px") and counts equal to its handled twin; a Pint
  raise still refuses; a handled-unit file reads identically under `.keepAsWritten` with no policy key. `.scanSizeTimesArea`:
  literal shape and sizes, bytes in the same flat order.
- **Tier 2:** each other parameter has a test that fails when its non-default path is broken (P3 at the boundary, P8 with
  blocks of 1 and 3 values equal to the default, P5 on a built TIFF with tag 37706 and on a compressed one, P6 with built tag
  streams of 5000-byte strings and a 600-element Double array).
- Sampled mutants (two or three per parameter: the option ignored, the flag omitted, the boundary moved); one refuter over the
  non-default paths.

## 4. Amendments

**A1 (2026-10-15, 15:00 CEST, results).** On `cd2938b` (gate green and stamped, 199 tests): every pin and fixture unchanged
(no pins JSON or existing fixture in the diff), the inherited names 121/121, both consumer checks green. P1 and P2 (`91d8a1b`):
`.firstImage` on `si-planted-grid.emd` equals `step-4-pins.json`'s RosettaSciIO records bit for bit for O1 to O8 (O9 and O10
still refuse); `.keepAsWritten` on the planted `policy/si-units-px.emd` (generated by `tools/policy/make_policy_fixtures.py`
from the v9 planted draw) gives the hand-typed axes; a Pint raise still refuses; 13 hand mutants red (a 14th, the outcome's
halving, is caught by the pins and the grid test, not the units outcome test, which shares the code). P5 and P6 (`cd2938b`): 11
tests, 9 hand mutants red; the inherited DM walk's diff is the string limit threaded from the new `DMReadOptions` entry points
(`keptStringBytes` an instance value, numeric arrays on a separate fixed `keptArrayBytes`), byte-identical at 4096. A
non-default string limit below 4096 moves a ushort array that is not a string into the numeric branch (invisible through
`tagTree`). **Not yet done: the one refuter over the non-default paths** (§3): the first item of the next session, before the
0.2.0 tag.

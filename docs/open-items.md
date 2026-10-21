# Open items

Listed first: functions slower than RosettaSciIO at their typical size (`docs/benchmarks.md`, 2026-10-21). Cause stated where measured.

1. **DM4 image, 2048² f32: 1.9 ms against 1.0 ms (0.54x).** Same for TIFF 4096² u16 (4.3 against 2.0) and DM4 4D 32²x128² (3.3 against 2.1). Cause
   not isolated: the shared lazy file array zero-fills a `Data` and then `pread`s into it (one extra pass over the bytes); a try with
   uninitialised storage was slower (the copy into `Data` costs more than the fill saves), so it was reverted. Next: read straight into
   a `Data`-backed allocation without either pass, then re-measure.
2. **Velox image, 2048² x5: 9.9 ms against 8.5 ms (0.86x), MRC 1024² x10 and the small DM rows** are within the run-to-run spread of the
   read path in item 1.
3. **TIFF written by tifffile with its shaped description is refused** ("the file carries tifffile's shaped description; its series
   rule is not ported"). RosettaSciIO reads those files (tifffile's own series logic); every tifffile-written file with default metadata
   is one. Found by the benchmark generator. Next: port the shaped-series rule (pin on tifffile-written files).
4. **Large rows of the benchmark are nightly** (`bench.py run --large`): decide threading for 4D loads above 100 MB there.

Not done from the task list (each is a registration-sized change with its own pins):
- Velox live/real times of `/Data/SpectrumImage` and the GMS EDS geometry (stage tilt, multi-segment list) so GMS absorption stops being refused: needs Paul's file for the GMS geometry (a GMS EDS `.dm4` with a spectrum image) and a Velox file with live/real times in the SI metadata; the single-spectrum path maps `DetectorMetadata.LiveTime/RealTime` where a spectrum carries them.
- Header-less MIB; `small_datacube` rank-3 reshape; DM4 lazy 4D gather speed (the 4D row above is the eager load; the whole-scan Float32 tile case is the app's) and rank-3 or more than four dimensions; EMPAD `mode="acquire"` scan block; HDF5 version attributes int64 against int32; TIFF vendor branches (Zeiss SEM, TVIPS, Olympus SIS, JEOL SightX, Hamamatsu), ImageJ "nm", FEI2 extended MRC header; unbounded allocation from file sizes in Velox (`markersPerFrame`, frame transformations, detector times).
- Then-list: HSPY/ZSPY, compressed TIFF, NCEM/Berkeley EMD, SER/EMI, Bruker BCF, other writers.
- `Sample.elements` (element selection) is not mapped for Velox single spectra; the four metadata groups are not parsed on that path.

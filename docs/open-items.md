# Open items

Listed first: functions slower than RosettaSciIO at their typical size (`docs/benchmarks.md`, 2026-10-21). Cause stated where measured.

1. **DM4 image, 2048² f32: 1.9 ms against 1.0 ms (0.54x).** Same for TIFF 4096² u16 (4.3 against 2.0) and DM4 4D 32²x128² (3.3 against 2.1). Cause
   not isolated: the shared lazy file array zero-fills a `Data` and then `pread`s into it (one extra pass over the bytes); a try with
   uninitialised storage was slower (the copy into `Data` costs more than the fill saves), so it was reverted. Next: read straight into
   a `Data`-backed allocation without either pass, then re-measure.
2. **Velox image, 2048² x5: 9.9 ms against 8.5 ms (0.86x), MRC 1024² x10 and the small DM rows** are within the run-to-run spread of the
   read path in item 1.
3. **Large rows of the benchmark are nightly** (`bench.py run --large`): decide threading for 4D loads above 100 MB there.

Not done from the task list (each is a change that needs its own pins):
- The GMS EDS geometry (stage tilt, multi-segment list) so GMS absorption stops being refused: needs a real file (a GMS EDS `.dm4` with a spectrum image). Velox live and real times of `/Data/SpectrumImage` are read since 0.11.0 (`VeloxEMDReader.spectrumImageMetadata()`, the EDS signal's metadata); they are unvalidated against a second file, and an SI group with several streams or a disabled segment is covered only by planted files.
- TIFF series still refused by name: SubIFD series, OME, generic pyramids; a shaped description in a second ImageDescription tag (`description1`).
- DM4 lazy 4D gather speed (the 4D row above is the eager load; the whole-scan Float32 tile case is the app's; it needs a gather row in the nightly benchmark before a cause can be named); TIFF vendor branches (the Zeiss SEM, TVIPS and JEOL SightX metadata mappings, their axes being read under `readWithVendorAxes`; Olympus SIS and Hamamatsu entirely), ImageJ "nm", FEI2 extended MRC header; unbounded allocation from file sizes in Velox (`markersPerFrame`, frame transformations, detector times).
- Then-list: HSPY/ZSPY, compressed TIFF, NCEM/Berkeley EMD, SER/EMI, Bruker BCF, other writers.
- `_parse_image_display` is not run on the single-spectrum path of a SpectrumStream file. (`Sample.elements` is mapped for single spectra since #10 and for spectrum images since #45.)

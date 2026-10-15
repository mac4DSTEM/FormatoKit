# Scope

FormatoMSA is empty until its format is registered. This article says what it will read.

## What it will read

The EMSA/MAS spectral data files, `.msa` and `.ems`, for EDS and EELS spectra. They are read and written as RosettaSciIO's `msa` plugin does: the keyword header, the XY or Y data, and the units. The keywords map into the metadata of ``FormatoCore``, each with its provenance.

## Status

The module has no public types yet. Its format is registered before any code is written, and its public types are added then. The checks will be against RosettaSciIO's MSA test files.

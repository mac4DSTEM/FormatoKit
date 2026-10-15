# Scope

FormatoMRC is empty until its format is registered. This article says what it will read.

## What it will read

MRC and MRC2014 volumes and stacks, as RosettaSciIO's `mrc` plugin reads them: the header's cell, mode and extended header, FEI's extended header among them. The data is memory-mapped and read lazily. Writing comes after reading.

## Status

The module has no public types yet. Its format is registered before any code is written, and its public types are added then. The checks will be against RosettaSciIO's MRC test files.

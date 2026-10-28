# Scope

What FormatoMRC reads, and what it is checked against.

## What it reads

MRC and MRC2014 images and stacks, as RosettaSciIO 049e7d70's `mrc` plugin (`file_reader`) reads them: the standard header
read little-endian whatever the machine stamp says, the data after the extended header, modes 0 (uint8, as RosettaSciIO
reads it), 1, 2 and 6. Scales are the cell length over the sampling, in nanometres; a Thermo Fisher (FEI) extended header
gives the pixel size instead. Reads are lazy and memory-mapped.

## Not read

DE movie files, virtual or external images, and modes 4 (complex64) and 12 (float16), which are refused by name. Writing is
not ported.

## Checks

Data bytes, type, shape and axes are pinned exactly against RosettaSciIO's reading of files written byte by byte for the
tests (`tools/acq-metadata/generate.py`).
``MRCAppImage`` is pinned against the consuming app's reader and against mrcfile's `voxel_size`. `docs/parity.md` in the
repository lists each function and its state.

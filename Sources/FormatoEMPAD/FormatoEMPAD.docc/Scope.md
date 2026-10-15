# Scope

FormatoEMPAD is empty until its format is registered. This article says what it will read.

## What it will read

The EMPAD detector's 4D-STEM raw files, with their XML description, as RosettaSciIO's `empad` plugin reads them. The frames are 128 by 130 with the two metadata rows dropped, and the scan shape comes from the XML. The data is read lazily and memory-mapped.

Later, the 4D HDF5 readers that the 4D-STEM tools use today will move into this module.

## Status

The module has no public types yet. Its format is registered before any code is written, and its public types are added then. The checks will be against RosettaSciIO and py4DSTEM.

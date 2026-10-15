# ``FormatoEMD``

Reads Thermo Fisher Velox EMD files: their images, and their spectrum images built from the EDS and EELS spectrum streams.

## Overview

A Velox EMD file is an HDF5 file. ``VeloxImageSignals`` reads its image groups as lazy signals, and ``VeloxSpectrumImageSignals`` reads its spectrum images as eager signals, following RosettaSciIO's `emd` reader.

The article "Velox images and spectrum images" shows how to read each kind.

## Topics

### Images

- ``VeloxImageSignals``
- ``VeloxImageInfo``
- ``VeloxImageArray``
- ``VeloxImageElementType``

### Spectrum images

- ``VeloxSpectrumImageSignals``
- ``VeloxSpectrumImageOptions``
- ``VeloxSpectrumImage``
- ``VeloxScanImage``
- ``VeloxEventStore``
- ``VeloxFrameSelection``
- ``VeloxStreamGeometry``
- ``VeloxStreamInfo``

### The file and its metadata

- ``VeloxEMDReader``
- ``VeloxMetadata``
- ``VeloxDetectorInfo``
- ``VeloxEnergyAxis``
- ``VeloxScanTransformation``

### Errors

- ``VeloxEMDError``

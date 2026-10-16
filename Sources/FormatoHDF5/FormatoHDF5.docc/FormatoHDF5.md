# ``FormatoHDF5``

The HDF5 library that FormatoKit's readers use: a copy of libhdf5 shipped inside the package, found without any setup, and the lock that every call into it runs under.

## Overview

The readers that need HDF5, such as the Velox reader in ``FormatoEMD``, open the library at run time. ``FormatoHDF5Library`` locates the copy that ships with the package, and ``HDF5Serial`` serialises the calls.

The article "The bundled HDF5 library" explains where the library is found and how to override it.

``HDF5Datacube`` opens an explicitly selected rank-four numeric dataset. It exposes stored-order hyperslabs,
calibration axes and scalar metadata through FormatoCore, with lazy fitted and measured origin maps. It supports
py4DSTEM EMD 1.0 calibration, legacy scalar attributes, and uniform EMD dimension vectors. Dataset discovery and
app-specific sidecar recognition belong to the consumer. Keep the source file unchanged while a reader exists.

``BraggVectorsEMD`` writes and reads py4DSTEM `BraggVectors` in EMD 1.0: the raw peak grid of every scan position, the scan
and detector shapes and the calibration scalars. Writes are atomic (a temporary file beside the destination, then rename)
and refuse to replace the source file; ``BraggAxisConvention`` names the reference and the mac4DSTEM axis conventions.

## Topics

### Datacubes

- ``HDF5Datacube``
- ``HDF5DatacubeError``
- ``HDF5OriginComponent``


### Bragg vectors

- ``BraggVectorsEMD``
- ``BraggPeak``
- ``BraggGridShape``
- ``BraggCalibration``
- ``BraggAxisConvention``
- ``BraggAttributeTarget``
- ``BraggVectorsEMDError``

### The shipped library

- ``FormatoHDF5Library``

### Calls into libhdf5

- ``HDF5Serial``

### Types

- ``hid_t``
- ``herr_t``
- ``hsize_t``

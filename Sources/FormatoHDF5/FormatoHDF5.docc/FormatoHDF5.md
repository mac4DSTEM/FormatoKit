# ``FormatoHDF5``

The HDF5 library that FormatoKit's readers use: a copy of libhdf5 shipped inside the package, found without any setup, and the lock that every call into it runs under.

## Overview

The readers that need HDF5, such as the Velox reader in ``FormatoEMD``, open the library at run time. ``FormatoHDF5Library`` locates the copy that ships with the package, and ``HDF5Serial`` serialises the calls.

The article "The bundled HDF5 library" explains where the library is found and how to override it.

``HDF5Datacube`` opens an explicitly selected rank-four numeric dataset. It exposes stored-order hyperslabs,
calibration axes and scalar metadata through FormatoCore, with lazy fitted and measured origin maps. It supports
py4DSTEM EMD 1.0 calibration, legacy scalar attributes, and uniform EMD dimension vectors. Dataset discovery and
app-specific sidecar recognition belong to the consumer. Keep the source file unchanged while a reader exists.

## Topics

### Datacubes

- ``HDF5Datacube``
- ``HDF5DatacubeError``
- ``HDF5OriginComponent``


### The shipped library

- ``FormatoHDF5Library``

### Calls into libhdf5

- ``HDF5Serial``

### Types

- ``hid_t``
- ``herr_t``
- ``hsize_t``

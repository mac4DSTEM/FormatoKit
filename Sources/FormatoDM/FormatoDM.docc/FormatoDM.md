# ``FormatoDM``

Reads Gatan DigitalMicrograph files (DM3 and DM4): every image object as a signal in the common data model, and the header and calibrations as the file states them.

## Overview

The module reads the tag tree of a DM3 or DM4 file and returns each image object as a signal of ``FormatoCore``. Reading the file lists its objects without loading their data, and each signal reads its data from the file when asked.

The article "Reading a DigitalMicrograph file" shows how to list a file and read its signals.

## Topics

### Reading files

- ``DMFile``
- ``DM4ImageObject``
- ``DM4ImageRole``
- ``DM4Axis``

### Lower-level access

- ``DM4Experiment``
- ``DM4Image``
- ``DM4EDSSpectrumImage``
- ``DM4EELSSpectrumImage``
- ``DM4EDSDetectorTags``

### Errors

- ``DM4Error``

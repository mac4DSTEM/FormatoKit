# ``FormatoTIFF``

Reads TIFF files as signals, the way RosettaSciIO's TIFF reader returns them with its defaults. The tag walker is public, so any private tag can be read as the file stores it.

## Overview

The module has two layers. ``TIFFFile`` reads the container: the header, every directory and every tag. ``TIFFSignals`` builds signals on top of it, one per series of pages that forms an array.

The article "Reading TIFF files" covers both layers.

## Topics

### Signals

- ``TIFFSignals``
- ``TIFFSeries``
- ``TIFFPageLayout``

### The container

- ``TIFFFile``
- ``TIFFDirectory``
- ``TIFFTag``
- ``TIFFTagValue``
- ``TIFFRational``

### Errors

- ``TIFFError``

# ``FormatoCore``

The data model that every FormatoKit reader returns: arrays as the file stores them, axes, metadata with provenance, and signals that load lazily or eagerly.

## Overview

FormatoCore names no file format. The readers in the other modules turn their files into the same types, so a caller handles a DigitalMicrograph image and a Velox image in the same way. The module also holds the unit conversions the readers share and the cancellation contract of long reads.

The article "The data model" describes the types and how they fit together.

## Topics

### Arrays

- ``FormatoArray``
- ``FormatoDataType``
- ``FormatoArrayError``

### Axes and units

- ``FormatoAxis``
- ``FormatoUnits``

### Metadata

- ``FormatoMetadata``
- ``FormatoMetadataEntry``
- ``FormatoProvenance``
- ``FormatoValue``

### Signals

- ``FormatoSignal``
- ``FormatoLazySignal``
- ``FormatoLazyArray``
- ``FormatoInMemoryArray``
- ``FormatoFileArray``

### Errors and cancellation

- ``FormatoReadError``
- ``FormatoCancellation``
- ``FormatoCancelled``

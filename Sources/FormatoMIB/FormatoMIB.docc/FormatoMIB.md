# ``FormatoMIB``

Reads Quantum Detectors Merlin `.mib` files as lazy, memory-mapped FormatoCore signals.

## Overview

``MIBReader`` opens a MIB file and its optional `.hdr` companion and reads the frame headers but no detector payload; the
signal reads pixels on demand. Processed U08 (1- and 6-bit), U16 (12-bit) and U32 (24-bit) frames are read; packed R64 is
refused, as in both pinned readers.

```swift
import FormatoMIB

let reader = try MIBReader(path: "scan.mib")
let signal = reader.signal
print(reader.pixelCode, signal.array.shape)
```

``MIBConvention`` picks the reference behaviour. ``MIBConvention/rosettaSciIO`` (the default) follows RosettaSciIO 049e7d70:
the scan shape from the trigger and timestamps, squeezed axes, the penultimate axis flipped, the stored integer type.
``MIBConvention/appScanXY`` follows the original application's reader: the ScanX / ScanY companion, Float32 values, not
flipped. Keep the file unchanged while the reader or its signal exists.

## Topics

### Reading

- ``MIBReader``
- ``MIBConvention``
- ``MIBError``

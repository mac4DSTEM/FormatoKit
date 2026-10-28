# ``FormatoMRC``

Reads MRC and MRC2014 images and stacks as RosettaSciIO's `mrc` plugin reads them.

## Overview

``MRCReader`` opens a file lazily (the header and nothing else) and returns a FormatoCore signal: shape (NZ, NY, NX) with
every size-1 axis squeezed away, axes z / y / x in nanometres, the data in its stored type and byte order. Modes 0, 1, 2
and 6 are read; modes 4 (complex64) and 12 (float16) are refused by name with ``MRCError``.

```swift
import FormatoMRC

let reader = try MRCReader(path: "image.mrc")
let signal = try reader.signal.load()
print(signal.data.shape, signal.axes.map(\.units))
```

``MRCAppImage`` is the named option beside it: one MRC2014 image read as Float32 pixels with an Angstrom calibration, the
way the first consuming app reads it. `AcquisitionMetadata.mrc(path:convention:)` gives the acquisition facts of RosettaSciIO's
128-byte FEI sections or of the FEI1/FEI2 extended-header record. The article <doc:Scope> says what is pinned.

## Topics

### Reading

- ``MRCReader``
- ``MRCAppImage``
- ``MRCError``

### Scope

- <doc:Scope>

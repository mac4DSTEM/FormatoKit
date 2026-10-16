# ``FormatoEMPAD``

Reads EMPAD XML headers and memory-mapped raw frames as FormatoCore signals.

## Overview

```swift
import FormatoEMPAD

let reader = try EMPADReader(path: "scan.xml")
let signal = reader.signal
let pixels = try signal.array.read(start: [0, 0, 0, 0], count: [1, 1, 128, 128])
```

The example assumes both scan dimensions exceed one. Singleton axes are squeezed, as in RosettaSciIO.
Keep the raw file unchanged while its reader or signal exists. Calibrations, supported headers and parity limits
are described in <doc:Scope>.

## Topics

- ``EMPADReader``
- ``EMPADError``
- <doc:Scope>

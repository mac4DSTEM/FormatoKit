# ``Formato``

One entry point for every format FormatoKit reads: find out what a file is, then load its signals.

## Overview

``FormatoLoader/sniff(path:)`` names a file's format from its extension, confirmed by its first bytes (the TIFF and HDF5
signatures, DM's version word, Velox's `Version` dataset); a file whose extension and bytes disagree is
``FormatoFileKind/unknown``. ``FormatoLoader/load(path:)`` returns the signals of a DM, Velox, TIFF, MRC or MSA file the way
that format's own module returns them, one result per object, so one unreadable object does not hide the others.

```swift
import Formato

for result in try FormatoLoader.load(path: "image.dm4") {
    switch result {
    case .success(let lazy): print(lazy.title, lazy.array.shape)
    case .failure(let error): print("refused:", error)
    }
}
```

Formats whose data are 4D datacubes rather than signals (EMPAD, Merlin MIB, py4DSTEM HDF5) are named, not loaded:
``FormatoLoadError/useDedicatedReader(_:_:)`` points to the reader with its own options (`EMPADReader`, `MIBReader`,
`HDF5Datacube`).

## Topics

### Loading

- ``FormatoLoader``
- ``FormatoFileKind``
- ``FormatoLoadError``

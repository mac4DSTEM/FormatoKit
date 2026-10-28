# ``FormatoPeek``

A thumbnail and the header facts of a file, without reading the file: for Quick Look and Finder-style previews.

## Overview

``Peek/thumbnailFrame(url:maxPixels:)`` returns one decimated frame of a DM, Velox, TIFF, MRC, MSA or py4DSTEM HDF5 file.
Never more than one frame is read: a stack or a 4D cube is entered at its centre, an image is read at most one row at a time
(every `stride`-th row), and columns are decimated in memory. The pixels are the file's own, point sampled, never averaged.
``Peek/summary(url:)`` returns the facts a preview card shows: format, size, scan shape, pixel size, high tension,
magnification, camera length, instrument, detector and acquisition time, as the format's reader gives them.

```swift
import FormatoPeek

let frame = try Peek.thumbnailFrame(url: url, maxPixels: 256)
let card = try Peek.summary(url: url)
print(frame.width, frame.height, frame.kind, card.format, card.highTensionKV ?? 0)
```

``Peek/Kind`` tells a consumer how to stretch the frame: images by percentile, diffraction patterns in log scale. EMPAD and
Merlin MIB files are refused by name with ``Peek/PeekError``.

## Topics

### Previews

- ``Peek``

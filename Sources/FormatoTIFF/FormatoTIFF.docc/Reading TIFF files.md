# Reading TIFF files

A TIFF file holds one or more pages, and each page can carry tags that describe the instrument, the acquisition or the software that wrote it. This module reads the pages as arrays and the tags as values.

## The container

``TIFFFile`` reads the header, classic TIFF or BigTIFF, in either byte order. It walks every directory of the main chain and keeps every tag with its code, type, count and value as stored. ``TIFFDirectory`` finds a tag by its code, and ``TIFFTag`` gives the value decoded by its TIFF type, as a ``TIFFTagValue``.

Text tags decode as UTF-8, or as cp1252 when that fails, with the trailing NUL bytes dropped and the surrounding whitespace removed. Private tags, such as Thermo Fisher's Velox XML (tag 34683) or Gatan's tag 65027, are kept as the file stores them.

```swift
import FormatoTIFF

let file = try TIFFFile(path: path)
for directory in file.directories {
    if let description = directory[270]?.text {      // ImageDescription
        print(description)
    }
}
```

## Signals

``TIFFSignals`` reads the series of a file. A series is the group of pages that forms one array, with the axis letters the file's software names it by. Each ``TIFFSeries`` gives its `axes`, its `shape` and its `dataType`. ``TIFFSignals/signal(series:)`` returns a lazy signal of a series, and its data is read from the file by page and strip as asked.

```swift
import FormatoCore
import FormatoTIFF

let tiff = try TIFFSignals(path: path)
for (index, series) in tiff.series.enumerated() {
    print(index, series.axes, series.shape, series.dataType)
}
let signal = try tiff.signal(series: 0)     // a FormatoLazySignal
let whole = try signal.load()               // the eager FormatoSignal of the series
```

The data is kept as stored. A colour page is one element per pixel, so an RGB page reads as `rgb8` or `rgb16`, and an RGBA page as `rgba8` or `rgba16`.

## What the module refuses

The reader reads uncompressed pages with strips and contiguous samples. A compressed page, or a tiled one, is refused with ``TIFFError/unsupportedLayout(_:)``, and so is a file from a vendor format that the module does not read yet. A multi-page file whose pages do not make one series this reader takes (an OME-TIFF, a pyramid of reduced-resolution pages, pages of several shapes or types, an ImageJ or shaped stack it cannot place) is refused with ``TIFFError/unsupportedSeries(file:series:)``, which carries the file name and the kind of series. Each refusal names the reason, so no page is decoded into a wrong array.

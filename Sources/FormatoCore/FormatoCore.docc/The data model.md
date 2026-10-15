# The data model

A reader returns a signal: an array of values, one axis per dimension, a title, a signal type and metadata. FormatoCore defines these types once, so every format reads into the same shape.

## The array

``FormatoArray`` holds the values as the file stores them. It has three parts: a stored element type (``FormatoDataType``, for example `float32`, `uint16` or `rgba8`), a shape in C order (slowest dimension first, the shape RosettaSciIO reports), and the values as little-endian bytes in that order.

A reader does not convert the values. A file that stores 16-bit integers returns `uint16`. A stored type that the library does not read, such as complex or boolean, is refused by name rather than converted.

```swift
import Foundation
import FormatoCore

let bytes = Data(count: 2 * 3 * 4)   // 2 rows, 3 columns, 4 bytes per float32
let array = try FormatoArray(dataType: .float32, shape: [2, 3], bytes: bytes)
let values = array.doubles()         // the same values as Double, for display or checks
```

Two arrays are equal when their type, shape and bytes are equal. That equality is the basis of the bit-for-bit checks against RosettaSciIO.

## Axes

``FormatoAxis`` describes one dimension. The value at index `i` is `offset + i * scale`, see ``FormatoAxis/value(at:)``. Each axis has an optional name, a unit string written as the reference writes it (`"nm"`, `"1/nm"`, `"eV"`), and a flag that says whether it is a navigation axis (a position) or the measured signal. A signal has one axis per dimension of its array, in array order.

## Metadata with provenance

``FormatoMetadata`` is an ordered list of ``FormatoMetadataEntry`` values. Each entry has:

- a key, under RosettaSciIO's metadata name;
- a value, a number or a text (``FormatoValue``);
- an optional unit;
- a ``FormatoProvenance`` that names the file, the place in the file the value came from, and the rule that turned it into the entry.

An entry always has a source. A value the file does not state is absent from the metadata; a reader never fills in a default.

## Lazy and eager signals

There are two kinds of signal. ``FormatoSignal`` holds its whole array. ``FormatoLazySignal`` holds a ``FormatoLazyArray`` that reads a hyperslab (a start and a count per dimension) when asked. Large files are read by slab, and the eager form is made only when the whole array is needed.

``FormatoLazySignal/load()`` reads the whole array once and returns the eager signal. The two forms are equal: every slab a lazy array returns is the same slice of the eager array, bit for bit.

```swift
import FormatoCore

let axes = [
    FormatoAxis(name: "y", size: 2, scale: 0.5, offset: 0, units: "nm", navigate: true),
    FormatoAxis(name: "x", size: 3, scale: 0.5, offset: 0, units: "nm", navigate: true),
]
let lazy = FormatoLazySignal(title: "Image", signalType: "", axes: axes,
                             metadata: FormatoMetadata(), array: FormatoInMemoryArray(array))
let slab = try lazy.array.read(start: [0, 1], count: [2, 2])   // the columns 1 and 2
let whole = try lazy.load()                                     // a FormatoSignal of the whole array
```

## Errors and cancellation

A reader that cannot read a file throws ``FormatoReadError``. Its cases name what it refused: a file that cannot be opened, a read past the end of the data, a stored type the library does not read, or a layout or calibration the reader does not guess at.

Long reads take a `cancelled` closure. It defaults to ``FormatoCancellation/task``, which follows the task's cancellation. When the closure returns true, the read throws ``FormatoCancelled`` and keeps nothing partial.

## Units

``FormatoUnits/convertUnits(_:from:to:)`` converts a value between the length and time units the readers meet, with the same factors RosettaSciIO uses. It returns nil for a pair it does not convert, so a caller decides what to do rather than receiving a guess.

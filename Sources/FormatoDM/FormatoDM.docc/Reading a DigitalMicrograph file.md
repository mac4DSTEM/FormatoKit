# Reading a DigitalMicrograph file

Gatan DigitalMicrograph saves its images as DM3 and DM4 files. ``DMFile`` lists such a file and returns its image objects as signals, with the calibrations and the metadata of each object. The reader follows RosettaSciIO's `digitalmicrograph` reader, which is the reference for every value.

## Listing the objects

``DMFile/init(path:)`` reads the header of the file. It walks the tag tree and skips every data block, so listing a large file is quick.

``DMFile/objects`` holds the image objects in the file's image list. Each ``DM4ImageObject`` has:

- `index`, its one-based number in the file;
- `name` and `dimensions`, as the file states them;
- `role`, a ``DM4ImageRole`` that says what the object holds (a survey image, a scan signal, an EELS or EDS spectrum image, a diffraction image, a thumbnail, or unknown).

Thumbnails that the file names as thumbnails are left out, the same way RosettaSciIO leaves them out.

## Reading signals

``DMFile/signal(index:)`` takes the object's `index`, not its position in the list. It returns a signal of the object's data, read from the file by slab when a caller asks for one. Its shape is the object's dimensions in reverse order, which puts the slowest dimension first as in C order. Its axes give the scale, the offset (the negative of the origin times the scale) and the units of each dimension.

```swift
import FormatoCore
import FormatoDM

let file = try DMFile(path: path)
for object in file.objects {
    print(object.index, object.name, object.dimensions, object.role)
}

let first = file.objects[0]
let signal = try file.signal(index: first.index)     // lazy: the data stays in the file
let metadata = file.metadata(of: first)              // each value with the tag path it came from
let whole = try signal.load()                        // the eager signal of the whole object
```

## Types the module does not read

An object stored as a complex, packed complex, RGB or boolean type is refused. ``DMFile/signal(index:)`` throws `FormatoReadError.unsupportedDataType` and names the object, so the caller knows what was not read.

## Lower-level access

``DM4Experiment`` exposes the parser the signals are built on. Its functions list the objects of a file and read an image, a spectrum image or the tag tree, from a path or from data in memory. Use it when the signal form does not carry what you need; for most files, ``DMFile`` is enough.

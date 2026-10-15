# Velox images and spectrum images

Thermo Fisher Velox stores an EMD file in HDF5. Its images are the groups under `Data/Image`. Its spectrum data is either the spectrum streams under `Data/SpectrumStream` or a spectrum image under `Data/SpectrumImage`. Two entry points read the two kinds.

## Images

``VeloxImageSignals`` lists the image groups of a file in ``VeloxImageSignals/images``. Each ``VeloxImageInfo`` gives the image's `id`, its `detectorName`, its `width` and `height`, and its `frameCount`. ``VeloxImageSignals/signal(_:)`` returns the image as a lazy signal, with the data shaped `(frames, y, x)` for a stack or `(y, x)` for a single frame. The data is read from the file by slab, and the stored element type is kept.

A file without a `Data/SpectrumImage` group reads every frame of a stack. A spectrum-image file reads the first frame only, which is RosettaSciIO's default. ``VeloxImageSignals/readsWholeStacks`` tells which rule applies to a file. ``VeloxImageSignals/title(of:)`` returns the title RosettaSciIO gives the image.

```swift
import FormatoCore
import FormatoEMD

let images = try VeloxImageSignals(path: path)
for info in images.images {
    let title = images.title(of: info) ?? info.id
    let signal = try images.signal(info)            // lazy: frames are read when a slab asks for them
    print(title, signal.array.shape, signal.array.dataType)
}
```

An image stored in a compound type, such as Velox's FFT and DPC images, is refused with `FormatoReadError.unsupportedDataType`.

## Spectrum images

``VeloxSpectrumImageSignals`` reads every spectrum image of a file at once and returns eager signals in ``VeloxSpectrumImageSignals/signals``. The EELS spectrum images come first, then the EDS signal, or one signal per stream when the EDS streams are not summed.

``VeloxSpectrumImageOptions`` carries RosettaSciIO's six arguments, with the same defaults:

- `firstFrame` and `lastFrame` choose the frames that are counted.
- `sumFrames` gives one spectrum image summed over the frames (true), or a frame axis first (false).
- `sumEDSDetectors` adds every EDS stream into the first (true), or keeps one signal per stream (false).
- `rebinEnergy` sums the energy channels in groups; it must divide the number of bins.
- `dataType` sets the type of the counts; nil uses the encoding of the first stream.

Use ``VeloxEMDReader/isVeloxEMD(path:)`` to ask whether a file holds a spectrum image. ``VeloxEMDReader/isVeloxFile(path:)`` answers the wider question of whether the file holds anything the images path can read.

```swift
import FormatoCore
import FormatoEMD

if VeloxEMDReader.isVeloxEMD(path: path) {
    let options = VeloxSpectrumImageOptions(sumFrames: true, sumEDSDetectors: true, rebinEnergy: 2)
    let spectra = try VeloxSpectrumImageSignals(path: path, options: options)
    for signal in spectra.signals {
        print(signal.title, signal.signalType, signal.data.shape)
    }
}
```

## Errors and cancellation

A file that cannot be opened, or is not a Velox file, throws ``VeloxEMDError``. A file that RosettaSciIO refuses throws `FormatoReadError.unsupported`, with the reason. Both readers take a `cancelled` closure; a read that is cancelled throws `FormatoCancelled` and returns nothing partial.

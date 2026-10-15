# The bundled HDF5 library

FormatoKit ships HDF5 2.1.1 with its compression libraries, libsz and libaec. The three arm64 dylibs are a resource of the module, so a package that depends on FormatoKit reads HDF5 files with nothing installed and no variable set.

The readers open the library at run time. They never link it, so the copy they use can be replaced without rebuilding them.

## Where the library is found

The Velox reader looks for libhdf5 in this order, and uses the first copy it can load:

1. The path in the `FORMATO_HDF5_PATH` environment variable, when it is set.
2. The host's own `libhdf5.dylib` in its private frameworks folder.
3. A `libhdf5.dylib` in the `Frameworks` folder beside the executable.
4. The copy that ships with FormatoKit, given by ``FormatoHDF5Library/bundledLibraryPath``.
5. The loader's own search path.

Set `FORMATO_HDF5_PATH` in the process environment before the process starts reading files. A host that embeds its own copy and removes the resource bundle gets nil from ``FormatoHDF5Library/bundledLibraryPath``, not a crash, and the search goes on to the next candidate.

```swift
import FormatoHDF5

if let path = FormatoHDF5Library.bundledLibraryPath {
    print("Bundled libhdf5 at \(path)")
}
```

## Calls under one lock

Every call into libhdf5 runs under the lock of ``HDF5Serial``. The lock lets one thread at a time make a call, so every call is made inside ``HDF5Serial/run(_:)``. The lock is recursive: a call that runs inside another on the same thread does not wait for itself.

```swift
import FormatoHDF5

HDF5Serial.run {
    // Every libhdf5 call goes here, for example H5Fopen and H5Dread.
}
```

## Quitting while a read is in progress

A process that calls `exit` runs the library's own teardown, and that teardown must not race a call still in progress. A loader calls ``HDF5Serial/installExitBarrier()`` right after its first successful `H5open`, and never before. The barrier makes the exit wait for the call in flight, for at most ``HDF5Serial/exitBarrierBound`` (10 seconds). After that the process exits without the teardown, so a thread stuck inside the library cannot hold the quit forever.

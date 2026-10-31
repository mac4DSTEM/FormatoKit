#!/usr/bin/env python3
"""Writes the tiny synthetic Velox EMDs that FormatoEMDTests/VeloxEMDReaderTests.swift embeds as base64
(so the unit tests need no References data). From mac4DSTEM (tools/velox-parity/make-tiny-fixture.py, last present at
7a0f727f^), where the reader and these files were written before the reader moved; only the pinned checkout's folder name
differs. h5py stamps dataset times here, so a rerun is not byte-identical: the embedded files are the record, and
--rsciio-truth checks the numbers the tests assert. Prints the raw-deflate base64 (what Foundation's `.zlib`
decompression expects):

    make-tiny-fixture.py <out.emd>               the main file
    make-tiny-fixture.py --bare <out.emd>        no FrameLocationTable, no SpectrumImage group, one stream
                                                 stopped mid-frame (the ceil-of-markers path)
    make-tiny-fixture.py --image-only <out.emd>  a Velox image file with no stream
    make-tiny-fixture.py --no-scan-area <out.emd>   the main file without ScanArea (grid from the last image)
    make-tiny-fixture.py --wrong-height <out.emd>   the main file with ScanSize height 4 (a grid the stream cannot fill)
    make-tiny-fixture.py --bare-huge-grid <out.emd> the bare file with ScanSize height 6000 (a corrupt grid, no table to catch it)
    make-tiny-fixture.py --no-last-marker <out.emd> the main file, every stream lacking its final pixel marker (EELS_EDS-like)
    make-tiny-fixture.py --multi-version <out.emd>  a Version dataset of 3 elements (a guard test)
    make-tiny-fixture.py --image-typed <out.emd>    an image-only file: three (3 rows, 5 columns, 2 frames) stacks of
                                                 int16, uint16 and float32 (VeloxEMDReaderTests' typed file)
    make-tiny-fixture.py --image-wide <out.emd>     an image-only file with one (3, 5, 1) stack of each other stored type:
                                                 uint8, int8, uint32, int32, uint64, int64, float64
    make-tiny-fixture.py --image-refused <out.emd>  an image-only file with two images the reader must refuse to read: Velox's
                                                 compound FFT type, and a 17000 x 17000 uint8 (more pixels than it accepts)
    make-tiny-fixture.py --rsciio-truth <in.emd>    prints what rosettasciio at the pin reads from a file: per signal the
                                                 title, dtype and the frames (frames, y, x), per axis scale, offset, units

Main file: a NON-SQUARE 3-row x 2-column spectrum image (ScanSize 4 x 6, ScanArea .25-.75 x 0-.5), 8 channels,
2 frames, two detector streams (SuperXG21, SuperXG22) with a FrameLocationTable, a (3, 2, 2) HAADF stack, and
Super-X segments with DIFFERENT elevations and a different dispersion (G22: 20 eV/channel, the rest 10), so a
swapped axis, a swapped segment or a lost calibration cannot pass. ScanTransformation is written the way Velox
writes it: FLAT dotted keys under CustomProperties.

The typed image file (--image-typed) has no stream and no SpectrumImage group: three image stacks, one frame per chunk as
Velox chunks them, each with its own detector (HAADF, DF4, BF), pixel size (anisotropic, in three magnitudes so rsciio's
unit compaction lands on nm, um and pm), and Offset (x != y, both nonzero). The numbers VeloxEMDReaderTests asserts are
what rsciio reads from this file (and from --image-wide), regenerated with:

    make-tiny-fixture.py --image-typed /tmp/typed.emd > /dev/null && make-tiny-fixture.py --rsciio-truth /tmp/typed.emd

--rsciio-truth puts References/rosettasciio-049e7d70 (the pinned checkout) first on sys.path, prints the rsciio it imported, and
refuses any other. Never run it on --image-refused (rsciio would load the 17000 x 17000 image). It needs rsciio's own dependencies (pint, dask, python-dateutil, pyyaml, python-box); sparse only for streams."""
import base64, json, os, sys, zlib
import h5py
import numpy as np

M = 65535
ROWS = 4096
NY, NX = 3, 2
# per frame, per pixel: the channels detected. Pixels are row-major (p = y * 2 + x).
A = [[[1, 1], [], [2], [], [], [7]], [[1], [3], [], [], [], [0]]]
B = [[[], [3], [], [4], [], [7]], [[], [], [5], [], [], []]]


def stream(frames, stop_after=None):
    out, n = [], 0
    for fr in frames:
        for px in fr:
            if stop_after is not None and n == stop_after:
                return out
            out += px + [M]
            n += 1
    return out


VARIANT = {"scan_area": True, "height": "6"}


def meta(detector, frames):
    dets = {"Detector-0": {"DetectorName": "HAADF", "DetectorType": "ScanningDetector", "Enabled": "true"}}
    for i, (az, el, disp) in enumerate(((45, 0.31415927, 10), (135, 0.5235988, 20), (225, 0.4, 10), (315, 0.6, 10))):
        dets[f"Detector-{i + 1}"] = {
            "DetectorName": f"SuperXG2{i + 1}", "DetectorType": "AnalyticalDetector", "Inserted": "true",
            "Enabled": "false" if i == 3 else "true", "ElevationAngle": repr(el),
            "AzimuthAngle": repr(float(np.radians(az))), "CollectionAngle": "0.225", "Dispersion": str(disp),
            "OffsetEnergy": "-250", "RealTime": "0.5", "LiveTime": "0.4"}
    m = {"Detectors": dets,
         "BinaryResult": {"Detector": detector, "DetectorIndex": "8", "PixelSize": {"width": "1e-9", "height": "1e-9"},
                          "PixelUnitX": "m", "Offset": {"x": "0", "y": "0"}},
         "Scan": {"ScanSize": {"width": "4", "height": VARIANT["height"]}, "DwellTime": "1e-3", "FrameTime": "0.006",
                  "ScanArea": {"left": "0.25", "top": "0", "right": "0.75", "bottom": "0.5"}, "ScanRotation": "-0.5"},
         "Optics": {"AccelerationVoltage": "200000", "ScreenCurrent": "1.5e-9"},
         "Stage": {"AlphaTilt": "-0.2945", "BetaTilt": "0.01", "HolderType": "FEI Double Tilt",
                   "Position": {"x": "1e-5", "y": "2e-5", "z": "3e-5"}},
         "Instrument": {"InstrumentModel": "Talos"}, "Acquisition": {"AcquisitionStartDatetime": {"DateTime": "1776689766"}}}
    if not VARIANT["scan_area"]:
        del m["Scan"]["ScanArea"]
    cols = []
    for f in range(frames):
        mm = json.loads(json.dumps(m))
        mm["CustomProperties"] = {f"Scan.ScanTransformation.{k}": {"type": "double", "value": str(v)} for k, v in
                                  dict(A11=1, A12=0, A13=0.001 * f, A21=0, A22=1, A23=-0.002 * f).items()}
        b = json.dumps(mm).encode()
        assert len(b) < ROWS
        cols.append(np.frombuffer(b.ljust(ROWS, b"\0"), dtype=np.uint8))
    return np.stack(cols, axis=1)


vl = h5py.string_dtype()


def emit(path):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    print(base64.b64encode(c.compress(open(path, "rb").read()) + c.flush()).decode())


def version(f):
    f.create_dataset("Version", data=[json.dumps({"version": "11", "format": "Velox"})], dtype=vl)


def image(d):
    g = d.create_group("Image/img0")
    stack = np.stack([np.arange(1, 7, dtype=np.uint16).reshape(NY, NX), 10 * np.arange(1, 7, dtype=np.uint16).reshape(NY, NX)], axis=2)
    g.create_dataset("Data", data=stack)   # (y, x, frame)
    g.create_dataset("Metadata", data=meta("HAADF", 2))


# The typed image file: (y, x) frames, 3 rows x 5 columns. Frame 1 differs from frame 0 at EVERY pixel (asserted below),
# so a read that ignores the frame index cannot pass; the values are chosen so that a wrong sign, a wrong width or a
# truncation to integers is visible: int16 holds -1, -32768, 32767; uint16 holds 65535, 40000; float32 holds exact binary
# fractions (-2.25, 0.5, 1000000.5) that no integer type keeps.
TYPED_IMAGES = [
    # (group id, detector, Detectors index, numpy dtype, [frame 0, frame 1], pixel (width, height), offset (x, y)), SI metres
    ("0c5f3e9a7b1d4c2e8a6f1b0d9e7c5a32", "HAADF", 3, np.int16,
     [[[-1, -32768, 32767, 300, 0], [17, -300, 42, -7, 1000], [-12345, 256, -256, 5, -99]],
      [[2, 32767, -32768, -300, 123], [-18, 301, -43, 8, -1000], [12346, -257, 257, -6, 100]]],
     (2.5e-9, 4e-9), (7e-9, -3e-9)),
    ("5b2178d0c4e94f3a9d17e6a2b8c05f41", "DF4", 4, np.uint16,
     [[[65535, 40000, 300, 0, 1], [32768, 32767, 65534, 256, 12], [511, 4096, 61000, 7, 40001]],
      [[2, 300, 40000, 65535, 99], [32769, 1, 255, 65533, 13], [512, 4097, 2, 8, 40002]]],
     (1.25e-6, 2e-6), (4e-7, -1.5e-6)),
    ("d94a60b3e1f2478c95a0d3c7b6e18f29", "BF", 5, np.float32,
     [[[-2.25, 0.5, 1000000.5, 3.0, -0.125], [1.5, -1000000.5, 0.0, 2.75, 123456.5], [0.25, -7.5, 65536.5, 0.0009765625, 8.0]],
      [[7.5, -0.25, 2.0, -3.5, 0.0625], [-1.5, 999999.5, -4.0, 0.125, -123456.5], [-0.5, 7.25, -65536.5, 1.0, 0.5]]],
     (3e-10, 5e-10), (-2e-10, 6e-10)),
]


# --image-wide: the stored types TYPED_IMAGES does not cover, one frame each. The values reach the ends of each type's range
# and, in the 32- and 64-bit integers and float64, beyond what Float32 keeps (16777217 = 2^24 + 1, 2^64 - 1, 0.1): the reader
# rounds those to the nearest Float32 and says so.
WIDE_IMAGES = [
    ("0-uint8", np.uint8, [[0, 255, 128, 1, 127], [254, 2, 100, 200, 50], [255, 0, 17, 34, 51]]),
    ("1-int8", np.int8, [[-128, 127, -1, 0, 1], [-127, 126, -2, 64, -64], [100, -100, 5, -5, 42]]),
    ("2-uint32", np.uint32, [[0, 4294967295, 2147483648, 16777216, 16777217], [1, 4278190080, 65535, 65536, 4294901760],
                             [123456789, 3000000000, 7, 255, 256]]),
    ("3-int32", np.int32, [[-2147483648, 2147483647, -1, 16777217, -16777217], [0, 1, -65536, 65535, 100000],
                           [-123456789, 2000000000, -2000000000, 7, -7]]),
    ("4-uint64", np.uint64, [[0, 1, 2 ** 63, 2 ** 64 - 1, 2 ** 32], [16777217, 2 ** 40, 2 ** 48, 65535, 255],
                             [123456789012, 2 ** 53 + 1, 3, 2 ** 62, 12]]),
    ("5-int64", np.int64, [[-2 ** 63, 2 ** 63 - 1, -1, 2 ** 32, -2 ** 32], [0, 1, -16777217, 16777217, 2 ** 40],
                           [-123456789012, 2 ** 53 + 1, -3, 2 ** 62, -12]]),
    ("6-float64", np.float64, [[0.5, -2.25, 1e10, 0.1, 123456789.123], [-0.1, 3.4e38, 1e-30, 1.0000000001, -7.5],
                               [2.5, 1e-3, -1e5, 16777217.0, 0.3333333333333333]]),
]


def image_meta(detector, index, size, offset, wrong_width):
    """One column of an image's Metadata. rsciio takes the pixel size and Offset from BinaryResult (X unit only), the title
    from the Detectors entry BinaryResult.DetectorIndex names, and Scan.FrameTime for a stack. Column 1 carries a different
    pixel width: only column 0 is the image's own (rsciio reads [:, 0]), so a reader of any other column cannot pass."""
    dets = {f"Detector-{i}": {"DetectorName": n, "DetectorType": "ScanningDetector", "Enabled": "true"}
            for i, n in ((3, "HAADF"), (4, "DF4"), (5, "BF"))}
    width = repr(wrong_width) if wrong_width else repr(size[0])
    m = {"Detectors": dets,
         "BinaryResult": {"Detector": detector, "DetectorIndex": str(index),
                          "PixelSize": {"width": width, "height": repr(size[1])},
                          "PixelUnitX": "m", "PixelUnitY": "m", "Offset": {"x": repr(offset[0]), "y": repr(offset[1])}},
         "Scan": {"ScanSize": {"width": "4096", "height": "4096"}, "DwellTime": "1e-6", "FrameTime": "0.5"},
         "Optics": {"AccelerationVoltage": "200000"},
         "Acquisition": {"AcquisitionStartDatetime": {"DateTime": "1776689766"}}}
    b = json.dumps(m).encode()
    assert len(b) < ROWS
    return np.frombuffer(b.ljust(ROWS, b"\0"), dtype=np.uint8)


def typed_images(d):
    for gid, detector, index, dtype, frames, size, offset in TYPED_IMAGES:
        f0, f1 = (np.array(f, dtype=dtype) for f in frames)
        assert f0.shape == (NY, 5) and bool(np.all(f0 != f1)), gid
        g = d.create_group(f"Image/{gid}")
        g.create_dataset("Data", data=np.stack([f0, f1], axis=2), chunks=(NY, 5, 1))   # (y, x, frame), a frame a chunk
        g.create_dataset("Metadata", data=np.stack([image_meta(detector, index, size, offset, None),
                                                    image_meta(detector, index, size, offset, 9e-9)], axis=1))


def wide_images(d):
    for k, (gid, dtype, rows) in enumerate(WIDE_IMAGES):
        data = np.array(rows, dtype=dtype)
        assert data.shape == (NY, 5), gid
        g = d.create_group(f"Image/{gid}")
        g.create_dataset("Data", data=data[:, :, None], chunks=(NY, 5, 1))
        g.create_dataset("Metadata", data=image_meta(("HAADF", "DF4", "BF")[k % 3], 3 + k % 3, (2.5e-9, 4e-9), (7e-9, -3e-9), None)[:, None])


def refused_images(d):
    """Velox stores an FFT (and DPC) image as real/imaginary float pairs: a compound type no float read can take. The second
    image is 17000 x 17000 = 289 M pixels, over the 2^28 the reader accepts; no chunk is written, so the file stays small.
    (Never run --rsciio-truth on this file: rsciio would try to load it.)"""
    meta = image_meta("HAADF", 3, (2.5e-9, 4e-9), (7e-9, -3e-9), None)[:, None]
    g = d.create_group("Image/9e1b4d7a2c6f4803b5a9d0e3f7c28b16")
    fft = np.dtype([("realFloatHalfEven", "<f4"), ("imagFloatHalfEven", "<f4")])
    g.create_dataset("Data", data=np.zeros((NY, 5, 1), dtype=fft), chunks=(NY, 5, 1))
    g.create_dataset("Metadata", data=meta)
    g = d.create_group("Image/f3a70c1e8d5b49266e2fb0a4c9d71e58")
    g.create_dataset("Data", shape=(17000, 17000, 1), dtype=np.uint8, chunks=(1000, 1000, 1))
    g.create_dataset("Metadata", data=meta)


def rsciio_truth(path):
    """What rosettasciio at the pin reads from `path`: the numbers VeloxEMDReaderTests asserts (frames, y, x)."""
    import logging
    pin = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "References", "rosettasciio-049e7d70"))
    sys.path.insert(0, pin)
    logging.disable(logging.CRITICAL)
    import rsciio
    from rsciio.emd import file_reader
    where = os.path.realpath(rsciio.__file__)
    print(f"rsciio {rsciio.__version__} from {where}")
    if not where.startswith(pin + os.sep):
        sys.exit(f"not the pinned checkout ({pin}): refusing to print truth")
    for i, sig in enumerate(file_reader(path)):
        data = np.asarray(sig["data"])
        print(f"signal {i}: title={sig['metadata']['General'].get('title')!r} dtype={data.dtype} shape={data.shape}")
        for k, frame in enumerate(data if data.ndim == 3 else data[None]):
            print(f"  frame {k}: {frame.tolist()}")
        for a in sig["axes"]:
            print(f"  axis {a['name']}: size={a['size']} scale={a['scale']!r} offset={a['offset']!r} units={a['units']!r}")


mode, path = (sys.argv[1], sys.argv[2]) if sys.argv[1].startswith("--") else ("--main", sys.argv[1])
if mode == "--rsciio-truth":
    rsciio_truth(path)
    sys.exit(0)
if mode == "--no-scan-area":      # the last-image grid fallback
    VARIANT["scan_area"] = False
if mode == "--bare-huge-grid":    # the bare file with ScanSize height 6000: more pixels per frame than the stream has pixel ends
    VARIANT["height"] = "6000"
    mode = "--bare"
NO_LAST_MARKER = mode == "--no-last-marker"   # every stream ends without its final pixel marker
if NO_LAST_MARKER:
    mode = "--main"
if mode == "--wrong-height":      # ScanSize height 4 instead of 6: a grid the stream cannot fill
    VARIANT["height"] = "4"
with h5py.File(path, "w") as f:
    if mode == "--multi-version":
        # A Version dataset with SEVERAL elements: any other HDF5 file may have one; reading it into one pointer overflows.
        f.create_dataset("Version", data=[json.dumps({"version": "11", "format": "Velox"})] * 3, dtype=vl)
        f.create_group("Data/SpectrumStream")
    else:
        version(f)
    d = f.create_group("Data") if mode != "--multi-version" else None
    if mode == "--multi-version":
        pass
    elif mode == "--image-only":
        d.create_group("Image/img0").create_dataset("Data", data=np.zeros((2, 2, 1), dtype=np.uint16))
    elif mode == "--image-typed":
        typed_images(d)
    elif mode == "--image-wide":
        wide_images(d)
    elif mode == "--image-refused":
        refused_images(d)
    elif mode == "--bare":
        g = d.create_group("SpectrumStream/aaaa")
        g.create_dataset("AcquisitionSettings", data=[json.dumps({"bincount": "8", "StreamEncoding": "uint16"})], dtype=vl)
        g.create_dataset("Data", data=np.array(stream(A, stop_after=8), dtype=np.uint16).reshape(-1, 1))
        g.create_dataset("Metadata", data=meta("SuperXG21", 2))
        image(d)
    else:
        for name, fr, det in (("aaaa", A, "SuperXG21"), ("bbbb", B, "SuperXG22")):
            g = d.create_group(f"SpectrumStream/{name}")
            g.create_dataset("AcquisitionSettings", data=[json.dumps({"bincount": "8", "StreamEncoding": "uint16"})], dtype=vl)
            s = stream(fr)
            if NO_LAST_MARKER:
                s = s[:-1]
            g.create_dataset("Data", data=np.array(s, dtype=np.uint16).reshape(-1, 1))
            idx = [i for i, v in enumerate(s) if v == M]
            g.create_dataset("FrameLocationTable", data=np.array([[0], [idx[NY * NX - 1] + 1]], dtype=np.uint64))
            g.create_dataset("Metadata", data=meta(det, 2))
        g = d.create_group("SpectrumImage/si00")
        g.create_dataset("SpectrumImageSettings", data=[json.dumps({"startFramePosition": "1", "endFramePosition": "2"})], dtype=vl)
        image(d)
emit(path)

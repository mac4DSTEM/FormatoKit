"""LZW TIFF fixtures and tifffile pins for FormatoTIFF's LZW decoding (Sources/FormatoTIFF/TIFFCompression.swift, FormatoKit#90).

    References/venv/bin/python -I -B tools/tiff-lzw/generate.py

tifffile (with imagecodecs' LZW encoder, the code stream libtiff writes) writes Tests/FormatoTIFFTests/Fixtures/lzw/*.tif, and
pins.json records how tifffile reads each back: shape, dtype, the SHA-256 of its little-endian bytes, and, for the files
TIFFAppImage reads (one grey page), the SHA-256 of the values as little-endian float32.

The files cover what the decoder meets: GMS-like float32 images without a predictor over several strips; uint8, uint16 in both
byte orders, int16 (negative differences wrap) and uint32 behind the horizontal predictor; float32 behind the floating-point
predictor; an RGB render behind the horizontal predictor (per-sample differences); a noise image large enough that the
code table fills and the stream clears it (ClearCode mid-strip); and a three-page uint16 stack.
"""
import hashlib
import json
import pathlib

import imagecodecs
import numpy as np
import tifffile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'Tests/FormatoTIFFTests/Fixtures/lzw'
OUT.mkdir(parents=True, exist_ok=True)


def le_bytes(a):
    return np.ascontiguousarray(a.astype(a.dtype.newbyteorder('<'), copy=False)).tobytes()


def sha(a):
    return hashlib.sha256(le_bytes(a)).hexdigest()


def images():
    y, x = np.mgrid[0:37, 0:53]
    ramp = (x * 3 + y * 7).astype(np.float64)
    disc = ((x - 26) ** 2 + (y - 18) ** 2 < 12 ** 2)
    gms = (ramp * 0.37 - 20 + 400 * disc).astype(np.float32)
    rng = np.random.default_rng(90)
    noise = rng.integers(0, 65536, (96, 128)).astype(np.uint16)
    stack = np.stack([(x * 100 + y + 5000 * k) for k in range(3)]).astype(np.uint16)
    rgb = np.stack([(x * 4) % 256, (y * 6) % 256, ((x + y) * 3) % 256], axis=-1).astype(np.uint8)
    # name, data, tifffile.imwrite options, read by TIFFAppImage too
    return [
        ('f32-gms', gms, dict(rowsperstrip=8), True),
        ('u8-pred2', (ramp % 256).astype(np.uint8), dict(predictor=2, rowsperstrip=10), True),
        ('u16-pred2', (ramp * 300 + 1000 * disc).astype(np.uint16), dict(predictor=2, rowsperstrip=6), True),
        ('u16-pred2-be', (ramp * 300 + 1000 * disc).astype(np.uint16), dict(predictor=2, rowsperstrip=6, byteorder='>'), True),
        ('i16-pred2', (ramp * 50 - 9000 * disc).astype(np.int16), dict(predictor=2), True),
        ('u32-pred2', (ramp * 70000 + 3).astype(np.uint32), dict(predictor=2, rowsperstrip=16), True),
        ('f32-pred3', gms, dict(predictor=3, rowsperstrip=8), True),
        ('f32-pred3-be', gms, dict(predictor=3, rowsperstrip=8, byteorder='>'), True),
        ('f64-pred3', gms.astype(np.float64) * 1.5, dict(predictor=3), False),
        ('rgb8-pred2', rgb, dict(predictor=2, photometric='rgb'), False),
        ('u16-noise', noise, dict(), True),
        ('u16-stack', stack, dict(predictor=2), False),
    ]


def main():
    pins = {}
    for name, data, options, app in images():
        path = OUT / f'{name}.tif'
        if name == 'u16-stack':
            # One page per image (tifffile would store a 3-plane array as one page of three planar samples).
            with tifffile.TiffWriter(path) as w:
                for plane in data:
                    w.write(plane, compression='lzw', metadata=None, photometric='minisblack', **options)
        else:
            tifffile.imwrite(path, data, compression='lzw', metadata=None, **options)
        with tifffile.TiffFile(path) as t:
            page = t.pages[0]
            assert page.compression == 5, name
            back = t.asarray()
            predictor = int(page.predictor)
            strips = len(page.dataoffsets)
        assert back.dtype == data.dtype and np.array_equal(back, data), name
        pin = {'shape': list(back.shape), 'dtype': str(back.dtype), 'sha256': sha(back), 'predictor': predictor, 'strips': strips}
        if app:
            pin['appFloat32Sha256'] = sha(back.astype(np.float32))
        pins[name] = pin
    # The noise image overflows the 4096-entry table: its stream carries ClearCode after the first one.
    with tifffile.TiffFile(OUT / 'u16-noise.tif') as t:
        page = t.pages[0]
        raw = t.filehandle
        raw.seek(page.dataoffsets[0])
        stream = raw.read(page.databytecounts[0])
    assert imagecodecs.lzw_decode(stream)[:16] == le_bytes(images()[10][1])[:16]
    assert pins['f32-gms']['strips'] > 1 and pins['f32-gms']['predictor'] == 1
    doc = {'tifffile': tifffile.__version__, 'imagecodecs': imagecodecs.__version__, 'numpy': np.__version__, 'files': pins}
    (OUT / 'pins.json').write_text(json.dumps(doc, indent=1, sort_keys=True) + '\n')
    print(f'{OUT.relative_to(ROOT)}: {len(pins)} files')


if __name__ == '__main__':
    main()

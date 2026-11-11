"""LZF fixture and h5py pins for FormatoHDF5's LZF filter (Sources/FormatoHDF5/LZFFilter.swift, FormatoKit#86).

    References/venv/bin/python -I -B tools/hdf5-lzf/generate.py

h5py writes Tests/FormatoHDF5Tests/Fixtures/lzf/lzf.h5 with its own LZF filter (HDF5 filter 32000, liblzf's compressor, the
filter AZtec uses for an .h5oina's patterns and the shipped libhdf5 lacks), and records how h5py reads it back in pins.json:
each dataset's shape, type, SHA-256 of its little-endian bytes, a slab, its filter pipeline and how many chunks h5py stored
compressed or, where LZF did not shrink the chunk, as is (the filter is optional, so HDF5 skips it for that chunk on reading).

The datasets cover what the decoder meets: EBSD-like uint8 patterns, one chunk each; uint16 counts with partial edge chunks;
int16 behind HDF5's shuffle; a constant chunk (back references of the longest length, overlapping their own output); float32
behind Fletcher-32; and a noise chunk h5py stored uncompressed beside a compressed one.
"""
import hashlib
import json
import pathlib

import h5py
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'Tests/FormatoHDF5Tests/Fixtures/lzf'
OUT.mkdir(parents=True, exist_ok=True)
LZF = 32000


def le_bytes(a):
    return np.ascontiguousarray(a.astype(a.dtype.newbyteorder('<'), copy=False)).tobytes()


def sha(a):
    return hashlib.sha256(le_bytes(a)).hexdigest()


def datasets():
    y, x = np.mgrid[0:40, 0:48]
    disc = ((x - 24) ** 2 + (y - 20) ** 2 < 15 ** 2).astype(np.int64)
    patterns = np.stack([((x * 3 + y * 5 + k * 11) % 64 + 100 * disc) for k in range(6)]).astype(np.uint8)
    i, j = np.mgrid[0:12, 0:17]
    counts = (1000 * (i // 3) + 10 * (j // 4) + 40000 * (i > 6)).astype(np.uint16)
    i, j = np.mgrid[0:30, 0:30]
    shuffled = ((i - 15) * (j - 15) * 7).astype(np.int16)
    constant = np.full((64, 64), 7, dtype=np.uint16)
    noise = np.stack([np.random.default_rng(86).integers(0, 256, 2048), np.full(2048, 5)]).astype(np.uint8)
    i, j = np.mgrid[0:16, 0:16]
    checked = (((i * 16 + j) % 13) * 0.25 - 1.5).astype(np.float32)
    return [
        ('/patterns', patterns, dict(chunks=(1, 40, 48))),
        ('/counts', counts, dict(chunks=(5, 7))),
        ('/shuffled', shuffled, dict(chunks=(10, 30), shuffle=True)),
        ('/constant', constant, dict(chunks=(64, 64))),
        ('/noise', noise, dict(chunks=(1, 2048))),
        ('/checked', checked, dict(chunks=(8, 8), fletcher32=True)),
    ]


def main():
    path = OUT / 'lzf.h5'
    with h5py.File(path, 'w') as f:
        for name, data, options in datasets():
            f.create_dataset(name, data=data, compression='lzf', track_times=False, **options)
    pins = {}
    with h5py.File(path, 'r') as f:
        for name, data, _ in datasets():
            ds = f[name]
            back = ds[()]
            assert back.dtype == data.dtype and np.array_equal(back, data), name
            plist = ds.id.get_create_plist()
            filters = [plist.get_filter(k) for k in range(plist.get_nfilters())]
            lzf = [list(int(v) for v in values) for code, _, values, _ in filters if code == LZF]
            assert len(lzf) == 1, name
            masks = [ds.id.get_chunk_info(k).filter_mask for k in range(ds.id.get_num_chunks())]
            start = [d // 4 for d in data.shape]
            count = [max(1, d // 2) for d in data.shape]
            slab = back[tuple(slice(s, s + c) for s, c in zip(start, count))]
            pins[name] = {
                'shape': list(data.shape), 'dtype': str(data.dtype), 'sha256': sha(back),
                'slab': {'start': start, 'count': count, 'sha256': sha(slab)},
                'filters': [int(code) for code, _, _, _ in filters], 'lzfValues': lzf[0],
                'chunks': len(masks),
                # The pipeline's order: the LZF bit of a chunk's filter mask set means h5py stored that chunk without it.
                'rawChunks': sum(1 for m in masks if m & (1 << [int(c) for c, _, _, _ in filters].index(LZF))),
            }
    assert pins['/noise']['rawChunks'] == 1, 'the noise chunk is stored as is'
    assert all(p['rawChunks'] == 0 for n, p in pins.items() if n != '/noise'), 'every other chunk is LZF'
    assert pins['/counts']['chunks'] == 9, 'partial edge chunks'
    doc = {'h5py': h5py.__version__, 'hdf5': h5py.version.hdf5_version, 'numpy': np.__version__, 'datasets': pins}
    (OUT / 'pins.json').write_text(json.dumps(doc, indent=1, sort_keys=True) + '\n')
    print(f'{path.relative_to(ROOT)}: {path.stat().st_size} bytes; {len(pins)} datasets')


if __name__ == '__main__':
    main()

"""Pinned py4DSTEM BraggVectors (EMD 1.0) fixtures. Run using References/python/py4dstem/bin/python -I -B,
under the suite tools/memcap.sh. MACEM_SUITE may locate References from a worktree.

Writes Tests/FormatoHDF5Tests/Fixtures/bragg/: py4DSTEM-written files, the peaks as little-endian float64
(qx, qy, intensity) triples in scan row-major order, and pins.json with the h5py structure and the values.
"""
import os, pathlib, subprocess, json
import numpy as np
import h5py, py4DSTEM, emdfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
SUITE = pathlib.Path(os.environ.get('MACEM_SUITE', ROOT.parent))
PIN = 'f050d207851f8accd3aa550365baaf1f38230428'
assert subprocess.check_output(['git','-C',str(SUITE/'References/CuboKit/py4DSTEM-f050d207'),'rev-parse','HEAD'],text=True).strip() == PIN
assert py4DSTEM.__version__ == '0.14.19'
OUT = ROOT/'Tests/FormatoHDF5Tests/Fixtures/bragg'
OUT.mkdir(parents=True, exist_ok=True)

import importlib.util
_spec = importlib.util.spec_from_file_location('bragg_structure', ROOT / 'tools/bragg-writer/structure.py')
_h = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_h)
plain, structure = _h.plain, _h.structure

def build(name, scan, det, cells, calib):
    bv = py4DSTEM.BraggVectors(scan, det, name='braggvectors')
    for (ry, rx), peaks in cells.items():
        pl = bv._v_uncal[ry, rx]
        pl.add(np.array(peaks, dtype=pl.dtype))
    for k, v in calib.items():
        getattr(bv.calibration, 'set_' + k)(v)
    path = OUT / (name + '.h5')
    py4DSTEM.save(str(path), bv, mode='o')
    got = py4DSTEM.read(str(path))
    assert isinstance(got, py4DSTEM.BraggVectors)
    counts, flat = [], []
    for ry in range(scan[0]):
        for rx in range(scan[1]):
            d = got._v_uncal[ry, rx].data
            assert d.dtype.names == ('qx', 'qy', 'intensity')
            counts.append(len(d))
            for r in d: flat.extend([float(r['qx']), float(r['qy']), float(r['intensity'])])
    (OUT / (name + '.peaks.bin')).write_bytes(np.array(flat, dtype='<f8').tobytes())
    with h5py.File(path) as f:
        root = [k for k in f.keys()]
        assert root == ['braggvectors_root']
    cal = got.calibration
    return dict(name=name, scan=list(scan), detector=list(det), counts=counts, group='/braggvectors_root',
                calibration={k: plain(getattr(cal, 'get_' + k)()) for k in list(calib) + (['QR_rotation'] if 'QR_rotation_degrees' in calib else [])}, structure=structure(path))

pins = dict(py4dstem_commit=PIN, py4dstem_version=py4DSTEM.__version__, h5py_version=h5py.__version__,
            numpy_version=np.__version__, emdfile_version=emdfile.__version__, cases=[])
calib = dict(Q_pixel_size=0.0625, Q_pixel_units='A^-1', R_pixel_size=1.5, R_pixel_units='nm', QR_flip=True,
             QR_rotation_degrees=15.0, qx0_mean=7.5, qy0_mean=9.25, a=1.5, b=1.25, theta=-0.25, probe_semiangle=20.5)
cells = {
    (0, 0): [(3.25, 4.5, 100.0), (7.125, 9.0625, 2.5e-3)],
    (0, 2): [(1.0 / 3.0, -0.0, 1e300)],
    (1, 1): [(15.5, 19.5, 12345.6789), (0.0, 0.0, 1.0), (8.0, 8.0, np.pi)],
    (2, 3): [(2.0, 17.75, 0.5)],
}
pins['cases'].append(build('basic', (3, 4), (16, 20), cells, calib))
pins['cases'].append(build('empty', (2, 2), (8, 8), {}, dict(Q_pixel_size=1.0, Q_pixel_units='pixels', R_pixel_size=1.0, R_pixel_units='pixels', QR_flip=False)))

# Damaged-but-valid-HDF5 files for the reader's refusals, made with h5py from the py4DSTEM-written basic.h5.
# Each case is its own EMD root in malformed.h5 (selected by groupPath); two.h5 holds two BraggVectors; plain.h5 none.
with h5py.File(OUT/'basic.h5') as src, h5py.File(OUT/'malformed.h5', 'w') as f, h5py.File(OUT/'two.h5', 'w') as two, h5py.File(OUT/'plain.h5', 'w') as plain_f:
    for name in ['noshape', 'mismatch', 'notvlen', 'zeroshape', 'badcal', 'nodata', 'wrongclass', 'badstring']:
        src.copy('braggvectors_root', f, name + '_root')
    shape = lambda n: f[n + '_root/braggvectors/metadatabundle/_braggvectors_shape']
    del shape('noshape')['Rshape']
    shape('mismatch')['Rshape'][...] = [3, 5]
    del f['notvlen_root/braggvectors/_v_uncal/data']
    f['notvlen_root/braggvectors/_v_uncal/data'] = np.zeros((3, 4), dtype='<f8')
    shape('zeroshape')['Rshape'][...] = [0, 4]
    del f['badcal_root/metadatabundle/calibration/Q_pixel_size']
    f['badcal_root/metadatabundle/calibration/Q_pixel_size'] = np.array([1., 2., 3.])
    del f['nodata_root/braggvectors/_v_uncal/data']
    f['wrongclass_root/braggvectors'].attrs['python_class'] = 'DataCube'
    del f['badstring_root/metadatabundle/calibration/Q_pixel_units']
    f['badstring_root/metadatabundle/calibration/Q_pixel_units'] = np.float64(3.0)
    src.copy('braggvectors_root', two, 'a_root'); src.copy('braggvectors_root', two, 'b_root')
    plain_f['x/data'] = np.zeros((2, 2), dtype='<f4')

(OUT / 'pins.json').write_text(json.dumps(pins, indent=1, sort_keys=True) + '\n')

"""Checks the Swift-written EMD bundle fixtures against the first consumer's own files, h5py and py4DSTEM.

Run (after the Swift test wrote swift-*.h5 into the fixtures folder) with the py4DSTEM venv, under memcap.sh:

  FORMATO_EMD_FIXTURE_DIR=$PWD/Tests/FormatoHDF5Tests/Fixtures/emd-bundle swift test -c release --jobs 4 --filter EMDBundleTests
  MPLCONFIGDIR=$PWD/.build/matplotlib <suite>/tools/memcap.sh -- <suite>/References/python/py4dstem/bin/python -I -B tools/emd-bundle/check.py

app-*.h5 are mac4DSTEM's own writers' output on the same inputs (tools/emd-bundle/oracle). For each swift file:
  structure_equal   h5py shows the same groups, datasets, dtypes (string encodings, bool storage), shapes, chunking-free attributes
                    and values as the app's file (the UUID and authoring attributes excepted). swift-datacube-default.h5 stores
                    QR_flip as h5py's bool enum (the py4DSTEM way) where the app stores uint8: that one dataset's dtype is the
                    only allowed difference, and py4DSTEM must read the same flip from both.
  chunks_equal      every dataset has the app's chunk layout (the datacube: one pattern per chunk).
  data_equal        every numeric dataset equal to the app's, bit for bit.
  py4dstem_reads    py4DSTEM.read opens the file as the same class it opens the app's file as (DataCube, BraggVectors; the
                    bundle has no py4DSTEM class: both files must give the same outcome).
  py4dstem_equal    the calibration py4DSTEM reads (origin mean from the maps included), the datacube pixels, the Bragg peaks and every
                    map py4DSTEM reads from the file's root equal those it reads from the app's file.
Writes check-result.json, which the Swift tests pin together with each file's SHA-256.
"""
import hashlib, importlib.util, json, pathlib, sys
import numpy as np
import h5py, py4DSTEM

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / 'Tests/FormatoHDF5Tests/Fixtures/emd-bundle'
spec = importlib.util.spec_from_file_location('structure', ROOT / 'tools/bragg-writer/structure.py')
helpers = importlib.util.module_from_spec(spec); spec.loader.exec_module(helpers)

FILES = [  # (swift file, app file, paths whose dtype may differ)
    ('swift-datacube.h5', 'app-datacube.h5', []),
    ('swift-datacube-default.h5', 'app-datacube.h5', ['/datacube_root/metadatabundle/calibration/QR_flip']),
    ('swift-sidecar.h5', 'app-sidecar.h5', []),
    ('swift-bundle.h5', 'app-bundle.h5', []),
]
CAL_GETTERS = ['Q_pixel_size', 'Q_pixel_units', 'R_pixel_size', 'R_pixel_units', 'QR_flip', 'QR_rotation_degrees']


def read_class(path):
    try:
        got = py4DSTEM.read(str(path))
        return got, type(got).__name__
    except Exception as e:                      # the bundle has no py4DSTEM class to return
        return None, 'error:' + type(e).__name__


def chunk_layout(path):
    out = {}
    with h5py.File(path) as f:
        f.visititems(lambda n, o: out.__setitem__('/' + n, o.chunks) if isinstance(o, h5py.Dataset) else None)
    return out


def datasets(path):
    out = {}
    with h5py.File(path) as f:
        def visit(name, obj):
            if isinstance(obj, h5py.Dataset) and obj.dtype.kind in 'fiub':
                out['/' + name] = np.array(obj[()])
        f.visititems(visit)
    return out


def calibration(obj):
    cal = obj.calibration
    out = {}
    for k in CAL_GETTERS:
        try: out[k] = helpers.plain(getattr(cal, 'get_' + k)())
        except Exception as e: out[k] = 'error:' + type(e).__name__
    try: out['origin_mean'] = [float(v) for v in cal.get_origin_mean()]
    except Exception as e: out['origin_mean'] = 'error:' + type(e).__name__
    return out


def children(path):
    """The py4DSTEM objects below the one root of a file: {name: (class name, comparable content)}."""
    with h5py.File(path) as f:
        root = [k for k in f.keys()][0]
        names = [k for k in f[root].keys() if k != 'metadatabundle']
    out = {}
    for name in names:
        obj = py4DSTEM.read(str(path), datapath=root + '/' + name)
        if type(obj).__name__ == 'BraggVectors':
            peaks = [obj._v_uncal[i, j].data.tobytes() for i in range(obj.Rshape[0]) for j in range(obj.Rshape[1])]
            out[name] = (type(obj).__name__, (peaks, list(obj.Qshape), calibration(obj)))
        else:
            out[name] = (type(obj).__name__, (np.asarray(obj.data).tobytes(), list(np.asarray(obj.data).shape)))
    return out


result = dict(py4dstem_version=py4DSTEM.__version__, h5py_version=h5py.__version__, files={})
failures = []
for fname, appname, allowed in FILES:
    swift, app = FIX / fname, FIX / appname
    entry = dict(sha256=hashlib.sha256(swift.read_bytes()).hexdigest())
    a, b = helpers.structure(swift), helpers.structure(app)
    rows_a = {r['path']: r for r in a}; rows_b = {r['path']: r for r in b}
    differing = [k for k in sorted(set(rows_a) | set(rows_b)) if rows_a.get(k) != rows_b.get(k)]
    for k in differing:
        if k not in allowed:
            print(fname, 'differs', k, rows_a.get(k), rows_b.get(k))
    structure_equal = all(k in allowed for k in differing) and all(
        {x: y for x, y in rows_a[k].items() if x != 'dtype'} == {x: y for x, y in rows_b[k].items() if x != 'dtype'} for k in allowed)
    da, db = datasets(swift), datasets(app)
    data_equal = set(da) == set(db) and all(da[k].shape == db[k].shape and da[k].tobytes() == db[k].tobytes() for k in da if k not in allowed) \
        and all(np.array_equal(da[k].astype(np.uint8), db[k].astype(np.uint8)) for k in allowed if k in da and k in db)
    chunks_equal = chunk_layout(swift) == chunk_layout(app)
    obj_a, cls_a = read_class(swift); obj_b, cls_b = read_class(app)
    reads = cls_a == cls_b
    equal = True
    if obj_a is not None and obj_b is not None:
        if cls_a == 'DataCube':
            equal = np.array_equal(np.asarray(obj_a.data), np.asarray(obj_b.data)) and calibration(obj_a) == calibration(obj_b)
        elif cls_a == 'Root':
            ca, cb = children(swift), children(app)
            equal = ca == cb and len(ca) > 0
            entry['py4dstem_objects'] = {k: v[0] for k, v in sorted(ca.items())}
    entry['py4dstem_class'] = cls_a
    entry['checks'] = dict(structure_equal=bool(structure_equal), data_equal=bool(data_equal), chunks_equal=bool(chunks_equal), py4dstem_reads=bool(reads), py4dstem_equal=bool(equal))
    result['files'][fname] = entry
    failures += [fname + ':' + k for k, v in entry['checks'].items() if not v]
(FIX / 'check-result.json').write_text(json.dumps(result, indent=1, sort_keys=True) + '\n')
print(json.dumps(result, indent=1, sort_keys=True))
sys.exit(1 if failures else 0)

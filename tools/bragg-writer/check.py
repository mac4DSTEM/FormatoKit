"""Checks the Swift-written BraggVectors fixtures against py4DSTEM and h5py. Run (after generate.py, and after the Swift
test wrote swift-*.h5 into the fixtures folder) with References/python/py4dstem/bin/python -I -B, under a memory cap:

  FORMATO_BRAGG_FIXTURE_DIR=$PWD/Tests/FormatoHDF5Tests/Fixtures/bragg swift test -c release --jobs 4 --filter BraggVectorsTests
  MACEM_SUITE=... MPLCONFIGDIR=$PWD/.build/matplotlib .../python -I -B tools/bragg-writer/check.py

For each swift-*.h5: py4DSTEM.read returns a BraggVectors whose peaks equal the py4DSTEM-written pins exactly, its
calibration equals the pins, and the h5py group/dataset/attribute structure equals the py4DSTEM-written file's (extra attributes
the caller asked for excepted, and named). Writes check-result.json, which the Swift tests pin together with each file's SHA-256.
"""
import hashlib, importlib.util, json, pathlib, sys
import numpy as np
import h5py, py4DSTEM

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / 'Tests/FormatoHDF5Tests/Fixtures/bragg'
spec = importlib.util.spec_from_file_location('bragg_generate_helpers', ROOT / 'tools/bragg-writer/structure.py')
helpers = importlib.util.module_from_spec(spec); spec.loader.exec_module(helpers)
pins = json.loads((FIX / 'pins.json').read_text())
assert py4DSTEM.__version__ == pins['py4dstem_version']

# (swift file, pinned py4DSTEM case, attributes the writer was asked to add: {object path: [names]})
FILES = [
    ('swift-basic.h5', 'basic', {}),
    ('swift-empty.h5', 'empty', {}),
    ('swift-extras.h5', 'basic', {'/': ['mac4dstem_session'], '/braggvectors_root': ['mac4dstem_schema'],
                                  '/braggvectors_root/braggvectors': ['mac4dstem_detection_provenance']}),
]
result = dict(py4dstem_version=py4DSTEM.__version__, h5py_version=h5py.__version__, files={})
failures = []
for fname, case_name, extras in FILES:
    case = next(c for c in pins['cases'] if c['name'] == case_name)
    path = FIX / fname
    got = py4DSTEM.read(str(path))
    entry = dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(), py4dstem_reads=isinstance(got, py4DSTEM.BraggVectors))
    expected = np.frombuffer((FIX / (case_name + '.peaks.bin')).read_bytes(), dtype='<f8').reshape(-1, 3)
    counts, flat = [], []
    for ry in range(case['scan'][0]):
        for rx in range(case['scan'][1]):
            d = got._v_uncal[ry, rx].data
            counts.append(len(d)); flat += [[r['qx'], r['qy'], r['intensity']] for r in d]
    flat = np.array(flat, dtype='<f8').reshape(-1, 3)
    entry['counts_equal'] = counts == case['counts']
    entry['peaks_bit_exact'] = flat.tobytes() == expected.tobytes()
    entry['shapes_equal'] = (list(got.Rshape), list(got.Qshape)) == (case['scan'], case['detector'])
    cal = got.calibration
    entry['calibration_equal'] = all(plain == helpers.plain(getattr(cal, 'get_' + k)()) for k, plain in case['calibration'].items())
    swift_structure = helpers.structure(path)
    # Drop the named extras, then the structure must be exactly the py4DSTEM-written one.
    extras_seen = []
    for row in swift_structure:
        for name in extras.get(row['path'], []):
            if name in row['attrs']:
                extras_seen.append(row['path'] + '@' + name); del row['attrs'][name]
            if name in row.get('attr_keys', []): row['attr_keys'].remove(name)
    entry['extras_present'] = sorted(extras_seen) == sorted(p + '@' + n for p, ns in extras.items() for n in ns)
    entry['structure_equal'] = swift_structure == case['structure']
    if not entry['structure_equal']:
        a = {r['path']: r for r in swift_structure}; b = {r['path']: r for r in case['structure']}
        print(fname, 'only in swift:', sorted(set(a) - set(b)), 'only in py4DSTEM:', sorted(set(b) - set(a)))
        for k in sorted(set(a) & set(b)):
            if a[k] != b[k]: print(' differs', k, a[k], b[k])
    entry['extra_attribute_names'] = sorted(extras_seen)
    result['files'][fname] = entry
    failures += [fname + ':' + k for k, v in entry.items() if v is False]
(FIX / 'check-result.json').write_text(json.dumps(result, indent=1, sort_keys=True) + '\n')
print(json.dumps(result, indent=1, sort_keys=True))
sys.exit(1 if failures else 0)

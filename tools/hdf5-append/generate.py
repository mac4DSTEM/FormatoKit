"""Fixtures and h5py pins for FormatoHDF5's low-level reader (HDF5Reader) and append writer (HDF5AppendWriter).

    <suite>/References/FormatoKit/rsciio-venv/bin/python -I -B tools/hdf5-append/generate.py

(a) READ.  Writes with h5py (the reference HDF5 binding) Tests/FormatoHDF5Tests/Fixtures/low-level/{assorted,latest}.h5: many dtypes
    (both byte orders, chunked and compressed, scalar, empty), fixed and variable-length strings, attributes of every shape the
    reader takes and refuses, nested groups, a soft link and a dangling one, dense attribute storage. Records how h5py itself reads
    every object as pins.json: kind, children, attributes (reals as hex floats, exact), dataset shape, type, SHA-256 of the
    little-endian bytes, one slab's SHA-256, string values. The Swift reader must equal them exactly.

(b) APPEND. Writes append/base.h5 (h5py) and append/inputs.json (the operations the Swift test applies: groups, datasets with their
    bytes, attributes, replacements, deletions). The Swift test, run with FORMATO_WRITE_GOLDEN=1, applies them to a copy of base.h5
    and writes append/swift-*.h5. When those exist this script has h5py read them and compares the WHOLE file, object by object,
    with the model "base.h5 plus the operations": every appended dataset (dtype, shape, bytes, chunk shape), every attribute, every
    object the operations did not touch (children, attributes, dataset bytes, chunking and compression) must be identical. The
    verdict and each swift file's SHA-256 go to append/check-result.json, which the Swift tests pin.
"""
import copy, hashlib, json, pathlib, sys
import h5py
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
LL = ROOT / 'Tests/FormatoHDF5Tests/Fixtures/low-level'
AP = ROOT / 'Tests/FormatoHDF5Tests/Fixtures/append'
LL.mkdir(parents=True, exist_ok=True)
AP.mkdir(parents=True, exist_ok=True)

CLASS_NAMES = {h5py.h5t.TIME: 'time', h5py.h5t.BITFIELD: 'bitfield', h5py.h5t.OPAQUE: 'opaque', h5py.h5t.COMPOUND: 'compound',
               h5py.h5t.REFERENCE: 'reference', h5py.h5t.ENUM: 'enum', h5py.h5t.VLEN: 'vlen', h5py.h5t.ARRAY: 'array'}


def dec(x):
    return x.decode('utf-8') if isinstance(x, (bytes, np.bytes_)) else str(x)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def le_bytes(a):
    a = np.asarray(a)
    return np.ascontiguousarray(a, dtype=a.dtype.newbyteorder('<')).tobytes()


def type_name(t, dtype):
    """The reader's name for a stored type: numeric:<FormatoDataType>, string:fixed|variable, or unsupported:<name>."""
    cls = t.get_class()
    bits = t.get_size() * 8
    if cls == h5py.h5t.INTEGER:
        name = ('int' if t.get_sign() == h5py.h5t.SGN_2 else 'uint') + str(bits)
        return ('numeric:' if bits in (8, 16, 32, 64) else 'unsupported:') + name
    if cls == h5py.h5t.FLOAT:
        return ('numeric:' if bits in (32, 64) else 'unsupported:') + f'float{bits}'
    if cls == h5py.h5t.STRING:
        return 'string:variable' if t.is_variable_str() else 'string:fixed'
    return 'unsupported:' + CLASS_NAMES.get(cls, f'class{cls}')


def attr_pin(obj, name):
    a = h5py.h5a.open(obj.id, name.encode())
    t, shape = a.get_type(), a.shape
    if len(shape) > 1:
        return {'type': 'unsupported', 'name': f'rank {len(shape)}'}
    value = obj.attrs[name]
    scalar = len(shape) == 0
    cls, bits = t.get_class(), t.get_size() * 8
    if cls == h5py.h5t.STRING:
        if scalar:
            return {'type': 'text', 'value': dec(value)}
        return {'type': 'texts', 'value': [dec(x) for x in value]}
    if cls == h5py.h5t.INTEGER and bits in (8, 16, 32, 64):
        values = [int(x) for x in np.atleast_1d(value)]
        if bits == 64 and t.get_sign() == h5py.h5t.SGN_NONE and any(v > 2**63 - 1 for v in values):
            return {'type': 'limit'}
        return {'type': 'integer', 'value': values[0]} if scalar else {'type': 'integers', 'value': values}
    if cls == h5py.h5t.FLOAT and bits in (16, 32, 64):
        values = [float(x).hex() for x in np.atleast_1d(value).astype('<f8')]
        return {'type': 'real', 'value': values[0]} if scalar else {'type': 'reals', 'value': values}
    if cls == h5py.h5t.INTEGER:
        return {'type': 'unsupported', 'name': f'int{bits}'}
    if cls == h5py.h5t.FLOAT:
        return {'type': 'unsupported', 'name': f'float{bits}'}
    return {'type': 'unsupported', 'name': CLASS_NAMES.get(cls, f'class{cls}')}


def slab_of(shape):
    start = [min(1, d - 1) for d in shape]
    count = [max(1, d // 2) for d in shape]
    return start, count


def object_pin(f, path):
    try:
        obj = f[path]
    except KeyError:
        return {'kind': 'other'}                                      # a dangling soft link
    pin = {'attrs': {n: attr_pin(obj, n) for n in sorted(obj.attrs)}}
    if isinstance(obj, h5py.Group):
        pin.update(kind='group', children=sorted(obj.keys(), key=lambda s: s.encode()))
        return pin
    t = obj.id.get_type()
    pin.update(kind='dataset', shape=list(obj.shape), type=type_name(t, obj.dtype),
               chunks=list(obj.chunks) if obj.chunks else None, compression=obj.compression)
    if pin['type'].startswith('numeric:'):
        data = obj[()] if obj.shape == () else obj[...]
        pin['sha256'] = sha(le_bytes(data))
        if obj.shape and obj.size:
            start, count = slab_of(obj.shape)
            sl = tuple(slice(s, s + c) for s, c in zip(start, count))
            pin['slab'] = {'start': start, 'count': count, 'sha256': sha(le_bytes(obj[sl]))}
    elif pin['type'].startswith('string:'):
        data = np.asarray(obj[()]).reshape(-1)
        pin['strings'] = [dec(x) for x in data]
    return pin


def dump(f):
    paths = ['/']
    f.visit(lambda n: paths.append('/' + n))
    return {p: object_pin(f, p) for p in paths}


# ---------------------------------------------------------------------------------------------------- (a) read fixtures
def build_assorted(path):
    with h5py.File(path, 'w') as f:
        f.attrs.create('title', np.bytes_('assorted fixture'))                      # fixed-length ASCII
        f.attrs['note'] = 'Å 日本 😀 variable'                                        # variable-length UTF-8
        f.attrs['empty_vlen'] = ''
        f.attrs.create('count', np.int64(7))
        f.attrs.create('small', np.uint8(200))
        f.attrs.create('neg', np.int16(-300))
        f.attrs.create('scale', np.float64(0.1))
        f.attrs.create('single', np.float32(1.5))
        f.attrs.create('half', np.float16(0.5))
        f.attrs.create('ids', np.array([1, -2, 3], dtype='<i4'))
        f.attrs.create('uids', np.array([1, 2**40], dtype='<u8'))
        f.attrs.create('weights', np.array([0.5, 1.5, -2.25], dtype='<f8'))
        f.attrs.create('names_fixed', np.array([b'ab', b'cde', b''], dtype='S3'))
        f.attrs['names_vlen'] = ['x', 'Å', 'yy']
        f.attrs.create('big_endian', np.array([258, 3], dtype='>i2'))
        f.attrs['flag'] = True                                                      # h5py bool: an HDF5 enum
        f.attrs['matrix'] = np.arange(6, dtype='<i4').reshape(2, 3)                 # rank 2
        f.attrs.create('compound', np.zeros((), dtype=[('a', '<i4'), ('b', '<f8')]))
        a = f.create_group('a')
        a.attrs['kind'] = 'group a'
        b = a.create_group('b')
        c = b.create_group('c')
        c.attrs['depth'] = np.int32(3)
        d = a.create_group('data')
        for name, dt in [('i8', '<i1'), ('i16', '<i2'), ('i32', '<i4'), ('i64', '<i8'), ('u8', '<u1'), ('u16', '<u2'),
                         ('u32', '<u4'), ('u64', '<u8'), ('f32', '<f4'), ('f64', '<f8')]:
            info = np.iinfo(dt) if dt[1] in 'iu' else None
            arr = (np.arange(24).reshape(2, 3, 4) * 7 - 40).astype(dt) if info is None or info.min < 0 else np.arange(24).reshape(2, 3, 4).astype(dt) * 9
            if info is not None:
                arr.flat[0], arr.flat[-1] = info.min, info.max
            if dt == '<f4':
                arr.flat[1] = np.float32('nan'); arr.flat[2] = np.float32('-inf')
            ds = d.create_dataset(name, data=arr)
            ds.attrs['dtype'] = dt
        d.create_dataset('be_i2', data=np.array([[1, -2, 258], [300, -301, 32767]], dtype='>i2'))
        d.create_dataset('be_f8', data=np.array([0.1, -2.5e300, np.pi], dtype='>f8'))
        d.create_dataset('scalar_f8', data=np.float64(2.718281828459045))
        d.create_dataset('scalar_i4', data=np.int32(-5))
        d.create_dataset('chunked', data=np.arange(5 * 6 * 7, dtype='<u2').reshape(5, 6, 7), chunks=(2, 3, 7), compression='gzip',
                         compression_opts=4, shuffle=True)
        d.create_dataset('empty', shape=(0, 3), dtype='<f4')
        d.create_dataset('rank1', data=np.linspace(0, 1, 11))
        d.create_dataset('f16', data=np.array([0.5, 1.5], dtype='<f2'))
        d.create_dataset('flags', data=np.array([True, False, True]))               # an enum
        d.create_dataset('rec', data=np.zeros(2, dtype=[('x', '<i4'), ('y', '<f4')]))
        d.create_dataset('rgb', data=np.zeros((2, 3), dtype=[('r', 'u1'), ('g', 'u1'), ('b', 'u1')]))
        s = f.create_group('strings')
        s.create_dataset('fixed', data=np.array([b'abc', b'de', b''], dtype='S3'))
        s.create_dataset('fixed_utf8', data=np.array(['Å日'.encode(), b'x'], dtype='S6'))
        s.create_dataset('variable', data=np.array([['one', 'Åtwo'], ['', '日本語 three']], dtype=object), dtype=h5py.string_dtype())
        s.create_dataset('scalar_vlen', data='scalar text', dtype=h5py.string_dtype())
        s.create_dataset('long', data=np.array(['y' * 5000], dtype=object), dtype=h5py.string_dtype())
        f.create_group('Ünï code/with space').attrs['ok'] = np.int64(1)
        f['link'] = h5py.SoftLink('/a/data/f64')
        f['dangling'] = h5py.SoftLink('/nowhere')
        e = f.create_group('edge')
        e.attrs.create('u64max', np.uint64(2**63 + 5))
        e.attrs.create('u64fits', np.uint64(2**63 - 1))
        e.attrs.create('i64min', np.int64(-2**63))


def build_latest(path):
    with h5py.File(path, 'w', libver='latest') as f:
        g = f.create_group('dense')
        for i in range(40):                                                         # past the compact limit: dense storage
            g.attrs[f'a{i:02d}'] = np.int64(i)
        g.create_dataset('x', data=np.arange(10, dtype='<f4'))
        f.attrs['v'] = 'latest'


build_assorted(LL / 'assorted.h5')
build_latest(LL / 'latest.h5')
pins = {}
for name, extra in [('assorted.h5', ['/link', '/dangling']), ('latest.h5', [])]:
    with h5py.File(LL / name, 'r') as f:
        objects = dump(f)
        for p in extra:
            objects[p] = object_pin(f, p)
        pins[name] = {'objects': objects, 'absent': ['/nope', '/a/nope/deeper', '/a/data/f64/inside']}
(LL / 'pins.json').write_text(json.dumps({'h5py_version': h5py.__version__, 'files': pins}, indent=1, sort_keys=True) + '\n')


# ------------------------------------------------------------------------------------------------------ (b) append inputs
def ds_op(path, dtype, shape, values, chunk=None, replace=False):
    arr = np.asarray(values, dtype=dtype).reshape(shape)
    return {'op': 'dataset', 'path': path, 'dtype': np.dtype(dtype).str, 'shape': list(shape), 'hex': le_bytes(arr).hex(),
            'chunk': chunk, 'replace': replace}


def attr_op(on, name, kind, value):
    return {'op': 'attr', 'on': on, 'name': name, 'type': kind, 'value': value}


def build_base(path):
    with h5py.File(path, 'w') as f:
        f.attrs.create('title', np.bytes_('base'))
        f.attrs.create('version', np.int64(3))
        f.attrs['untouched'] = 'stays'
        g = f.create_group('grp1')
        g.attrs['kind'] = 'first group'
        d = g.create_dataset('data', data=np.arange(12, dtype='<i2').reshape(3, 4) * 11 - 5, chunks=(2, 2), compression='gzip',
                             compression_opts=3)
        d.attrs['units'] = 'counts'
        d.attrs['old'] = np.float64(1.0)
        g.create_group('sub').create_dataset('arr', data=np.array([1.5, -2.5, 3.25, 4.0, 5.0], dtype='<f4')).attrs['n'] = np.int32(5)
        f.create_dataset('orphan', data=np.float64(42.5))
        f.create_group('empty')
        f.create_dataset('keep', data=np.arange(6, dtype='<u1').reshape(2, 3))
        f.create_dataset('strs', data=np.array(['p', 'qq'], dtype=object), dtype=h5py.string_dtype())


build_base(AP / 'base.h5')
ints = lambda dt, n=8: np.array([np.iinfo(dt).min, np.iinfo(dt).max] + list(range(3, n)), dtype=dt)
SCENARIOS = [
    {'name': 'appended', 'base': True, 'file': 'swift-appended.h5', 'ops': [
        {'op': 'group', 'path': '/new/deep/er'},
        {'op': 'group', 'path': '/grp1'},                                                  # an existing group is fine
        ds_op('/new/deep/er/u8', '<u1', [2, 3, 4], np.arange(24) * 10),
        ds_op('/new/f32', '<f4', [4, 5], np.arange(20) / 8 - 1, chunk=[2, 5]),
        ds_op('/new/i64', '<i8', [3], [-2**63, 0, 2**63 - 1]),
        ds_op('/new/scalar', '<f8', [], [0.1]),
        ds_op('/new/empty', '<f4', [0, 3], []),
        ds_op('/types/i8', '<i1', [7], ints('<i1')), ds_op('/types/i16', '<i2', [7], ints('<i2')),
        ds_op('/types/i32', '<i4', [7], ints('<i4')), ds_op('/types/u16', '<u2', [7], ints('<u2')),
        ds_op('/types/u32', '<u4', [7], ints('<u4')), ds_op('/types/u64', '<u8', [7], ints('<u8')),
        ds_op('/types/f64', '<f8', [7], [-0.0, 1e-300, np.pi, -np.e, 1.7976931348623157e308, 5e-324, 0.1]),
        ds_op('/grp1/sub/extra', '<f4', [2, 2], [1, 2, 3, 4]),
        attr_op('/new', 'text', 'text', 'Å 日本 😀'),
        attr_op('/new', 'empty', 'text', ''),
        attr_op('/grp1/data', 'scale', 'real', (0.1).hex()),
        attr_op('/grp1/data', 'offsets', 'reals', [(1.5).hex(), (-2.0).hex(), (1e-9).hex()]),
        attr_op('/grp1/data', 'ids', 'integers', [1, 2, 3, -2**63]),
        attr_op('/grp1/data', 'texts', 'texts', ['a', 'bcd', '']),
        attr_op('/grp1/data', 'units', 'text', 'replaced counts, longer'),               # replaces a variable-length attribute
        attr_op('/grp1/data', 'old', 'integer', 9),                                       # replaces a float with an integer
        attr_op('/', 'flag', 'integer', 1),
        attr_op('/', 'version', 'integer', 4),
        attr_op('/', 'title', 'text', 'a longer base title'),
        attr_op('/new/f32', 'tag', 'real', (2.5).hex()),
    ]},
    {'name': 'replaced', 'base': True, 'file': 'swift-replaced.h5', 'ops': [
        ds_op('/grp1/data', '<f8', [2, 2], [1.5, 2.5, -3.5, 4.5], replace=True),          # replaces a chunked, compressed dataset
        {'op': 'delete', 'path': '/orphan'},
        {'op': 'delete', 'path': '/grp1/sub'},
        ds_op('/keep2', '<u1', [3], [1, 2, 3]),
        {'op': 'delete', 'path': '/keep2'},                                                # created then removed in one session
        ds_op('/strs2', '<u4', [1], [5]),
    ]},
    {'name': 'new', 'base': False, 'file': 'swift-new.h5', 'ops': [
        ds_op('/data/a', '<i4', [2, 2], [1, -2, 3, -4]),
        {'op': 'group', 'path': '/g/h'},
        attr_op('/', 'created_by', 'text', 'swift'),
        attr_op('/g', 'pi', 'real', np.pi.hex()),
    ]},
]
(AP / 'inputs.json').write_text(json.dumps({'scenarios': SCENARIOS}, indent=1) + '\n')


# ---------------------------------------------------------------------------------------- (b) the model and the h5py check
def parent(p):
    q = p.rsplit('/', 1)[0]
    return q or '/'


def ensure_group(model, p):
    if p in model:
        return
    ensure_group(model, parent(p))
    model[p] = {'kind': 'group', 'children': [], 'attrs': {}}
    kids = model[parent(p)]['children']
    kids.append(p.rsplit('/', 1)[1]); kids.sort(key=lambda s: s.encode())


def apply_ops(model, ops):
    for op in ops:
        if op['op'] == 'group':
            ensure_group(model, op['path'])
        elif op['op'] == 'dataset':
            p = op['path']
            ensure_group(model, parent(p))
            if p in model:
                del model[p]
            else:
                kids = model[parent(p)]['children']; kids.append(p.rsplit('/', 1)[1]); kids.sort(key=lambda s: s.encode())
            arr = np.frombuffer(bytes.fromhex(op['hex']), dtype=np.dtype(op['dtype'])).reshape(op['shape'])
            name = {'i': 'int', 'u': 'uint', 'f': 'float'}[arr.dtype.kind] + str(arr.dtype.itemsize * 8)
            pin = {'kind': 'dataset', 'attrs': {}, 'shape': op['shape'], 'type': 'numeric:' + name, 'chunks': op['chunk'],
                   'compression': None, 'sha256': sha(le_bytes(arr))}
            if arr.shape and arr.size:
                start, count = slab_of(arr.shape)
                sl = tuple(slice(s, s + c) for s, c in zip(start, count))
                pin['slab'] = {'start': start, 'count': count, 'sha256': sha(le_bytes(arr[sl]))}
            model[p] = pin
        elif op['op'] == 'attr':
            t, v = op['type'], op['value']
            model[op['on']]['attrs'][op['name']] = {'type': t} if v is None else {'type': t, 'value': v}
        elif op['op'] == 'delete':
            p = op['path']
            for q in [q for q in model if q == p or q.startswith(p + '/')]:
                del model[q]
            model[parent(p)]['children'].remove(p.rsplit('/', 1)[1])


result = {'h5py_version': h5py.__version__, 'files': {}}
with h5py.File(AP / 'base.h5', 'r') as f:
    base_dump = dump(f)
failures = []
for sc in SCENARIOS:
    path = AP / sc['file']
    if not path.exists():
        continue
    model = copy.deepcopy(base_dump) if sc['base'] else {'/': {'kind': 'group', 'children': [], 'attrs': {}}}
    apply_ops(model, sc['ops'])
    with h5py.File(path, 'r') as f:
        actual = dump(f)
        # The appended bytes themselves, from the dataset, not from the pin hash.
        for op in sc['ops']:
            if op['op'] == 'dataset' and op['path'] in actual:
                got = f[op['path']]
                want = np.frombuffer(bytes.fromhex(op['hex']), dtype=np.dtype(op['dtype'])).reshape(op['shape'])
                same = got.dtype == np.dtype(op['dtype']) and got.shape == want.shape and (got[()] if got.shape == () else got[...]).tobytes() == want.tobytes()
                if not same:
                    failures.append(f"{sc['name']}: {op['path']} differs")
    equal = actual == model
    if not equal:
        for p in sorted(set(actual) | set(model)):
            if actual.get(p) != model.get(p):
                failures.append(f"{sc['name']}: {p}: file {actual.get(p)} != model {model.get(p)}")
    result['files'][sc['file']] = {'sha256': sha(path.read_bytes()), 'equals_base_plus_operations': equal,
                                   'objects': len(actual), 'h5py_opens': True}
if result['files']:
    (AP / 'check-result.json').write_text(json.dumps(result, indent=1, sort_keys=True) + '\n')
if failures:
    print('\n'.join(failures[:20])); sys.exit(1)
print('ok', {k: v['equals_base_plus_operations'] for k, v in result['files'].items()})

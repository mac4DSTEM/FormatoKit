"""Shared h5py structure dump for generate.py and check.py (not run on its own)."""
import numpy as np
import h5py

UNSTABLE = {'UUID', 'authoring_program', 'authoring_user'}   # not part of the structure contract

def plain(v):
    if isinstance(v, bytes): return v.decode()
    if isinstance(v, np.generic): return v.item()
    return v

def structure(path):
    """Every group/dataset below the file root: kind, attributes (stable ones), dtype, shape, scalar string values."""
    rows = []
    with h5py.File(path) as f:
        rows.append(dict(path='/', kind='file', attrs={k: plain(v) for k, v in f.attrs.items() if k not in UNSTABLE},
                         attr_keys=sorted(f.attrs.keys())))
        def visit(name, obj):
            row = dict(path='/' + name, kind='group' if isinstance(obj, h5py.Group) else 'dataset',
                       attrs={k: plain(v) for k, v in obj.attrs.items()})
            if isinstance(obj, h5py.Dataset):
                info = h5py.check_string_dtype(obj.dtype)
                if info is not None:
                    row['dtype'] = 'string:' + info.encoding
                elif obj.dtype.kind == 'O' and h5py.check_vlen_dtype(obj.dtype) is not None:
                    row['dtype'] = 'vlen:' + str(h5py.check_vlen_dtype(obj.dtype))
                else:
                    row['dtype'] = str(obj.dtype)
                row['shape'] = list(obj.shape)
                if info is not None and obj.shape == ():
                    row['value'] = plain(obj[()])
                elif obj.dtype != object and obj.size <= 4:
                    row['value'] = [plain(x) for x in np.atleast_1d(obj[()]).tolist()]
            rows.append(row)
        f.visititems(visit)
    return rows

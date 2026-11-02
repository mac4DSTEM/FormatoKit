"""Pinned py4DSTEM/EMD 1.0 fixtures. Run using References/venv/bin/python -I -B,
under a memory cap. In a worktree, References/ is a link to the main checkout's.
"""
import os, pathlib, subprocess, json, uuid
import numpy as np
import h5py, py4DSTEM, emdfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
PIN = 'f050d207851f8accd3aa550365baaf1f38230428'
assert subprocess.check_output(['git','-C',str(ROOT/'References/py4DSTEM-f050d207'),'rev-parse','HEAD'],text=True).strip() == PIN
assert py4DSTEM.__version__ == '0.14.19'
OUT = ROOT/'Tests/FormatoHDF5Tests/Fixtures/4d'
OUT.mkdir(parents=True, exist_ok=True)
def fixed_uuid(path):
    """emdfile writes a random uuid4 into the root `UUID` attribute at every save; the fixture gets one derived from its
    name instead (uuid5), so a rerun is byte-identical. The kit's readers never read `UUID`."""
    value = str(uuid.uuid5(uuid.NAMESPACE_URL, 'FormatoKit/' + path.relative_to(ROOT).as_posix()))
    with h5py.File(path, 'r+') as f:
        assert len(f.attrs['UUID']) == len(value)
        f.attrs.modify('UUID', value)
pins = dict(py4dstem_commit=PIN, py4dstem_version=py4DSTEM.__version__, h5py_version=h5py.__version__, numpy_version=np.__version__, emdfile_version=emdfile.__version__, cases=[])
for name,dtype,shape in [('float32','<f4',(4,4,16,16)),('uint16','<u2',(4,4,16,16)),('singleton','<f4',(1,4,16,16))]:
    a = np.arange(np.prod(shape)).reshape(shape).astype(dtype)
    if name == 'float32': a = (a * np.float32(0.25) - np.float32(12.5)); a.flat[1] = -0.0
    cube = py4DSTEM.DataCube(a, name='cube')
    cube.calibration.set_R_pixel_size(1.25)
    cube.calibration.set_R_pixel_units('nm')
    cube.calibration.set_Q_pixel_size(0.03125)
    cube.calibration.set_Q_pixel_units('A^-1')
    cube.calibration.set_QR_flip(True)
    cube.calibration.set_QR_rotation(0.125)
    for key,value in dict(qx0_mean=7.125, qy0_mean=8.25, a=1.5, b=1.25, theta=-0.25, probe_semiangle=20.5).items():
        getattr(cube.calibration, 'set_'+key)(value)
    for i,key in enumerate(['qx0','qy0','qx0_meas','qy0_meas']):
        getattr(cube.calibration, 'set_'+key)(np.arange(np.prod(shape[:2]),dtype='<f8').reshape(shape[:2])/8+i)
    path = OUT/(name+'.h5')
    py4DSTEM.save(str(path), cube, mode='o')
    fixed_uuid(path)
    with h5py.File(path) as f:
        paths=[]
        f.visititems(lambda p,o: paths.append(p) if isinstance(o,h5py.Dataset) and o.ndim==4 else None)
        assert len(paths)==1
        dp='/'+paths[0]
        stored = f[dp][...].tobytes()
    if name != 'singleton':  # Exercise compressed floats and big-endian contiguous integers.
        with h5py.File(path, 'r+') as f:
            attrs=dict(f[dp].attrs)
            del f[dp]
            ds=f.create_dataset(dp,data=a,chunks=(1,2,8,8),compression='gzip') if name=='float32' else f.create_dataset(dp,data=a.astype('>u2'))
            ds.attrs.update(attrs)
    got = py4DSTEM.read(str(path), datapath=dp.rsplit('/',1)[0])
    np.testing.assert_array_equal(got.data, a)
    with h5py.File(path) as f:
        assert f[dp][...].tobytes()==got.data.tobytes()
    (OUT/(name+'.bin')).write_bytes(got.data.astype(dtype).tobytes())
    pins['cases'].append(dict(name=name, dataset=dp, shape=list(got.data.shape), dtype=np.dtype(dtype).name,
        R_pixel_size=got.calibration.get_R_pixel_size(),R_pixel_units=got.calibration.get_R_pixel_units(),
        Q_pixel_size=got.calibration.get_Q_pixel_size(),Q_pixel_units=got.calibration.get_Q_pixel_units(),
        QR_flip=bool(got.calibration.get_QR_flip()), QR_rotation=got.calibration.get_QR_rotation()))
    pins['cases'][-1]['scalars'] = {k:float(getattr(got.calibration, 'get_'+k)()) for k in ['qx0_mean','qy0_mean','a','b','theta','probe_semiangle','QR_rotation_degrees']}
    for key in ['qx0','qy0','qx0_meas','qy0_meas']:
        (OUT/(name+'.'+key+'.bin')).write_bytes(getattr(got.calibration, 'get_'+key)().astype('<f8').tobytes())
    with h5py.File(path) as f:
        pins['cases'][-1]['offsets'] = [float(f[dp.rsplit('/',1)[0]+'/dim'+str(i)][0]) for i in range(4)]
# The app also supports older scalar-attribute calibration and generic EMD dimensions.
# h5py is the oracle for these raw HDF5 representations (not a py4DSTEM Metadata claim).
with h5py.File(OUT/'attributes.h5','w') as f:
    f['cube/data']=np.arange(96,dtype='>u2').reshape(2,3,4,4)
    cal=f.require_group('metadatabundle/calibration')
    cal.attrs['R_pixel_size']=2.5
    cal.attrs['Q_pixel_size']=0.125
    cal.attrs['R_pixel_units']=np.bytes_('nm')
    cal.attrs['Q_pixel_units']='1/nm'
    cal.attrs['QR_flip']=True
    for i in range(4):
        ds=f.create_dataset('cube/dim'+str(i),data=np.array([0.,1.]))
        ds.attrs['name']=['Rx','Ry','Qx','Qy'][i]
    f['uncalibrated/fallback/data']=np.arange(96,dtype='<f4').reshape(2,3,4,4)
    for i in range(4):
        ds=f.create_dataset('uncalibrated/fallback/dim'+str(i),data=np.array([-1.5,-1.25]))
        ds.attrs['units']=np.bytes_('nm')
with h5py.File(OUT/'attributes.h5') as f:
    (OUT/'attributes.bin').write_bytes(f['cube/data'][...].astype('<u2').tobytes())
    (OUT/'fallback.bin').write_bytes(f['uncalibrated/fallback/data'][...].tobytes())
with h5py.File(OUT/'malformed.h5','w') as f:
    f['rank3']=np.zeros((2,3,4),dtype='f4')
    f['empty']=np.zeros((0,2,3,4),dtype='f4')
    f['complex']=np.zeros((2,2,3,4),dtype='c8')
    f['badcal/data']=np.zeros((2,2,3,4),dtype='u2')
    f.require_group('metadatabundle/calibration').attrs['R_pixel_size']=[1.,2.,3.]
    f['nonlinear/cube/data']=np.zeros((2,2,4,4),dtype='f4')
    f['nonlinear/cube/dim2']=np.array([0.,1.,3.,6.])
    f['badlength/cube/data']=np.zeros((2,2,4,4),dtype='f4')
    f['badlength/cube/dim2']=np.array([0.,1.,2.])
    f['badstring/cube/data']=np.zeros((2,2,3,4),dtype='u2')
    f.require_group('badstring/metadatabundle/calibration').attrs['R_pixel_units']=np.array([b'nm',b'um'],dtype='S2')
(OUT/'pins.json').write_text(json.dumps(pins,indent=2)+'\n')

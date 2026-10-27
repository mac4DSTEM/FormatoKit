"""Run with MACEM_SUITE=<suite> <suite>/References/FormatoKit/rsciio-venv/bin/python -I -B tools/mib/generate.py.
Processed 1/6/12/24-bit synthetic frames and raw refusal pins. App pins compile the exact pinned initializer/readPattern
with identity-view scaffolding (no crop/bin); no app files are changed or app targets built.
"""
import gzip, json, os, pathlib, subprocess, tempfile
import numpy as np
import rsciio
from rsciio.quantumdetector import file_reader
ROOT = pathlib.Path(__file__).resolve().parents[2]
SUITE = pathlib.Path(os.environ['MACEM_SUITE'])
PIN = '049e7d7070e84779b499adaf3295beee9facb004'
APP = 'c809679c8ee23a355da6af4f63665aaf64f90d0d'
assert subprocess.check_output(['git','-C',str(SUITE/'References/FormatoKit/rosettasciio-049e7d70'),'rev-parse','HEAD'],text=True).strip()==PIN
assert rsciio.__version__=='0.14.1.dev96+g049e7d707'
OUT=ROOT/'Tests/FormatoMIBTests/Fixtures'
OUT.mkdir(parents=True,exist_ok=True)
def gz(name,data): (OUT/name).write_bytes(gzip.compress(data,mtime=0))
def header(frame, w,h,code,size=384, bits=12, stamp=None, layout="1x1"):
    stamp=stamp or f'2026-01-02T03:04:{frame//3:02d}.{frame%3:06d}Z'
    prefix=f'MQ1,{frame:06d},{size:05d},1,{w},{h},{code},{layout},{bits},'
    tail=f',{stamp},1250000ns,0,\0'
    return (prefix+' '*(size-len(prefix)-len(tail))+tail).encode()
pins=dict(reference_commit=PIN,rsciio_version=rsciio.__version__,app_commit=APP,cases=[],raw=[])
with tempfile.TemporaryDirectory() as td:
    td=pathlib.Path(td)
    for bits,code,dtype,maximum in [(1,'U08','u1',2),(6,'U08','u1',64),(12,'U16','>u2',4096),(24,'U32','>u4',2**24)]:
        a=((np.arange(6*3*4,dtype='u4')*173+3)%maximum).reshape(6,3,4).astype(dtype)
        raw=b''.join(header(i,4,3,code,bits=bits)+a[i].tobytes() for i in range(6))
        for suffix,nav,first,last,hdr in [('trigger',None,None,None,True),('timestamps',None,None,None,False),('explicit',[3,2],None,None,False),('slice',[3,2],-4,-1,False),('interrupted',[4,2],None,None,False),('continuous',None,None,None,True),('quad',[3,2],None,None,False)]:
            if bits!=12 and suffix!='trigger': continue
            name=f'processed{bits}-{suffix}'; path=td/(name+'.mib')
            case_raw = b''.join(header(i,4,3,code,size=768,layout='2x2')+a[i].tobytes() for i in range(6)) if suffix=='quad' else raw
            path.write_bytes(case_raw)
            if hdr:
                (path.with_suffix('.hdr')).write_text('HDR\nFrames per Trigger (Number):\t3\nFrames in Acquisition (Number):\t6\nEnd\t\n')
                if suffix=='continuous': path.with_suffix('.hdr').write_text('HDR\nFrames per Trigger (Number):\t0\nFrames in Acquisition (Number):\t0\nEnd\t\n')
                (OUT/(name+'.hdr')).write_bytes(path.with_suffix('.hdr').read_bytes())
            s=file_reader(str(path),navigation_shape=None if nav is None else tuple(nav),first_frame=first,last_frame=last)[0]
            gz(name+'.mib.gz',case_raw); gz(name+'.data.gz',s['data'].astype(s['data'].dtype.newbyteorder('<')).tobytes())
            pins['cases'].append(dict(name=name,shape=list(s['data'].shape),dtype=s['data'].dtype.name,axes=s['axes'],metadata=s['metadata'],navigation=nav,first=first,last=last,app=False))
    # Squeezing includes navigation and detector singleton axes before the final -2 flip.
    for dims in [(1,3,4),(2,1,4),(2,3,1)]:
        n,h,w=dims; name=f'singleton-{n}-{h}-{w}'; a=np.arange(n*h*w,dtype='>u2').reshape(dims)
        raw=b''.join(header(i,w,h,'U16')+a[i].tobytes() for i in range(n)); path=td/(name+'.mib'); path.write_bytes(raw)
        s=file_reader(str(path),navigation_shape=(n,))[0]
        gz(name+'.mib.gz',raw); gz(name+'.data.gz',s['data'].astype('<u2').tobytes())
        pins['cases'].append(dict(name=name,shape=list(s['data'].shape),dtype='uint16',axes=s['axes'],metadata=s['metadata'],navigation=[n],first=None,last=None,app=False))
    for bits in [1,6,12,24]:
        name=f'raw{bits}'; path=td/(name+'.mib'); raw=header(0,4,3,'R64',bits=bits)+bytes(96); path.write_bytes(raw)
        try: file_reader(str(path),navigation_shape=(1,))
        except NotImplementedError as e: pins['raw'].append(dict(name=name,error=str(e)))
        else: raise AssertionError('raw unexpectedly read')
        gz(name+'.mib.gz',raw)
    # Exact app readPattern, with the initializer kept verbatim; all three app detector assemblies.
    source=subprocess.check_output(['git','-C',str(SUITE/'mac4DSTEM'),'show',APP+':mac4DSTEM/Core/Data/VendorRawReaders.swift'],text=True)
    actor=source[source.index('package actor MIBReader:'):]
    actor=actor[:actor.index('    package func discoverPrimaryDataset')]+actor[actor.index('    package func readPattern'):actor.index('    package func readScanRow')]+ '\n}\n'
    actor=actor.replace('package actor MIBReader: FourDDataSource','actor MIBReader').replace('package ','')
    scaffold=(ROOT/'tools/mib/app-scaffold.swift').read_text()
    swift=td/'oracle.swift'; swift.write_text(scaffold+actor+'''\n@main struct Main { static func main() async throws {
let reader = try MIBReader(path: CommandLine.arguments[1]); var data = Data()
for x in 0..<2 { for value in try await reader.readPattern(LoadView(), ry: 0, rx: x) {
var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
} }; try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
} }\n''')
    subprocess.run(['swiftc','-parse-as-library',str(swift),'-o',str(td/'oracle')],check=True)
    for code,dtype,layout,d in [('U08','u1','1x1',256),('U16','>u2','1x1',256),('U32','>u4','1x1',256),('U08','u1','2x2',512),('U08','u1','2x2G',514)]:
        name='app-'+code+('-'+layout if layout!='1x1' else ''); a=(np.arange(2*d*d,dtype='u4')%251).astype(dtype).reshape(2,d,d)
        if code=='U32': a[0,0,:3]=[2**24+1,2**24+3,2**32-1]
        raw=b''.join(header(i,d,d,code,size=384 if d==256 else 768,layout=layout)+a[i].tobytes() for i in range(2)); path=td/(name+'.mib'); path.write_bytes(raw)
        hdr='ScanX:\t2\nScanY:\t1\n'; path.with_suffix('.hdr').write_text(hdr); (OUT/(name+'.hdr')).write_text(hdr)
        subprocess.run([str(td/'oracle'),str(path),str(td/'data')],check=True)
        gz(name+'.mib.gz',raw); gz(name+'.data.gz',(td/'data').read_bytes())
        pins['cases'].append(dict(name=name,shape=[1,2,d,d],dtype='float32',axes=[],metadata={},navigation=None,first=None,last=None,app=True))
(OUT/'pins.json').write_text(json.dumps(pins,indent=2)+'\n')

"""Synthetic 4D DM4 and byte/axis pins. Run under a memory cap:
MACEM_SUITE=<suite> References/venv/bin/python -I -B tools/dm4-gather/generate.py.
App output comes from its exact pinned gather and decode methods, compiled with identity-view scaffolding.
"""
import os, pathlib, subprocess, tempfile, struct, json, hashlib
import numpy as np
import rsciio
from rsciio.digitalmicrograph import file_reader
ROOT=pathlib.Path(__file__).resolve().parents[2]; SUITE=pathlib.Path(os.environ['MACEM_SUITE'])
PIN='049e7d7070e84779b499adaf3295beee9facb004'; APP='c809679c8ee23a355da6af4f63665aaf64f90d0d'
assert subprocess.check_output(['git','-C',str(ROOT/'References/rosettasciio-049e7d70'),'rev-parse','HEAD'],text=True).strip()==PIN
assert rsciio.__version__=='0.14.1.dev96+g049e7d707'
OUT=ROOT/'Tests/FormatoDMTests/Fixtures/gather'; OUT.mkdir(parents=True,exist_ok=True)
def u64(n): return struct.pack('>Q',n)
def tag(name,info,payload):
    b=name.encode(); return b'\x15'+struct.pack('>H',len(b))+b+u64(0)+b'%%%%'+u64(len(info))+b''.join(u64(x) for x in info)+payload
def integer(name,n): return tag(name,[3],struct.pack('<i',n))
def number(name,n): return tag(name,[7],struct.pack('<d',n))
def text(name,s): return tag(name,[20,4,len(s.encode('utf-16le'))//2],s.encode('utf-16le'))
def group(name,children):
    b=name.encode(); body=b'\x01\x00'+u64(len(children))+b''.join(children)
    return b'\x14'+struct.pack('>H',len(b))+b+u64(len(body))+body
source=subprocess.check_output(['git','-C',str(SUITE/'mac4DSTEM'),'show',APP+':mac4DSTEM/Core/Data/DM4Reader.swift'],text=True)
# Pure pixel methods; storage shape and tag parsing are checked independently by rsciio and Swift tests.
gather=source[source.index('    private var scanFastestStrides:'):source.index('    /// True when a whole view scan row')]
decode=source[source.index('    private func decode(byteOffset'):source.index('    /// Byte size of a tag encoded-type')]
scaffold='''import Foundation
enum DM4Error: Error { case truncated }
struct Crop { let xOffset: Int; let yOffset: Int; let width: Int; let height: Int }
struct LoadView { var readDetectorCrop: Crop? { nil } }
struct Oracle {
let data: Data; let dataOffset = 0; let ry: Int; let rx: Int; let qy: Int; let qx: Int; let imageDataType: Int; let elementSize: Int
'''
main='''
func values(scanFast: Bool) throws -> [Float] {
if scanFast { return try scanFastestGather(LoadView(), positions: (0..<ry).flatMap { y in (0..<rx).map { (y,$0) } }) }
return try decode(byteOffset: 0, count: ry*rx*qy*qx)
}
}
@main struct Main { static func main() throws {
let a=CommandLine.arguments; let dims=a[3...6].map { Int($0)! }
let oracle=Oracle(data: try Data(contentsOf: URL(fileURLWithPath:a[1])),ry:dims[0],rx:dims[1],qy:dims[2],qx:dims[3],imageDataType:Int(a[7])!,elementSize:Int(a[8])!)
var out=Data(); for value in try oracle.values(scanFast:a[9]=="1") { var bits=value.bitPattern.littleEndian; withUnsafeBytes(of:&bits) { out.append(contentsOf:$0) } }
try out.write(to:URL(fileURLWithPath:a[2]))
} }
'''
pins=dict(reference_commit=PIN,rsciio_version=rsciio.__version__,app_commit=APP,cases=[])
with tempfile.TemporaryDirectory() as td:
    td=pathlib.Path(td); swift=td/'oracle.swift'; swift.write_text(scaffold+gather+decode+main)
    subprocess.run(['swiftc','-parse-as-library',str(swift),'-o',str(td/'oracle')],check=True)
    # Non-square pairs expose transposition. Large scan exercises the app's blocked >=32 position branch.
    for code,enc,dtype in [(1,2,'<i2'),(2,6,'<f4'),(6,10,'u1'),(7,3,'<i4'),(9,9,'i1'),(10,4,'<u2'),(11,5,'<u4'),(12,7,'<f8')]:
        for layout in ['detector','scan']:
            name=f'{layout}-{code}'; dims=[5,3,4,2] if layout=='detector' else [4,2,3,5]
            if code==2 and layout=='scan': dims=[8,5,3,5]
            a=(np.arange(np.prod(dims))*3+7).astype(dtype).reshape(dims[::-1])
            if code in [2,12]: a.flat[:5]=[-0.0,0.125,-12.5,np.inf,np.nan]
            if code==11: a.flat[:3]=[2**24+1,2**24+3,2**32-1]
            units=['1/nm','1/nm','nm','nm'] if layout=='detector' else ['nm','nm','1/nm','1/nm']
            axes=[group(str(i),[number('Origin',i+0.5),number('Scale',2.0**(-i-2)),text('Units',units[i])]) for i in range(4)]
            image=group('0',[text('Name',name),group('ImageData',[integer('DataType',code),group('Dimensions',[integer(str(i),d) for i,d in enumerate(dims)]),group('Calibrations',[group('Dimension',axes)]),tag('Data',[20,enc,a.size],a.tobytes())]),group('ImageTags',[group('Meta Data',[text('Format','Diffraction image')]),group('Microscope Info',[number('Voltage',200000.)])])])
            root=b'\x01\x00'+u64(1)+group('ImageList',[image]); raw=struct.pack('>I',4)+u64(len(root))+struct.pack('>I',1)+root
            path=OUT/(name+'.dm4'); path.write_bytes(raw); s=file_reader(str(path))[0]
            assert s['data'].tobytes()==a.tobytes()
            (OUT/(name+'.bin')).write_bytes(s['data'].tobytes())
            shape=list(s['data'].shape); perm=[0,1,2,3] if layout=='detector' else [2,3,1,0]; app_shape=[shape[i] for i in perm]
            (td/'raw').write_bytes(a.tobytes())
            subprocess.run([str(td/'oracle'),str(td/'raw'),str(td/'app'),*map(str,app_shape),str(code),str(a.itemsize),'1' if layout=='scan' else '0'],check=True)
            (OUT/(name+'.app.bin')).write_bytes((td/'app').read_bytes())
            pins['cases'].append(dict(name=name,shape=shape,dtype=s['data'].dtype.name,axes=s['axes'],app_shape=app_shape,permutation=perm,sha256=hashlib.sha256(raw).hexdigest()))
(OUT/'pins.json').write_text(json.dumps(pins,indent=2)+'\n')

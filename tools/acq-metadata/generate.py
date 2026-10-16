"""Acquisition-metadata fixtures and pins (FormatoCore AcquisitionMetadata; FormatoDM/MRC/TIFF/EMD readers).

    MACEM_SUITE=<suite> <suite>/tools/memcap.sh -- <suite>/References/FormatoKit/rsciio-venv/bin/python -I -B tools/acq-metadata/generate.py

Writes small synthetic DM4, MRC, TIFF and Velox EMD files (struct/h5py only, byte by byte) under Tests/*/Fixtures/acq-metadata/ and,
for each, two pins:
  reference  RosettaSciIO 049e7d70 read the file (digitalmicrograph / mrc / tiff / emd) and its returned `mapping` applied the way
             HyperSpy applies it (rsciio_oracle.py). The TIFF Velox XML (tag 34683) is read by no RosettaSciIO plugin: its
             reference is the EMD mapping's own lambdas (float(x) / 1e3 and float(x) * 1e3) typed here.
  app        the consumer's readers compiled UNCHANGED from macTEM cb6e164 (git show, read-only) with stand-ins for the types
             they import (harness.swift), run on the same inputs. Never produced by the kit's Swift.
"""
import json, os, pathlib, struct, subprocess, tempfile, sys

import h5py
import numpy as np
import rsciio
from rsciio.digitalmicrograph import file_reader as dm_reader
from rsciio.mrc import file_reader as mrc_reader
from rsciio.tiff import file_reader as tiff_reader
from rsciio.emd import file_reader as emd_reader

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from rsciio_oracle import apply_mapping

ROOT = pathlib.Path(__file__).resolve().parents[2]
SUITE = pathlib.Path(os.environ['MACEM_SUITE'])
PIN = '049e7d7070e84779b499adaf3295beee9facb004'
APP = 'cb6e164f9227bf716185ed515bb6a2afb3a8841f'
assert subprocess.check_output(['git', '-C', str(SUITE / 'References/FormatoKit/rosettasciio-049e7d70'), 'rev-parse', 'HEAD'], text=True).strip() == PIN
assert rsciio.__version__ == '0.14.1.dev96+g049e7d707'
HERE = pathlib.Path(__file__).resolve().parent
OUT = {k: ROOT / f'Tests/{k}Tests/Fixtures/acq-metadata' for k in ('FormatoDM', 'FormatoMRC', 'FormatoTIFF', 'FormatoEMD')}
for p in OUT.values():
    p.mkdir(parents=True, exist_ok=True)


def target_key(target):
    for prefix in ('Acquisition_instrument.TEM.', 'Acquisition_instrument.SEM.'):
        if target.startswith(prefix):
            rest = target[len(prefix):]
            return 'exposure' if rest in ('Camera.exposure', 'Detector.Camera.exposure') else rest
    return target


WANTED = {'beam_energy', 'camera_length', 'magnification', 'dwell_time', 'exposure', 'acquisition_mode', 'microscope',
          'General.date', 'General.time',
          # 0.3.1: the stage, beam current, SEM working distance, operator and EELS angles
          'Stage.tilt_alpha', 'Stage.tilt_beta', 'Stage.rotation', 'Stage.x', 'Stage.y', 'Stage.z', 'beam_current', 'working_distance',
          'General.authors', 'Detector.EELS.collection_angle', 'convergence_angle'}


def reference(signal):
    # An SEM stage has one tilt: RosettaSciIO's `Stage.tilt` is read as the alpha tilt (Swift: stageTiltAlphaDeg).
    # An EELS signal's own dwell/exposure targets are read into the same fields (Swift: dwellUS / exposureS).
    renames = {'Stage.tilt': 'Stage.tilt_alpha', 'Detector.EELS.dwell_time': 'dwell_time', 'Detector.EELS.exposure': 'exposure'}
    got = {renames.get(target_key(t), target_key(t)): v for t, v in apply_mapping(signal).items()}
    return {k: (float(v) if isinstance(v, (int, float, np.floating)) else v) for k, v in got.items() if k in WANTED}


# ---------------------------------------------------------------------------------------------------------------- DM
def u64(n): return struct.pack('>Q', n)
def tag(name, info, payload):
    b = name.encode(); return b'\x15' + struct.pack('>H', len(b)) + b + u64(0) + b'%%%%' + u64(len(info)) + b''.join(u64(x) for x in info) + payload
def number(name, n): return tag(name, [7], struct.pack('<d', n))
def text(name, s): return tag(name, [20, 4, len(s.encode('utf-16le')) // 2], s.encode('utf-16le'))
def integer(name, n): return tag(name, [3], struct.pack('<i', n))
def group(name, children):
    b = name.encode(); body = b'\x01\x00' + u64(len(children)) + b''.join(children)
    return b'\x14' + struct.pack('>H', len(b)) + b + u64(len(body)) + body


def tag_tree(items):
    """items: [(dotted path, float|str)] -> list of DM tag children (nested groups, first-seen order)."""
    tree = {}
    for path, value in items:
        node = tree
        parts = path.split('.')
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = value
    def build(d):
        out = []
        for k, v in d.items():
            if isinstance(v, dict): out.append(group(k, build(v)))
            elif isinstance(v, str): out.append(text(k, v))
            else: out.append(number(k, v))
        return out
    return build(tree)


def dm4_file(items, bare=False):
    tags = tag_tree(items)
    if bare:
        root = b'\x01\x00' + u64(len(tags)) + b''.join(tags)
        return struct.pack('>I', 4) + u64(len(root)) + struct.pack('>I', 1) + root
    a = np.arange(4, dtype='<i2')
    dims = group('Dimension', [group(str(i), [number('Origin', 0.), number('Scale', 1.), text('Units', 'nm')]) for i in range(2)])
    image = group('0', [text('Name', 'x'), group('ImageData', [integer('DataType', 1), group('Dimensions', [integer('0', 2), integer('1', 2)]),
                        group('Calibrations', [dims, group('Brightness', [number('Origin', 0.), number('Scale', 1.), text('Units', '')])]),
                        tag('Data', [20, 2, 4], a.tobytes())]), group('ImageTags', tags)])
    root = b'\x01\x00' + u64(1) + group('ImageList', [image])
    return struct.pack('>I', 4) + u64(len(root)) + struct.pack('>I', 1) + root


MI = 'Microscope Info.'
DM_CASES = {
    'stem': [(MI + 'Voltage', 200000.), (MI + 'Illumination Mode', 'STEM NANOPROBE'), (MI + 'Imaging Mode', 'IMAGING'),
             (MI + 'STEM Camera Length', 130.), (MI + 'Indicated Magnification', 2.0e6), (MI + 'Actual Magnification', 2.1e6),
             (MI + 'Name', 'FEI Tecnai Remote'), (MI + 'Microscope', '[]'), ('Session Info.Microscope', 'FEI Titan'),
             ('DigiScan.Sample Time', 15.), ('DataBar.Acquisition Date', '27.08.2016'), ('DataBar.Acquisition Time', '20:54:33'),
             ('DataBar.Exposure Time (s)', 0.5), ('Acquisition.Device.Name', 'Orius')],
    'tem-image': [(MI + 'Voltage', 300000.), (MI + 'Illumination Mode', 'TEM'), (MI + 'Imaging Mode', 'IMAGING'),
                  (MI + 'Indicated Magnification', 50000.), (MI + 'Name', 'Tecnai'),
                  ('Acquisition.Parameters.Detector.exposure (s)', 0.25), ('DataBar.Exposure Time (s)', 0.26),
                  ('DataBar.Acquisition Date', '8/8/2016'), ('DataBar.Acquisition Time', '4:26:37 PM'),
                  ('Acquisition.Device.Name', 'K2 ')],
    'tem-diffraction': [(MI + 'Voltage', 200000.), (MI + 'Illumination Mode', 'TEM'), (MI + 'Imaging Mode', 'DIFFRACTION'),
                        (MI + 'Indicated Magnification', 680.), (MI + 'STEM Camera Length', 99.)],
    'sem': [(MI + 'Voltage', 5000.), (MI + 'Illumination Mode', 'SEM'), (MI + 'STEM Camera Length', 0.), (MI + 'Indicated Magnification', 1.),
            ('DigiScan.Sample Time', 2.)],
    'stack-builder': [(MI + 'Voltage', 100000.), (MI + 'Illumination Mode', 'TEM'), (MI + 'Indicated Magnification', 1000.),
                      ('source.Tags at creation.' + MI + 'Voltage', 200000.), ('source.Tags at creation.' + MI + 'Illumination Mode', 'STEM'),
                      ('source.Tags at creation.' + MI + 'STEM Camera Length', 100.), ('source.Tags at creation.' + MI + 'Indicated Magnification', 5.0e5),
                      ('source.Tags at creation.DataBar.Acquisition Date', '1/31/2020'), ('source.Tags at creation.DataBar.Acquisition Time', '23:59:58')],
    'stack-fallback': [('source.Tags at creation.' + MI + 'Voltage', 120000.), ('source.Tags at creation.' + MI + 'Illumination Mode', 'TEM'),
                       (MI + 'Indicated Magnification', 700.)],
    'zeros': [(MI + 'Voltage', 0.), (MI + 'Illumination Mode', 'STEM'), (MI + 'STEM Camera Length', 0.), (MI + 'Indicated Magnification', 0.),
              ('DigiScan.Sample Time', 0.)],
    'negative-voltage': [(MI + 'Voltage', -200000.), (MI + 'Illumination Mode', 'TEM'), (MI + 'Indicated Magnification', 10.)],
    'whitespace-names': [(MI + 'Illumination Mode', 'TEM'), (MI + 'Imaging Mode', 'IMAGING'), (MI + 'Indicated Magnification', 100.),
                         ('Session Info.Microscope', '  '), (MI + 'Name', 'Titan '), ('Acquisition.Device.Name', '  ')],
    'no-microscope-group': [('DataBar.Acquisition Date', '1/2/2020'), ('DataBar.Acquisition Time', '01:02:03'),
                            ('Acquisition.Parameters.Detector.exposure (s)', 1.0)],
    'ambiguous-date': [(MI + 'Voltage', 80000.), (MI + 'Illumination Mode', 'TEM'), ('DataBar.Acquisition Date', '03/04/2021'),
                       ('DataBar.Acquisition Time', '12:00:00 a.m.')],
    'stage-beam-operator': [(MI + 'Voltage', 200000.), (MI + 'Illumination Mode', 'STEM'), (MI + 'STEM Camera Length', 100.),
                            (MI + 'Indicated Magnification', 1.0e6), (MI + 'Stage Position.Stage Alpha', 12.5), (MI + 'Stage Position.Stage Beta', -3.25),
                            (MI + 'Stage Position.Stage X', 1234.5), (MI + 'Stage Position.Stage Y', -67.25), (MI + 'Stage Position.Stage Z', 8.125),
                            (MI + 'Probe Current (nA)', 0.125), ('Session Info.Operator', 'P. Operator ')],
    'sem-stage': [(MI + 'Voltage', 5000.), (MI + 'Illumination Mode', 'SEM'), (MI + 'Stage Position.Stage Alpha', 30.), (MI + 'Probe Current (nA)', 2.0),
                  ('Session Info.Operator', '')],
    'eels-angles': [(MI + 'Voltage', 200000.), (MI + 'Illumination Mode', 'STEM'), (MI + 'STEM Camera Length', 48.), ('Meta Data.Signal', 'EELS'),
                    ('EELS.Experimental Conditions.Collection semi-angle (mrad)', 20.), ('EELS.Experimental Conditions.Convergence semi-angle (mrad)', 30.),
                    ('DigiScan.Sample Time', 15.)],
    'eels-exposure-frames': [(MI + 'Voltage', 200000.), ('Meta Data.Signal', 'EELS'), ('EELS.Acquisition.Exposure (s)', 0.25),
                             ('EELS.Acquisition.Number of frames', 4.)],
    'eels-integration': [(MI + 'Voltage', 200000.), ('Meta Data.Signal', 'EELS'), ('EELS.Acquisition.Integration time (s)', 2.0),
                         ('EELS.Acquisition.Exposure (s)', 0.5), ('Acquisition.Parameters.Detector.exposure (s)', 9.)],
    'eels-scanning': [(MI + 'Voltage', 200000.), ('Meta Data.Signal', 'EELS'), ('DigiScan.Sample Time', 15.), ('EELS.Acquisition.Exposure (s)', 0.5)],
    'xray-no-dwell': [(MI + 'Voltage', 200000.), ('Meta Data.Signal', 'X-ray'), ('DigiScan.Sample Time', 15.)],
    'cl-dwell': [(MI + 'Voltage', 200000.), ('Meta Data.Signal', 'CL'), ('DigiScan.Sample Time', 15.)],
    'eels-orsay': [(MI + 'Voltage', 100000.), (MI + 'Illumination Mode', 'STEM'), ('spim.eels.Dummy', 1.),
                   ('EELS.Experimental Conditions.Collection semi-angle (mrad)', 25.)],
    'angles-without-eels-signal': [(MI + 'Voltage', 100000.), ('EELS.Experimental Conditions.Collection semi-angle (mrad)', 25.),
                                   ('EELS.Experimental Conditions.Convergence semi-angle (mrad)', 10.)],
    'stack-stage': [(MI + 'Voltage', 100000.), ('source.Tags at creation.' + MI + 'Voltage', 200000.),
                    ('source.Tags at creation.' + MI + 'Stage Position.Stage Alpha', 7.5), ('source.Tags at creation.Session Info.Operator', 'Stack Op'),
                    ('Meta Data.Signal', 'EELS'),
                    ('source.Tags at creation.EELS.Experimental Conditions.Collection semi-angle (mrad)', 11.)],
    'unparseable-date': [(MI + 'Voltage', 80000.), ('DataBar.Acquisition Date', '2021-03-04'), ('DataBar.Acquisition Time', '12:00:00')],
}


def tag_maps(items):
    return ({k: v for k, v in items if not isinstance(v, str)}, {k: v for k, v in items if isinstance(v, str)})


# ---------------------------------------------------------------------------------------------------------------- MRC
def mrc_header(nsymbt, exttyp=b'\0\0\0\0', stamp=b'\x44\x44\0\0', mode=2, nx=4, ny=4):
    h = bytearray(1024)
    struct.pack_into('<4i', h, 0, nx, ny, 1, mode)
    struct.pack_into('<3i', h, 28, nx, ny, 1)
    struct.pack_into('<3f', h, 40, nx * 1.0, ny * 1.0, 1.0)
    struct.pack_into('<3i', h, 64, 1, 2, 3)
    struct.pack_into('<i', h, 92, nsymbt)
    h[104:108] = exttyp
    h[208:212] = b'MAP '
    h[212:216] = stamp
    return h


def fei2_record(fields):
    """fields: name -> (value, set_bit). Bit layout and offsets as AcquisitionMetadataMRC.swift states (mrcfile 1.5.4 dtypes.py)."""
    r = bytearray(888)
    struct.pack_into('<i', r, 0, 888)
    masks = [0, 0, 0, 0]
    layout = {'timestamp': (12, 'd', 0, 0), 'microscopeType': (20, 'S', 0, 1), 'ht': (84, 'd', 0, 5), 'instrumentMode': (244, 'i', 0, 25),
              'magnification': (289, 'd', 0, 31), 'cameraLength': (301, 'd', 1, 0), 'integration': (419, 'd', 1, 16),
              'cameraName': (435, 'S', 1, 19), 'stemDetector': (519, 'S', 2, 7), 'dwell': (571, 'd', 2, 15), 'commercial': (804, 'S', 3, 7)}
    for name, (value, on) in fields.items():
        off, kind, mask, bit = layout[name]
        if kind == 'd': struct.pack_into('<d', r, off, value)
        elif kind == 'i': struct.pack_into('<i', r, off, value)
        else: r[off:off + 16] = value.encode().ljust(16, b'\0')
        if on: masks[mask] |= 1 << bit
    for off, m in zip((8, 297, 490, 748), masks):
        struct.pack_into('<I', r, off, m)
    return bytes(r)


def mrc_file(header, ext, nx=4, ny=4):
    return bytes(header) + ext + np.arange(nx * ny, dtype='<f4').tobytes()


MRC_CASES = {}
fei128 = bytearray(128 * 1024)
struct.pack_into('<f', fei128, 32, 0.3)       # exp_time (s), record 0
struct.pack_into('<f', fei128, 48, 14500.0)   # magnification, record 0
struct.pack_into('<f', fei128, 128 + 32, 9.0)
struct.pack_into('<f', fei128, 128 + 48, 99.0)
MRC_CASES['fei-128-sections'] = mrc_file(mrc_header(128 * 1024), bytes(fei128))
MRC_CASES['fei-128-big-endian-stamp'] = mrc_file(mrc_header(128 * 1024, stamp=b'\x11\x11\0\0'), bytes(fei128))
good = {'timestamp': (44900.550779478755, 1), 'microscopeType': ('Talos F200X', 1), 'ht': (300000.0, 1), 'instrumentMode': (3, 1),
        'magnification': (28500.0, 1), 'cameraLength': (0.844, 1), 'integration': (0.5, 1), 'cameraName': ('Ceta', 1),
        'stemDetector': ('', 1), 'dwell': (1e-5, 1), 'commercial': ('BM-Ceta', 1)}
rec = fei2_record(good)
MRC_CASES['fei2-all-set'] = mrc_file(mrc_header(2 * 888, exttyp=b'FEI2'), rec + rec)
MRC_CASES['fei2-zero-and-clear-bits'] = mrc_file(mrc_header(888, exttyp=b'FEI2'), fei2_record(
    {**good, 'ht': (0.0, 1), 'magnification': (0.0, 1), 'cameraLength': (0.844, 0), 'dwell': (1e-5, 0), 'integration': (0.0, 1)}))
MRC_CASES['fei2-big-endian'] = None  # built below
MRC_CASES['no-extended-header'] = mrc_file(mrc_header(0), b'')
del MRC_CASES['fei2-big-endian']


# ---------------------------------------------------------------------------------------------------------------- TIFF
def tiff_file(extra):
    """A little-endian classic TIFF with one 2 x 2 uint8 strip and the private tags in `extra` {code: (type, bytes)}."""
    entries = {256: (3, struct.pack('<H', 2)), 257: (3, struct.pack('<H', 2)), 258: (3, struct.pack('<H', 8)),
               259: (3, struct.pack('<H', 1)), 262: (3, struct.pack('<H', 1)), 277: (3, struct.pack('<H', 1)),
               278: (3, struct.pack('<H', 2)), 279: (4, struct.pack('<I', 4))}
    entries.update(extra)
    n = len(entries) + 1  # + StripOffsets
    ifd_size = 2 + 12 * n + 4
    blob = bytearray()
    data_at = 8 + ifd_size
    pixels = bytes([1, 2, 3, 4])
    blob += pixels
    layout = {}
    for code, (typ, payload) in sorted(entries.items()):
        if len(payload) <= 4:
            layout[code] = (typ, len(payload) // {3: 2, 4: 4, 5: 8}.get(typ, 1), payload.ljust(4, b'\0'))
        else:
            if len(blob) % 2: blob += b'\0'
            layout[code] = (typ, len(payload) // {3: 2, 4: 4, 5: 8}.get(typ, 1), struct.pack('<I', data_at + len(blob)))
            blob += payload
    layout[273] = (4, 1, struct.pack('<I', data_at))
    out = bytearray(b'II*\0' + struct.pack('<I', 8) + struct.pack('<H', len(layout)))
    for code, (typ, count, value) in sorted(layout.items()):
        out += struct.pack('<HHI', code, typ, count) + value
    out += struct.pack('<I', 0)
    assert len(out) == 8 + ifd_size
    return bytes(out + blob)


def ascii_tag(s): return (2, s.encode() + b'\0')


def velox_xml(**o):
    d = dict(volts='200000', mag='17500', length='0.844', op='TEM', proj='Imaging', det='BM-Ceta', exposure='0.5',
             start='2026-06-05T13:05:07.123', second='2026-06-05T13:05:07.123', model='Talos F200X')
    d.update(o)
    return ('<Metadata xmlns="http://schemas.fei.com/Metadata/v1/2013/07"><Instrument><InstrumentModel>%(model)s</InstrumentModel></Instrument>'
            '<Optics><AccelerationVoltage>%(volts)s</AccelerationVoltage><NominalMagnification>%(mag)s</NominalMagnification>'
            '<CameraLength>%(length)s</CameraLength><OperatingMode>%(op)s</OperatingMode><ProjectorMode>%(proj)s</ProjectorMode></Optics>'
            '<BinaryResult><Detector>%(det)s</Detector></BinaryResult>'
            '<Detectors><Detector-0><DetectorName>BF</DetectorName><ExposureTime>9</ExposureTime></Detector-0>'
            '<Detector-1><DetectorName>%(det)s</DetectorName><ExposureTime>%(exposure)s</ExposureTime></Detector-1></Detectors>'
            '<Acquisition><AcquisitionStartDatetime>%(start)s</AcquisitionStartDatetime><AcquisitionDatetime>%(second)s</AcquisitionDatetime></Acquisition>'
            '</Metadata>') % d


def fei_ini(hv='5000', dwell='1e-05', date='06/05/2026', time='01:02:03 PM'):
    return ('[User]\r\nDate=%s\r\nTime=%s\r\nUser=analyst\r\n[System]\r\nSystemType=Helios NanoLab" 660\r\n[Beam]\r\nHV=%s\r\n'
            '[Scan]\r\nDwelltime=%s\r\nPixelWidth=1e-08\r\nPixelHeight=1e-08\r\n[Detectors]\r\nName=ETD\r\n') % (date, time, hv, dwell)


TIFF_CASES = {
    'velox-ceta-imaging': {34683: ascii_tag(velox_xml())},
    'velox-diffraction-zero-voltage': {34683: ascii_tag(velox_xml(proj='Diffraction', volts='0', length='0.15', mag='0'))},
    'velox-stem': {34683: ascii_tag(velox_xml(op='STEM', proj='Imaging', length='0.2'))},
    'velox-zone-designator': {34683: ascii_tag(velox_xml(start='2026-06-05T13:05:07Z'))},
    'fei-helios': {34682: ascii_tag(fei_ini())},
    'fei-sfeg-zero': {34680: ascii_tag(fei_ini(hv='0', dwell='0'))},
    'fei-first-field-day': {34682: ascii_tag(fei_ini(date='25/12/2026', time='23:59:59'))},
    'dm-tag-65027': {65027: (1, dm4_file(DM_CASES['tem-image'], bare=True))},
    'plain': {},
}


# ---------------------------------------------------------------------------------------------------------------- Velox EMD
S = h5py.string_dtype()


def velox_md(index, name, dtype_name, extra, optics):
    doc = {'BinaryResult': {'Detector': name, 'DetectorIndex': str(index), 'PixelSize': {'width': '2e-10', 'height': '2e-10'},
                            'Offset': {'x': '0', 'y': '0'}, 'PixelUnitX': 'm', 'PixelUnitY': 'm'},
           'Detectors': {'Detector-0': {'DetectorName': 'HAADF', 'DetectorType': 'ScanningDetector'},
                         'Detector-8': {'DetectorName': 'BM-Ceta', 'DetectorType': 'ImagingDetector', 'ExposureTime': '0.5'},
                         'Detector-5': {'DetectorName': 'SuperXG21', 'DetectorType': 'AnalyticalDetector'}},
           'Acquisition': {'AcquisitionStartDatetime': {'DateTime': '1600000000'}},
           'Scan': {'DwellTime': '1e-05'}, 'Instrument': {'InstrumentModel': 'Talos F200X', 'InstrumentClass': 'Talos'},
           'Optics': optics}
    doc.update(extra)
    raw = json.dumps(doc).encode()
    return np.frombuffer(raw + b'\0' * (8192 - len(raw)), dtype=np.uint8).reshape(8192, 1)


VELOX_TABLE = [{'index': 0, 'name': 'HAADF', 'type': 'ScanningDetector'}, {'index': 8, 'name': 'BM-Ceta', 'type': 'ImagingDetector'},
               {'index': 5, 'name': 'SuperXG21', 'type': 'AnalyticalDetector'}]
VELOX_IMAGES = {
    # name: (detector index, detector name, optics, extra)
    'ceta': (8, 'BM-Ceta', {'AccelerationVoltage': '200000', 'NominalMagnification': '17500', 'CameraLength': '0.844', 'OperatingMode': '1', 'ProjectorMode': '2'},
             {'CustomProperties': {'StemMagnification': {'type': 'bool', 'value': '0'}}}),
    'haadf': (0, 'HAADF', {'AccelerationVoltage': '300000', 'CameraLength': '0.15', 'OperatingMode': '2', 'ProjectorMode': '1'},
              {'CustomProperties': {'StemMagnification': {'type': 'double', 'value': '225000'}},
               'Stage': {'AlphaTilt': '0.087266462599716', 'BetaTilt': '-0.0174532925199433',
                         'Position': {'x': '0.000123456789', 'y': '-5.55555555e-05', 'z': '1.5e-06'}}}),
    'zeros': (0, 'HAADF', {'AccelerationVoltage': '0', 'CameraLength': '0', 'NominalMagnification': '0'}, {}),
}


def write_velox(path):
    with h5py.File(path, 'w') as f:
        f.create_dataset('Version', data=[json.dumps({'version': '11', 'format': 'Velox'})], dtype=S)
        for i, (gid, (idx, name, optics, extra)) in enumerate(VELOX_IMAGES.items()):
            g = f.create_group(f'Data/Image/{gid}')
            g.create_dataset('Data', data=np.arange(6, dtype='<u2').reshape(2, 3, 1) + i, track_times=False)
            g.create_dataset('Metadata', data=velox_md(idx, name, 'u2', extra, optics), track_times=False)


# ---------------------------------------------------------------------------------------------------------------- app harness
def build_harness(td):
    src = td / 'src'; src.mkdir()
    for name in ('AcquisitionMetadata', 'AcquisitionMetadata+DM', 'AcquisitionMetadata+MRC', 'AcquisitionMetadata+TIFF', 'AcquisitionMetadata+Velox', 'GuardedXML', 'CalibratedImage', 'DisplayFileName', 'MRCImageReader', 'TIFFImageReader', 'VeloxImageReader'):
        t = subprocess.check_output(['git', '-C', str(SUITE / 'macTEM'), '--no-optional-locks', 'show', f'{APP}:Sources/TEMCore/Data/{name}.swift'], text=True)
        t = '\n'.join(l for l in t.split('\n') if l.strip() not in ('import FormatoDM', 'import FormatoEMD', 'import FormatoCore'))
        (src / (name.replace('+', '_') + '.swift')).write_text(t)
    (src / 'harness.swift').write_text((HERE / 'harness.swift').read_text())
    exe = td / 'harness'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-package-name', 'app', '-o', str(exe)] + [str(p) for p in sorted(src.iterdir())], check=True)
    return exe


def run_harness(exe, kind, cases, td):
    cp = td / f'{kind}.json'
    cp.write_text(json.dumps(cases))
    return json.loads(subprocess.check_output([str(exe), kind, str(cp)]))


# ---------------------------------------------------------------------------------------------------------------- image readers
def rational_tag(n, d=1): return (5, struct.pack('<II', n, d))
def short_tag(v): return (3, struct.pack('<H', v))


def velox_pixel_xml(x='2.5e-10', y='2.5e-10', xunit='m', yunit='m'):
    return ('<Metadata xmlns="http://schemas.fei.com/Metadata/v1/2013/07"><BinaryResult><PixelSize><X unit="%s">%s</X><Y unit="%s">%s</Y>'
            '</PixelSize></BinaryResult></Metadata>') % (xunit, x, yunit, y)


TIFF_IMAGE_CASES = {
    'velox-agree': {34683: ascii_tag(velox_pixel_xml()), 65450: rational_tag(40000000), 65451: rational_tag(40000000), 65452: short_tag(3)},
    'velox-disagree': {34683: ascii_tag(velox_pixel_xml()), 65450: rational_tag(50000000), 65451: rational_tag(40000000), 65452: short_tag(3)},
    # Velox stores pixels per cm as a float32-rounded integer: the tags agree with the XML within half a count plus half a float32 step.
    'velox-float32-rounded': {34683: ascii_tag(velox_pixel_xml(x='4.46168e-11', y='4.46168e-11')), 65450: rational_tag(int(np.float32(0.01 / 4.46168e-11))), 65451: rational_tag(int(np.float32(0.01 / 4.46168e-11))), 65452: short_tag(3)},
    'velox-xml-only': {34683: ascii_tag(velox_pixel_xml())},
    'velox-nm': {34683: ascii_tag(velox_pixel_xml('0.25', '0.5', 'nm', 'nm'))},
    'velox-mixed-units': {34683: ascii_tag(velox_pixel_xml('2.5e-10', '0.5', 'm', 'nm')), 65450: rational_tag(40000000), 65452: short_tag(3)},
    'velox-zero-x': {34683: ascii_tag(velox_pixel_xml('0', '2.5e-10'))},
    'velox-no-pixel-size': {34683: ascii_tag('<Metadata><BinaryResult/></Metadata>')},
    'velox-refused-xml': {34683: ascii_tag('<!DOCTYPE a [<!ENTITY e "x">]>' + velox_pixel_xml())},
    'velox-and-fei': {34683: ascii_tag(velox_pixel_xml()), 34682: ascii_tag(fei_ini())},
    'plain': {},
}


def axes_records(sig):
    return [{'name': a['name'], 'size': int(a['size']), 'scale': float(a['scale']), 'offset': float(a['offset']),
             'units': a['units'] or '', 'navigate': bool(a['navigate'])} for a in sig['axes']]


def mrc_image(nx=2, ny=2, nz=1, mode=2, payload=None, cella=(2.0, 2.0, 1.0), m=(2, 2, 1), origin=(0., 0., 0.), mapcrs=(1, 2, 3),
              ext=b'', big=False):
    e = '>' if big else '<'
    h = bytearray(1024)
    struct.pack_into(e + '4i', h, 0, nx, ny, nz, mode)
    struct.pack_into(e + '3i', h, 28, *m)
    struct.pack_into(e + '3f', h, 40, *cella)
    struct.pack_into(e + '3i', h, 64, *mapcrs)
    struct.pack_into(e + 'i', h, 92, len(ext))
    struct.pack_into(e + '3f', h, 196, *origin)
    h[208:212] = b'MAP '
    h[212:216] = b'\x11\x11\0\0' if big else b'\x44\x44\0\0'
    return bytes(h) + ext + payload


def f32(values, big=False): return np.array(values, dtype='>f4' if big else '<f4').tobytes()


FEI128 = bytearray(128 * 1024)
struct.pack_into('<f', FEI128, 44, 2.5e-10)
MRC_IMAGE_CASES = {
    'f32-3x2': mrc_image(3, 2, 1, 2, f32([0.5, -1.25, 3, 4, 5, 6]), (30., 20., 1.), (3, 2, 1)),
    'int8-signed': mrc_image(2, 2, 1, 0, bytes([0, 127, 128, 255])),
    'int16': mrc_image(2, 2, 1, 1, np.array([-32768, 0, 1, 32767], '<i2').tobytes()),
    'uint16': mrc_image(2, 2, 1, 6, np.array([0, 1, 65535, 300], '<u2').tobytes()),
    'float16': mrc_image(2, 2, 1, 12, np.array([0.5, -2, 65504, 1e-4], '<f2').tobytes()),
    'complex64': mrc_image(2, 1, 1, 4, np.array([1 + 2j, 3 - 4j], '<c8').tobytes(), m=(2, 1, 1), cella=(2., 1., 1.)),
    'mode-3': mrc_image(2, 2, 1, 3, bytes(8)),
    'stack-3': mrc_image(2, 2, 3, 2, f32(range(12)), (2., 2., 3.), (2, 2, 3)),
    'origin': mrc_image(2, 2, 1, 2, f32([1, 2, 3, 4]), (20., 40., 1.), (2, 2, 1), (20., 40., 5.)),
    'zero-cell': mrc_image(2, 2, 1, 2, f32([1, 2, 3, 4]), (0., 0., 0.), (2, 2, 1)),
    'zero-sampling': mrc_image(2, 2, 1, 2, f32([1, 2, 3, 4]), (2., 2., 1.), (0, 0, 0)),
    'singleton-y': mrc_image(3, 1, 1, 2, f32([1, 2, 3]), (30., 5., 1.), (3, 1, 1)),
    'fei-128': mrc_image(2, 2, 1, 2, f32([1, 2, 3, 4]), ext=bytes(FEI128)),
    'extended-64': mrc_image(2, 2, 1, 2, f32([1, 2, 3, 4]), ext=bytes(64)),
    'big-endian': mrc_image(2, 2, 1, 2, f32([1, 2, 3, 4], big=True), big=True),
    'axis-order': mrc_image(2, 2, 1, 2, f32([1, 2, 3, 4]), mapcrs=(2, 1, 3)),
    'truncated': mrc_image(4, 4, 1, 2, f32([1, 2, 3])),
}

VELOX_TABLE2 = [{'index': 0, 'name': 'HAADF', 'type': 'ScanningDetector'}, {'index': 3, 'name': 'DF4', 'type': 'ImagingDetector'},
                {'index': 5, 'name': 'SuperXG21', 'type': 'AnalyticalDetector'}, {'index': 8, 'name': 'BM-Ceta', 'type': 'ImagingDetector'}]
# id -> (BinaryResult.Detector, DetectorIndex or None, pixel size (w, h) or None, (unit X, unit Y), offset (x, y) or None, dtype)
VELOX_OBJECTS = {
    'a-edx': ('SuperXG21', 5, (2e-10, 2e-10), ('m', 'm'), (0., 0.), 'uint16'),
    'b-df': ('DF4', 3, (2e-10, 2e-10), ('m', 'm'), (0., 0.), 'uint16'),
    'c-haadf': ('HAADF', 0, (2.5e-10, 2.5e-10), ('m', 'm'), (0., 0.), 'uint16'),
    'd-ceta-index-mismatch': ('BM-Ceta', 0, (4e-9, 4e-9), ('m', 'm'), (0., 0.), 'uint16'),
    'e-no-index': ('HAADF', None, (2e-10, 2e-10), ('m', 'm'), (0., 0.), 'uint16'),
    'f-offsets-units': ('DF4', 3, (2e-10, 4e-10), ('m', 'nm'), (1e-9, -2e-9), 'int32'),
    'g-zero-size': ('DF4', 3, (0.0, 2e-10), ('m', 'm'), (0., 0.), 'uint16'),
}


def write_velox_objects(path):
    with h5py.File(path, 'w') as f:
        f.create_dataset('Version', data=[json.dumps({'version': '11', 'format': 'Velox'})], dtype=S)
        for i, (gid, (det, idx, size, units, offset, dtype)) in enumerate(VELOX_OBJECTS.items()):
            binary = {'Detector': det, 'PixelSize': {'width': repr(size[0]), 'height': repr(size[1])},
                      'Offset': {'x': repr(offset[0]), 'y': repr(offset[1])}, 'PixelUnitX': units[0], 'PixelUnitY': units[1]}
            if idx is not None: binary['DetectorIndex'] = str(idx)
            doc = {'BinaryResult': binary, 'Detectors': {f'Detector-{d["index"]}': {'DetectorName': d['name'], 'DetectorType': d['type']} for d in VELOX_TABLE2},
                   'Acquisition': {'AcquisitionStartDatetime': {'DateTime': '1600000000'}}, 'Scan': {'DwellTime': '1e-05'},
                   'Optics': {'AccelerationVoltage': '200000'}, 'Instrument': {'InstrumentModel': 'Talos F200X'}}
            raw = json.dumps(doc).encode()
            g = f.create_group(f'Data/Image/{gid}')
            g.create_dataset('Data', data=(np.arange(6) + i).astype(dtype).reshape(2, 3, 1), track_times=False)
            g.create_dataset('Metadata', data=np.frombuffer(raw + b'\0' * (8192 - len(raw)), dtype=np.uint8).reshape(8192, 1), track_times=False)


def images_part(exe, td, pins):
    # TIFF Velox calibration
    d = ROOT / 'Tests/FormatoTIFFTests/Fixtures/image-readers'; d.mkdir(parents=True, exist_ok=True)
    cases = []
    for name, extra in TIFF_IMAGE_CASES.items():
        path = d / f'{name}.tif'
        path.write_bytes(tiff_file(extra))
        sig = tiff_reader(str(path))[0]
        cases.append({'name': name, 'path': str(path), 'reference': {'axes': axes_records(sig), 'shape': list(sig['data'].shape)}})
    app = run_harness(exe, 'tiffimage', cases, td)
    for c in cases: c['app'] = app[c['name']]; del c['path']
    (d / 'pins.json').write_text(json.dumps({**pins, 'cases': cases}, indent=1, sort_keys=True) + '\n')

    # MRC images
    d = ROOT / 'Tests/FormatoMRCTests/Fixtures/image-readers'; d.mkdir(parents=True, exist_ok=True)
    cases = []
    for name, data in MRC_IMAGE_CASES.items():
        path = d / f'{name}.mrc'
        path.write_bytes(data)
        try:
            sig = mrc_reader(str(path))[0]
            ref = {'shape': list(sig['data'].shape), 'dtype': sig['data'].dtype.name, 'axes': axes_records(sig),
                   'data_hex': np.ascontiguousarray(sig['data']).astype(sig['data'].dtype.newbyteorder('<')).tobytes().hex()}
        except Exception as e:
            ref = {'error': type(e).__name__}
        cases.append({'name': name, 'path': str(path), 'reference': ref})
    app = run_harness(exe, 'mrcimage', cases, td)
    for c in cases: c['app'] = app[c['name']]; del c['path']
    (d / 'pins.json').write_text(json.dumps({**pins, 'cases': cases}, indent=1, sort_keys=True) + '\n')

    # Velox object rule and axes
    d = ROOT / 'Tests/FormatoEMDTests/Fixtures/image-readers'; d.mkdir(parents=True, exist_ok=True)
    write_velox_objects(d / 'velox-objects.emd')
    entries = []
    for gid, (det, idx, size, units, offset, dtype) in VELOX_OBJECTS.items():
        entries.append({'id': gid, 'detectorName': det, 'detectorIndex': idx, 'detectors': VELOX_TABLE2, 'pixelSize': list(size),
                        'pixelUnit': units[0], 'pixelUnitY': units[1], 'offset': list(offset), 'voltage': 200000.0,
                        'width': 3, 'height': 2, 'elementType': dtype})
    subsets = {'all': list(VELOX_OBJECTS), 'without-haadf': [k for k in VELOX_OBJECTS if k != 'c-haadf'],
               'only-edx-and-unindexed': ['a-edx', 'e-no-index'], 'edx-then-df': ['a-edx', 'b-df'], 'none': []}
    cases = [{'name': n, 'ids': ids, 'entries': [e for e in entries if e['id'] in ids]} for n, ids in subsets.items()]
    app = run_harness(exe, 'veloxobjects', cases, td)
    for c in cases: c['app'] = app[c['name']]; del c['entries']
    (d / 'pins.json').write_text(json.dumps({**pins, 'cases': cases, 'entries': entries}, indent=1, sort_keys=True) + '\n')


def main():
    pins = {'rsciio_version': rsciio.__version__, 'reference_commit': PIN, 'app_commit': APP}
    with tempfile.TemporaryDirectory() as tmp:
        td = pathlib.Path(tmp)
        exe = build_harness(td)

        # DM
        cases = []
        for name, items in DM_CASES.items():
            path = OUT['FormatoDM'] / f'{name}.dm4'
            path.write_bytes(dm4_file(items))
            sig = dm_reader(str(path))[0]
            numbers, strings = tag_maps(items)
            cases.append({'name': name, 'numbers': numbers, 'strings': strings, 'reference': reference(sig)})
        app = run_harness(exe, 'dm', cases, td)
        for c in cases: c['app'] = app[c['name']]
        (OUT['FormatoDM'] / 'pins.json').write_text(json.dumps({**pins, 'cases': cases}, indent=1, sort_keys=True) + '\n')

        # MRC
        cases = []
        for name, data in MRC_CASES.items():
            path = OUT['FormatoMRC'] / f'{name}.mrc'
            path.write_bytes(data)
            sig = mrc_reader(str(path))[0]
            ref = {}
            for t, v in apply_mapping(sig).items():
                k = target_key(t)
                if k in ('magnification', 'exposure'):
                    ref[k] = float(np.asarray(v).reshape(-1)[0])  # RosettaSciIO keeps one value per section; the first is read
            cases.append({'name': name, 'path': str(path), 'reference': ref})
        app = run_harness(exe, 'mrc', cases, td)
        for c in cases: c['app'] = app[c['name']]; del c['path']
        (OUT['FormatoMRC'] / 'pins.json').write_text(json.dumps({**pins, 'cases': cases}, indent=1, sort_keys=True) + '\n')

        # TIFF
        cases = []
        for name, extra in TIFF_CASES.items():
            path = OUT['FormatoTIFF'] / f'{name}.tif'
            path.write_bytes(tiff_file(extra))
            ref = {}
            if name.startswith('fei'):
                sig = tiff_reader(str(path))[0]
                ref = reference(sig)
            elif name.startswith('velox'):
                # No RosettaSciIO plugin reads tag 34683: the EMD mapping's lambdas (emd/_emd_velox.py:938-945) on the XML values.
                import re
                x = extra[34683][1].decode()
                v = lambda tagname: re.search('<%s>([^<]*)</%s>' % (tagname, tagname), x).group(1)
                ref = {'beam_energy': float(v('AccelerationVoltage')) / 1e3, 'camera_length': float(v('CameraLength')) * 1e3}
            cases.append({'name': name, 'path': str(path), 'reference': ref})
        app = run_harness(exe, 'tiff', cases, td)
        for c in cases: c['app'] = app[c['name']]; del c['path']
        (OUT['FormatoTIFF'] / 'pins.json').write_text(json.dumps({**pins, 'cases': cases}, indent=1, sort_keys=True) + '\n')

        # Velox EMD
        path = OUT['FormatoEMD'] / 'velox-acquisition.emd'
        write_velox(path)
        sigs = emd_reader(str(path))
        cases = []
        by_title = {s['metadata']['General'].get('title'): s for s in sigs}
        for gid, (idx, name, optics, extra) in VELOX_IMAGES.items():
            sig = by_title.get(name) if name != 'HAADF' else None
            cases.append({'name': gid, 'id': gid, 'detectorName': name, 'detectorIndex': idx, 'detectors': VELOX_TABLE, 'binaryResultDetector': name,
                          'instrumentModel': 'Talos F200X', 'acquisitionStartUnixTime': 1600000000.0, 'dwellTimeSeconds': 1e-05,
                          'accelerationVoltageVolts': float(optics['AccelerationVoltage'])})
        # RosettaSciIO names images by Operations or DetectorIndex; read each image group's mapping by its file order.
        titles = [s['metadata']['General'].get('title') for s in sigs]
        for gid, s in zip(VELOX_IMAGES, sigs):
            for c in cases:
                if c['name'] == gid:
                    c['reference'] = reference(s)
                    c['rsciio_title'] = s['metadata']['General'].get('title')
        app = run_harness(exe, 'velox', cases, td)
        for c in cases: c['app'] = app[c['name']]
        (OUT['FormatoEMD'] / 'acq-pins.json').write_text(json.dumps({**pins, 'cases': cases}, indent=1, sort_keys=True) + '\n')

        images_part(exe, td, pins)


main()

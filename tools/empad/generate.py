"""Run from FormatoKit with References/venv/bin/python -I -B tools/empad/generate.py."""
import gzip, json, pathlib, subprocess, tempfile
import numpy as np
import rsciio
from rsciio.empad import file_reader
ROOT = pathlib.Path(__file__).resolve().parents[2]
REF = ROOT / 'References/rosettasciio-049e7d70'
PIN = '049e7d7070e84779b499adaf3295beee9facb004'
assert subprocess.check_output(['git', '-C', str(REF), 'rev-parse', 'HEAD'], text=True).strip() == PIN
assert rsciio.__version__ == '0.14.1.dev96+g049e7d707'
OUT = ROOT / 'Tests/FormatoEMPADTests/Fixtures'
# Repeated rows compress well; unique frame, row and column probes expose transposition and footer leakage.
raw = np.zeros((2, 3, 130, 128), dtype='<f4')
for y in range(2):
    for x in range(3):
        raw[y,x,:128,0] = np.arange(128) + (y*3+x)*256
        raw[y,x,:128,1] = -0.0
        raw[y,x,:128,127] = (y*3+x)+0.125
        raw[y,x,128:,:] = -9999
raw[0,0,0,2] = np.nan
raw[0,0,0,3] = np.inf
cases = {
 'legacy': ('<pix_x>3</pix_x><pix_y>2</pix_y>', '<optics><get_full_scan_field_of_view>[6e-9,\n12e-9]</get_full_scan_field_of_view></optics><calibrated_pixelsize>3.315e-10</calibrated_pixelsize>', {}),
 'modern': ('<reconstructions><reconstruction>first</reconstruction><reconstruction>last</reconstruction></reconstructions><scan_parameters mode="search"><scan_resolution_x>9</scan_resolution_x></scan_parameters><scan_parameters mode="acquire"><scan_resolution_x>3</scan_resolution_x></scan_parameters>', '<full_scan_field_of_view><x>2.16e-8</x><y>2.16e-8</y><scale_factor>0.72</scale_factor></full_scan_field_of_view>', {}),
 'override': ('<pix_x>3</pix_x><pix_y>2</pix_y>', '<calibrated_pixelsize>7e-10</calibrated_pixelsize>', {'q_calibration':0.3315}),
 'series': ('<scan_parameters><series_count>6</series_count></scan_parameters>', '', {}),
 'singleton': ('<pix_x>1</pix_x><pix_y>6</pix_y>', '', {}),
}
pins = {'reference_commit':PIN, 'rsciio_version':rsciio.__version__, 'cases':[]}
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    (tmp/'scan_x3_y2.raw').write_bytes(raw.tobytes())
    (OUT/'scan_x3_y2.raw.gz').write_bytes(gzip.compress(raw.tobytes(), mtime=0))
    for name,(shape,cal,options) in cases.items():
        xml = f'<root><raw_file filename="scan_x3_y2.raw"/>{shape}<timestamp><isoformat>2026-01-02T03:04:05</isoformat></timestamp><iom_measurements>{cal}</iom_measurements></root>'
        (tmp/f'{name}.xml').write_text(xml)
        (OUT/f'{name}.xml').write_text(xml)
        s = file_reader(str(tmp/f'{name}.xml'), **options)[0]
        (OUT/f'{name}.data.gz').write_bytes(gzip.compress(s['data'].tobytes(), mtime=0))
        pins['cases'].append({'name':name,'shape':list(s['data'].shape),'axes':s['axes'],'metadata':s['metadata'],'options':options})
(OUT/'pins.json').write_text(json.dumps(pins, indent=2)+'\n')

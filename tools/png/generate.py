"""Writes Tests/FormatoCoreTests/Fixtures/png/input.png: a small RGB PNG made by Pillow (an encoder that is not ours), the input of
the oracle (tools/png/oracle.sh) and of the insertion tests.

  <suite>/References/FormatoKit/rsciio-venv/bin/python -I -B tools/png/generate.py
"""
import pathlib
import numpy as np
from PIL import Image

FIX = pathlib.Path(__file__).resolve().parents[2] / 'Tests/FormatoCoreTests/Fixtures/png'
FIX.mkdir(parents=True, exist_ok=True)
w, h = 4, 3
px = np.array([[[(x * 37 + y * 91 + c * 53 + 7) % 256 for c in range(3)] for x in range(w)] for y in range(h)], dtype=np.uint8)
Image.fromarray(px, 'RGB').save(FIX / 'input.png')
print('wrote', FIX / 'input.png')

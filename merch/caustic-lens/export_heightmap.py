#!/usr/bin/env python3
"""
Export the Zeroman lens height field as a 16-bit-encoded PNG (height packed into
R,G) plus a JSON of the physical parameters, for the WebGL simulator in web/.

Re-runs the exact transport used for out_zeroman (deterministic), so the texture
and the shipped STL describe the same surface.
"""
import json, os, numpy as np
from PIL import Image
import caustic_lens as cl

# identical parameters to the committed out_zeroman lens
N, L, D, NIDX, BASE = 512, 120.0, 264.0, 1.51, 3.0
IMG, INVERT, BLUR, FLOOR, ITERS = 'target_zeroman_src.png', True, 1.2, 0.04, 110

here = os.path.dirname(os.path.abspath(__file__))
os.chdir(here)
tgt = cl.prepare_target(IMG, N, INVERT, BLUR, FLOOR, None)
Phi = cl.solve_transport(tgt, L, ITERS, 0.8, verbose=False)
h = cl.heights_from_potential(Phi, NIDX, D)          # already min-shifted to 0
hmin, hmax = float(h.min()), float(h.max())
rng = max(hmax - hmin, 1e-9)

# pack normalized height into 16 bits across R (high) and G (low)
q = np.clip((h - hmin) / rng, 0, 1)
u16 = np.round(q * 65535).astype(np.uint32)
rgb = np.zeros((N, N, 3), np.uint8)
rgb[..., 0] = (u16 >> 8) & 0xFF
rgb[..., 1] = u16 & 0xFF
Image.fromarray(rgb).save('web/heightmap.png')

meta = dict(N=N, size_mm=L, throw_mm=D, ior=NIDX, base_mm=BASE,
            relief_mm=rng, height_min_mm=hmin, height_max_mm=hmax)
json.dump(meta, open('web/lens.json', 'w'), indent=2)
print(json.dumps(meta, indent=2))
print('wrote web/heightmap.png + web/lens.json')

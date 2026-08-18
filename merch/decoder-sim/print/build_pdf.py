#!/usr/bin/env python3
"""
Exact-dimension, print-ready PDFs for the Nearfield decoder sticker + cling,
formatted for the StickerYou "custom die-cut PDF" uploader.

deps:  reportlab, pillow   (pip install reportlab pillow)

Why PDF (not the drag-in-editor flow): the die-cut PDF path is a true vector
die-line workflow — the PDF's own dimensions ARE the print dimensions and the
art + cut line scale as one locked unit. That is what makes the barrier decoder
register: the sticker's interlaced text-band pitch and the cling's bar pitch are
derived from the SAME physical pitch, to the micron.

Outputs (written next to this script, in print/):
  sticker.pdf : RASTER. dark topo field + 3-frame interlaced text (logotype /
                SUMMER 2026 / HERMON PARK · LOS ANGELES) at 600 dpi, full-bleed,
                with a closed rounded-rect 'DieLine' spot-colour cut path.
  cling.pdf   : VECTOR. the 1/3-duty barrier bars drawn as exact rectangles at
                the matched physical pitch (crisper + dimensionally exact than a
                raster), same 'DieLine' spot-colour cut path.
  reveal_logotype.png / reveal_date.png / reveal_location.png :
                registration proof — the cling bars overlaid on the real sticker
                at each of the three P/3 phase offsets, so you can see the reveal
                actually lands before ordering a print.

StickerYou checklist compliance:
  - one page each                                     [ok]
  - one closed die-cut path, Stroke not Fill          [ok: roundRect stroke]
  - die path uses a Spot Colour named 'DieLine'       [ok: CMYKColor spotName]
  - no other object uses that spot colour             [ok]
  - >= 300 dpi                                         [ok: 600 dpi raster]
  - < 25 MB                                            [checked at end]
  - 1/16" (1.58mm) bleed + 1/16" safe area            [ok: die-line inset 1/16"]
"""
import os
import numpy as np
from PIL import Image
from reportlab.pdfgen import canvas
from reportlab.lib.colors import CMYKColorSep, Color

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- master print spec (everything derives from these) ---------------------
DPI       = 600
PT        = 72.0            # points per inch
BLEED_IN  = 1.0 / 16.0      # 0.0625" = 1.58 mm  (StickerYou spec)
PITCH_PX  = 72             # export pitch @600dpi -> 0.12" period
SLIT_PX   = 24             # P/3 clear slit
# LIGHT theme: black-on-white sticker; cling bars are WHITE (== the paper ground)
# so they vanish into it and only the revealed frame's black ink shows through the
# clear slits. White bars on clear film => the cling needs WHITE INK printed on a
# CLEAR material (StickerYou "Clear" stickers support this; confirm no unintended
# white flood behind the slits at upload).
GROUND    = (0xf4, 0xf4, 0xf8)   # paper/ground; cling bars MATCH this (white)
CLING_TRIM = (3.70, 1.90)  # inches (trim, before bleed) — slides over the sticker

def _pt(inch): return inch * PT

# Spot colour for the cut contour. MUST be CMYKColorSep (not CMYKColor) — only the
# *Sep subclass triggers reportlab's Separation emission for graphics strokes; a
# plain CMYKColor(spotName=...) silently falls back to process CMYK. Verified: this
# emits page /ColorSpace /DieLine -> [/Separation /DieLine /DeviceCMYK <tint fn>]
# and the stroke op "/DieLine CS 1 SCN". StickerYou reads that named separation as
# the die-line. The CMYK preview value (magenta) is cosmetic; the spot NAME matters.
DIE = CMYKColorSep(0, 1, 0, 0, spotName='DieLine', density=1)


def build_sticker():
    src = os.path.join(HERE, 'sticker.png')
    im = Image.open(src)
    wpx, hpx = im.size
    w_in, h_in = wpx / DPI, hpx / DPI          # full page = trim + bleed ring
    b = BLEED_IN
    trim = (w_in - 2 * b, h_in - 2 * b)
    out = os.path.join(HERE, 'sticker.pdf')
    c = canvas.Canvas(out, pagesize=(_pt(w_in), _pt(h_in)))
    c.drawImage(src, 0, 0, _pt(w_in), _pt(h_in))          # art bleeds to page edge
    c.setStrokeColor(DIE); c.setLineWidth(0.75)           # cut line inset 1/16"
    c.roundRect(_pt(b), _pt(b), _pt(trim[0]), _pt(trim[1]), _pt(0.18), stroke=1, fill=0)
    c.showPage(); c.save()
    return dict(file=out, page_in=(w_in, h_in), trim_in=trim, px=(wpx, hpx))


def build_cling():
    tw, th = CLING_TRIM
    b = BLEED_IN
    w_in, h_in = tw + 2 * b, th + 2 * b
    pitch_in = PITCH_PX / DPI
    slit_in  = SLIT_PX / DPI
    bar_in   = (PITCH_PX - SLIT_PX) / DPI
    out = os.path.join(HERE, 'cling.pdf')
    c = canvas.Canvas(out, pagesize=(_pt(w_in), _pt(h_in)))
    # vector bars, exact pitch. slit [x, x+slit) clear; bar [x+slit, x+pitch) inked.
    # bars span the full page height so they bleed under the top/bottom cut.
    c.setFillColor(Color(GROUND[0] / 255, GROUND[1] / 255, GROUND[2] / 255))
    x = 0.0
    while x < w_in:
        bx = x + slit_in
        bw = min(bar_in, w_in - bx)
        if bw > 0:
            c.rect(_pt(bx), 0, _pt(bw), _pt(h_in), fill=1, stroke=0)
        x += pitch_in
    c.setStrokeColor(DIE); c.setLineWidth(0.75)
    c.roundRect(_pt(b), _pt(b), _pt(tw), _pt(th), _pt(0.15), stroke=1, fill=0)
    c.showPage(); c.save()
    return dict(file=out, page_in=(w_in, h_in), trim_in=(tw, th),
                pitch_in=pitch_in, slit_in=slit_in, bar_in=bar_in)


def build_previews():
    """Overlay the exact cling bars on the real sticker at the three P/3 phase
    offsets and crop the central decoder region — a true registration proof."""
    im = np.asarray(Image.open(os.path.join(HERE, 'sticker.png')).convert('RGB'))
    H, W, _ = im.shape
    P, third = PITCH_PX, SLIT_PX
    xs = np.arange(W)
    # central decoder footprint (matches the sim's cling rect proportions)
    cw, ch = int(W * 0.74), int(H * 0.60)
    x0, y0 = (W - cw) // 2, (H - ch) // 2
    names = {0: 'reveal_logotype.png', 1: 'reveal_date.png', 2: 'reveal_location.png'}
    saved = []
    for k, name in names.items():
        off = k * third
        phase = ((xs - off) % P + P) % P
        is_slit = phase < third                        # slit reveals sticker; bar = GROUND
        frame = im.copy()
        bar_cols = ~is_slit
        # paint GROUND over bar columns, but only inside the cling footprint
        region = np.zeros(W, bool); region[x0:x0 + cw] = True
        cols = bar_cols & region
        frame[y0:y0 + ch, cols] = GROUND
        crop = frame[y0:y0 + ch, x0:x0 + cw]
        p = os.path.join(HERE, name)
        Image.fromarray(crop).save(p)
        saved.append(p)
    return saved


def build_cling_qa():
    """White bars are invisible on a white/transparent render, so draw the exact
    cling bars on a mid-grey ground purely so the cling can be eyeballed."""
    tw, th = CLING_TRIM
    b = BLEED_IN
    wpx, hpx = int(round((tw + 2 * b) * DPI)), int(round((th + 2 * b) * DPI))
    arr = np.full((hpx, wpx, 3), 110, np.uint8)          # mid grey ground
    P, slit = PITCH_PX, SLIT_PX
    xs = np.arange(wpx)
    is_bar = ((xs % P) >= slit)                          # bar [slit,P); slit [0,slit)
    arr[:, is_bar] = GROUND                              # white bars
    p = os.path.join(HERE, 'cling_qa.png')
    Image.fromarray(arr).save(p)
    return p


def verify_spot(path):
    """Assert the PDF carries a real 'DieLine' Separation colorspace (not process)."""
    import pikepdf
    pdf = pikepdf.open(path)
    ok = False
    for page in pdf.pages:
        cs = page.get('/Resources', {}).get('/ColorSpace', None)
        if cs is None:
            continue
        for _, v in cs.items():
            if isinstance(v, pikepdf.Array) and str(v[0]) == '/Separation' and str(v[1]) == '/DieLine':
                ok = True
    pdf.close()
    return ok


if __name__ == '__main__':
    s = build_sticker()
    cl = build_cling()
    pv = build_previews()
    qa = build_cling_qa()
    sc = Image.open(os.path.join(HERE, 'sticker.png')).convert('RGB')
    center = sc.getpixel((sc.width // 2, sc.height // 2))
    print('sticker.png center pixel:', center, '(dark ground ~ (8,8,12) expected)')
    print()
    print('STICKER pdf :', os.path.basename(s['file']))
    print('   page  : %.3f x %.3f in  (%d x %d px @ %d dpi)' %
          (s['page_in'][0], s['page_in'][1], s['px'][0], s['px'][1], DPI))
    print('   trim  : %.3f x %.3f in  (die-line, 1/16" bleed all sides)' % s['trim_in'])
    print('   size  : %.2f MB' % (os.path.getsize(s['file']) / 1e6))
    print()
    print('CLING pdf   :', os.path.basename(cl['file']))
    print('   page  : %.3f x %.3f in' % cl['page_in'])
    print('   trim  : %.3f x %.3f in' % cl['trim_in'])
    print('   pitch : %.4f in (%.3f mm) | slit %.4f in | bar %.4f in | 1/3 duty' %
          (cl['pitch_in'], cl['pitch_in'] * 25.4, cl['slit_in'], cl['bar_in']))
    print('   size  : %.2f MB' % (os.path.getsize(cl['file']) / 1e6))
    print()
    W = s['px'][0]
    tol = PITCH_PX / (3.0 * W)
    print('scale tolerance (full-width clean reveal): +/- %.2f%%' % (tol * 100))
    print('previews    :', ', '.join(os.path.basename(p) for p in pv + [qa]))
    print()
    for f in (s['file'], cl['file']):
        print('spot-colour DieLine separation in %-12s: %s' %
              (os.path.basename(f), 'PASS' if verify_spot(f) else '** FAIL **'))

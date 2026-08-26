#!/usr/bin/env python3
"""
Build the combined caustic target: the Nearfield topo field (fine glowing contour
lines) with a bold, dominant 2-line "near/field" wordmark composited on top so the
text reads while the topo frames it. Output is bright-on-dark (light concentrates
into the bright parts), ready to feed caustic_lens.py WITHOUT --invert.
"""
import argparse
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import grey_dilation

FONT = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"


def wordmark(W, scale, dilate):
    im = Image.new("L", (W, W), 0); d = ImageDraw.Draw(im)

    def fit(word, maxw):
        s = 520
        while s > 60:
            f = ImageFont.truetype(FONT, s); bb = d.textbbox((0, 0), word, font=f)
            if bb[2] - bb[0] < maxw:
                return f, bb
            s -= 4
    for word, cy in [("near", 0.32), ("field", 0.68)]:
        f, bb = fit(word, W * scale)
        x = (W - (bb[2] - bb[0])) // 2 - bb[0]
        y = int(W * cy) - (bb[3] - bb[1]) // 2 - bb[1]
        d.text((x, y), word, fill=255, font=f)
    return grey_dilation(np.asarray(im, float) / 255.0, size=dilate)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--icon", required=True)
    ap.add_argument("--out", default="target_combo.png")
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--topo-weight", type=float, default=0.5, help="topo brightness vs wordmark (=1)")
    ap.add_argument("--word-scale", type=float, default=0.72, help="wordmark width fraction")
    ap.add_argument("--dilate", type=int, default=7)
    args = ap.parse_args()
    W = args.size
    topo = np.asarray(Image.open(args.icon).convert("L").resize((W, W), Image.LANCZOS), float) / 255.0
    topo = 1.0 - topo                                  # invert: contour lines glow
    topo = topo / topo.max()
    word = wordmark(W, args.word_scale, args.dilate)
    combo = np.maximum(topo * args.topo_weight, word)  # wordmark (=1) dominates; topo frames it
    Image.fromarray((np.clip(combo, 0, 1) * 255).astype(np.uint8)).save(args.out)
    print("wrote", args.out)


if __name__ == "__main__":
    main()

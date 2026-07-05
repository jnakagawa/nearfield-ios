#!/usr/bin/env python3
"""Derive the Nearfield scale from the ensemble spectrum via Sethares dissonance curves.

Computes the sensory-dissonance curve of the (stretched) spectrum against itself across
one pseudo-octave, finds the dips, selects scale degrees, and emits config/scale.json
plus a review plot. See docs/superpowers/specs/2026-07-04-crowd-ensemble-design.md §4.2.

Usage: python3 derive_scale.py [--base-freq 220] [--pseudo-octave 2.07]
                               [--ratios 1.0,2.07,3.2,4.4] [--amps 1.0,0.5,0.3,0.2]
"""

import argparse
import json
import math
from pathlib import Path

import numpy as np

# Sethares' parameterization of the Plomp-Levelt roughness curve
# (Tuning, Timbre, Spectrum, Scale, appendix E), min-amplitude weighting.
B1, B2 = 3.5, 5.75
S1, S2, XSTAR = 0.021, 19.0, 0.24

DEFAULT_SPECTRUM = {"ratios": [1.0, 2.07, 3.2, 4.4], "amps": [1.0, 0.5, 0.3, 0.2]}
REGISTERS = {"anchor": -1, "voice": 0, "shimmer": 1}


def pair_dissonance(f1, f2, a1, a2):
    fmin, fmax = (f1, f2) if f1 <= f2 else (f2, f1)
    s = XSTAR / (S1 * fmin + S2)
    d = fmax - fmin
    return min(a1, a2) * (math.exp(-B1 * s * d) - math.exp(-B2 * s * d))


def total_dissonance(freqs, amps):
    total = 0.0
    n = len(freqs)
    for i in range(n):
        for j in range(i + 1, n):
            total += pair_dissonance(freqs[i], freqs[j], amps[i], amps[j])
    return total


def dissonance_curve(spectrum, base_freq, max_ratio, n=4000):
    """Sweep a copy of `spectrum` against itself from unison to max_ratio.

    Returns (cents_array, curve_array)."""
    ratios = np.asarray(spectrum["ratios"], dtype=float)
    amps = np.asarray(spectrum["amps"], dtype=float)
    fixed_f = ratios * base_freq
    alphas = np.geomspace(1.0, max_ratio, n)
    curve = np.empty(n)
    for k, alpha in enumerate(alphas):
        freqs = np.concatenate([fixed_f, fixed_f * alpha])
        a = np.concatenate([amps, amps])
        curve[k] = total_dissonance(freqs, a)
    cents = 1200.0 * np.log2(alphas)
    return cents, curve


def find_dips(cents, curve, min_separation_cents=40.0, min_prominence_frac=0.02):
    """Local minima of the curve, merged within min_separation_cents (keep deeper),
    filtered by prominence relative to curve range. Unison (0 cents) always included;
    the right endpoint is included if the curve is non-increasing into it."""
    rng = float(curve.max() - curve.min())
    minima = []  # (cents, value)
    for i in range(1, len(curve) - 1):
        if curve[i] < curve[i - 1] and curve[i] <= curve[i + 1]:
            left_peak = curve[: i + 1].max()
            right_peak = curve[i:].max()
            prominence = min(left_peak, right_peak) - curve[i]
            if prominence >= min_prominence_frac * rng:
                minima.append((float(cents[i]), float(curve[i])))
    if curve[-1] <= curve[-2]:
        minima.append((float(cents[-1]), float(curve[-1])))

    merged = []
    for c, v in sorted(minima):
        if merged and c - merged[-1][0] < min_separation_cents:
            if v < merged[-1][1]:
                merged[-1] = (c, v)
        else:
            merged.append((c, v))

    dips = [0.0] + [c for c, _ in merged if c > 1.0]
    return dips


def derive(spectrum, base_freq, pseudo_octave, max_degrees=7, min_degrees=4):
    pseudo_cents = 1200.0 * math.log2(pseudo_octave)
    cents, curve = dissonance_curve(spectrum, base_freq, max_ratio=pseudo_octave)

    prominence = 0.02
    dips = find_dips(cents, curve, min_prominence_frac=prominence)
    # Interior degrees exclude the pseudo-octave itself (it is the register wrap).
    interior = [d for d in dips if d < pseudo_cents - 1.0]
    while len(interior) < min_degrees and prominence > 1e-4:
        prominence /= 2.0
        dips = find_dips(cents, curve, min_prominence_frac=prominence)
        interior = [d for d in dips if d < pseudo_cents - 1.0]

    if len(interior) > max_degrees:
        # Keep unison plus the deepest dips.
        def depth(c):
            idx = int(np.argmin(np.abs(cents - c)))
            return curve[idx]

        rest = sorted(interior[1:], key=depth)[: max_degrees - 1]
        interior = [0.0] + sorted(rest)

    return {
        "version": 1,
        "base_freq_hz": float(base_freq),
        "spectrum": spectrum,
        "pseudo_octave_ratio": float(pseudo_octave),
        "scale_cents": [round(c, 1) for c in interior],
        "dip_intervals_cents": [round(c, 1) for c in dips],
        "registers": REGISTERS,
    }


def plot(cents, curve, result, out_path):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(11, 5))
    ax.plot(cents, curve, lw=1.2, color="#333")
    for c in result["dip_intervals_cents"]:
        ax.axvline(c, color="#bbb", ls="--", lw=0.7, zorder=0)
    for c in result["scale_cents"]:
        ax.axvline(c, color="#c0392b", lw=1.4, alpha=0.8)
    ax.set_xlabel("interval (cents)")
    ax.set_ylabel("sensory dissonance (Sethares)")
    ratios = ", ".join(f"{r:g}" for r in result["spectrum"]["ratios"])
    ax.set_title(
        f"Nearfield spectrum [{ratios}] @ {result['base_freq_hz']:g} Hz — "
        f"red = scale degrees, dashed = all dips"
    )
    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=150)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--base-freq", type=float, default=220.0)
    p.add_argument("--pseudo-octave", type=float, default=2.07)
    p.add_argument("--ratios", default=None, help="comma-separated partial ratios")
    p.add_argument("--amps", default=None, help="comma-separated partial amplitudes")
    args = p.parse_args()

    spectrum = dict(DEFAULT_SPECTRUM)
    if args.ratios:
        spectrum["ratios"] = [float(x) for x in args.ratios.split(",")]
    if args.amps:
        spectrum["amps"] = [float(x) for x in args.amps.split(",")]

    result = derive(spectrum, args.base_freq, args.pseudo_octave)

    here = Path(__file__).resolve().parent
    config_path = here.parent / "config" / "scale.json"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(result, indent=2) + "\n")

    cents, curve = dissonance_curve(spectrum, args.base_freq, args.pseudo_octave)
    plot(cents, curve, result, here / "plots" / "dissonance_curve.png")

    print(f"scale_cents: {result['scale_cents']}")
    print(f"dip_intervals_cents: {result['dip_intervals_cents']}")
    print(f"wrote {config_path} and plots/dissonance_curve.png")


if __name__ == "__main__":
    main()

import math

from derive_scale import pair_dissonance, dissonance_curve, find_dips, derive, sweep

HARMONIC = {"ratios": [1.0, 2.0, 3.0, 4.0], "amps": [1.0, 0.5, 0.3, 0.2]}
STRETCHED = {"ratios": [1.0, 2.07, 3.2, 4.4], "amps": [1.0, 0.5, 0.3, 0.2]}


def _has_dip_near(dips_cents, target, tol=20):
    return any(abs(d - target) <= tol for d in dips_cents)


def test_pair_dissonance_zero_at_unison_and_far():
    assert pair_dissonance(440, 440, 1, 1) < 1e-9
    assert pair_dissonance(440, 2000, 1, 1) < 0.01


def test_pair_dissonance_peaks_in_between():
    near = pair_dissonance(440, 460, 1, 1)  # roughness zone
    assert near > pair_dissonance(440, 441, 1, 1)
    assert near > pair_dissonance(440, 700, 1, 1)


def test_harmonic_spectrum_recovers_fifth_and_octave():
    cents, curve = dissonance_curve(HARMONIC, 220.0, max_ratio=2.0)
    dips = find_dips(cents, curve)
    assert _has_dip_near(dips, 702)  # perfect fifth
    assert _has_dip_near(dips, 1200)  # octave


def test_stretched_spectrum_has_pseudo_octave_dip():
    pseudo = 1200 * math.log2(2.07)  # ~1259 cents
    cents, curve = dissonance_curve(STRETCHED, 220.0, max_ratio=2.07)
    dips = find_dips(cents, curve)
    assert _has_dip_near(dips, pseudo)


def test_derive_output_schema():
    out = derive(STRETCHED, base_freq=220.0, pseudo_octave=2.07)
    assert out["version"] == 1
    assert out["base_freq_hz"] == 220.0
    # A <=4-partial spectrum has few coincidence intervals (spec §2.3); this
    # spectrum yields exactly 4 interior dips, which is the scale.
    assert 4 <= len(out["scale_cents"]) <= 7
    assert out["scale_cents"][0] == 0
    assert out["scale_cents"] == sorted(out["scale_cents"])
    pseudo_cents = 1200 * math.log2(2.07)
    assert all(0 <= c < pseudo_cents + 1 for c in out["scale_cents"])
    assert out["dip_intervals_cents"][0] == 0
    assert out["registers"] == {"anchor": -1, "voice": 0, "shimmer": 1}
    assert out["spectrum"] == STRETCHED
    assert out["pseudo_octave_ratio"] == 2.07


def test_sweep_rows_aligned_and_consistent():
    rows = sweep(STRETCHED, 220.0, 2.04, 2.10, 7)
    assert len(rows) == 7
    n_deg = len(rows[0]["scale_cents"])
    n_dip = len(rows[0]["dip_intervals_cents"])
    assert all(len(r["scale_cents"]) == n_deg for r in rows)
    assert all(len(r["dip_intervals_cents"]) == n_dip for r in rows)
    for r in rows:
        # partial 2 tracks the stretch; upper partials scale proportionally
        assert abs(r["spectrum"]["ratios"][1] - r["stretch"]) < 1e-9
        assert r["scale_cents"] == sorted(r["scale_cents"])
        assert r["scale_cents"][0] == 0
        # last dip is the pseudo-octave for that stretch
        assert abs(r["dip_intervals_cents"][-1] - 1200 * math.log2(r["stretch"])) < 1.0
    # middle row is the canonical 2.07 tuning
    mid = rows[3]
    assert abs(mid["stretch"] - 2.07) < 1e-9
    base = derive(STRETCHED, base_freq=220.0, pseudo_octave=2.07)
    for a, b in zip(mid["scale_cents"], base["scale_cents"]):
        assert abs(a - b) < 1.0
    # degrees move continuously between adjacent rows (interpolable)
    for r0, r1 in zip(rows, rows[1:]):
        for a, b in zip(r0["scale_cents"], r1["scale_cents"]):
            assert abs(a - b) < 40

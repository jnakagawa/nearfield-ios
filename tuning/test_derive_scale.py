import math

from derive_scale import pair_dissonance, dissonance_curve, find_dips, derive

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

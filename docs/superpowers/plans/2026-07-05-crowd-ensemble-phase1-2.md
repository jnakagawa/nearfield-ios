# Nearfield v2 Phases 1–2 Implementation Plan (Derive + Simulate)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the scale-derivation script and the browser simulator so the piece can be auditioned and tuned end-to-end (spec §4.2, §7; phases 1–2 of §10).

**Architecture:** A standalone Python script derives the dissonance-curve scale and writes `config/scale.json` + plots. A single-file `simulator/index.html` embeds a pure-logic core (`<script id="nearfield-core">` — params, BLE bucket/encounter pipeline, reward model, role assignment) that a Node test extracts and exercises headlessly; UI/canvas/Web Audio wrap that core. Configs flow: derive → scale.json → simulator (fetch with embedded fallback) → exported params.json.

**Tech Stack:** Python 3 + numpy + matplotlib (both installed; pytest 9 for tests). Vanilla JS + Web Audio + canvas, zero build step. Node 23 built-in `node:test` for headless logic tests.

**Spec:** `docs/superpowers/specs/2026-07-04-crowd-ensemble-design.md` — §5 constants are normative; the simulator core must implement them verbatim.

---

## File map

- Create: `tuning/derive_scale.py` — Sethares curve, dip finding, scale selection, JSON + plot emission
- Create: `tuning/test_derive_scale.py` — pytest
- Create: `config/scale.json` — generated (committed)
- Create: `tuning/plots/dissonance_curve.png` — generated (committed)
- Create: `config/params.json` — §5/§6.3/§7.3 defaults (hand-written, matches spec tables)
- Create: `simulator/index.html` — the simulator (single file)
- Create: `simulator/tests/core.test.mjs` — extracts `nearfield-core` script block, runs logic tests
- Modify: `README.md` — v2 section: spec link, how to run the simulator
- Branch: continue on `design/crowd-ensemble`

---

### Task 1: Scale derivation script (TDD)

**Files:** Create `tuning/derive_scale.py`, `tuning/test_derive_scale.py`

- [ ] **Step 1: Write failing tests**

```python
# tuning/test_derive_scale.py
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
    near = pair_dissonance(440, 460, 1, 1)   # ~roughness zone
    assert near > pair_dissonance(440, 441, 1, 1)
    assert near > pair_dissonance(440, 700, 1, 1)

def test_harmonic_spectrum_recovers_fifth_and_octave():
    cents, curve = dissonance_curve(HARMONIC, 220.0, max_ratio=2.0)
    dips = find_dips(cents, curve)
    assert _has_dip_near(dips, 702)   # perfect fifth
    assert _has_dip_near(dips, 1200)  # octave

def test_stretched_spectrum_has_pseudo_octave_dip():
    pseudo = 1200 * math.log2(2.07)   # ≈ 1259 cents
    cents, curve = dissonance_curve(STRETCHED, 220.0, max_ratio=2.07)
    dips = find_dips(cents, curve)
    assert _has_dip_near(dips, pseudo)

def test_derive_output_schema():
    out = derive(STRETCHED, base_freq=220.0, pseudo_octave=2.07)
    assert out["version"] == 1
    assert out["base_freq_hz"] == 220.0
    assert 5 <= len(out["scale_cents"]) <= 7
    assert out["scale_cents"][0] == 0
    assert all(0 <= c < 1200 * math.log2(2.07) + 1 for c in out["scale_cents"])
    assert out["dip_intervals_cents"][0] == 0
    assert out["registers"] == {"anchor": -1, "voice": 0, "shimmer": 1}
```

- [ ] **Step 2: Run to verify failure** — `cd tuning && python3 -m pytest test_derive_scale.py -v` → ImportError.

- [ ] **Step 3: Implement**

Core math (Sethares' canonical `dissmeasure`, min-amplitude weighting):

```python
def pair_dissonance(f1, f2, a1, a2):
    B1, B2, S1, S2, XSTAR = 3.5, 5.75, 0.021, 19.0, 0.24
    fmin, fmax = (f1, f2) if f1 <= f2 else (f2, f1)
    s = XSTAR / (S1 * fmin + S2)
    d = fmax - fmin
    return min(a1, a2) * (math.exp(-B1 * s * d) - math.exp(-B2 * s * d))
```

`dissonance_curve(spectrum, base_freq, max_ratio, n=4000)`: for each alpha in
`geomspace(1, max_ratio, n)`, combine partials of spectrum at `base_freq` and at
`alpha*base_freq` into one list, sum `pair_dissonance` over all pairs; return
(cents_array, curve_array), cents = `1200*log2(alpha)`.

`find_dips(cents, curve)`: local minima (strictly lower than both neighbors) plus the
endpoint at max_ratio if curve is non-increasing into it; merge minima closer than 40
cents keeping the deeper; drop dips shallower than 2% of curve range (noise). Return
cents list, always prepending 0.0 (unison).

`derive(spectrum, base_freq, pseudo_octave)`: dips = find_dips(...) over one
pseudo-octave; scale = up to 7 deepest dips in `[0, pseudo_octave_cents)` sorted
ascending (unison always included); if fewer than 5 interior dips exist, lower the
prominence threshold until ≥5 (spectra with 4 partials give ~5–8). Emit dict per spec
§4.2 schema. `main()`: argparse (`--base-freq`, `--pseudo-octave`, ratios/amps
defaults from spec), writes `../config/scale.json` (relative to script), writes
`plots/dissonance_curve.png` (curve + vertical lines at chosen degrees, dashed at all
dips).

- [ ] **Step 4: Run tests** — expected all PASS.
- [ ] **Step 5: Commit** — `feat(tuning): dissonance-curve scale derivation`

### Task 2: Generate committed artifacts

- [ ] **Step 1:** `cd tuning && python3 derive_scale.py` → writes `config/scale.json`, `tuning/plots/dissonance_curve.png`.
- [ ] **Step 2:** Read the PNG; verify dips visually align with marked degrees; verify scale.json has 5–7 degrees, pseudo-octave dip ≈1259.
- [ ] **Step 3:** Commit — `feat(config): generated Nearfield scale (stretched 2.07 spectrum)`

### Task 3: params.json

- [ ] **Step 1:** Write `config/params.json` containing every §5 constant, §5.1 bucket
thresholds/hysteresis/debounce, §5.4 role modifier table, §7.3 BLE noise defaults
(`p0_dbm: -45, path_loss_n: 2.2, shadow_sigma_db: 6, body_block_db: -10,
body_block_rate_per_min: 2, body_block_dur_s: [2,8]`), breath period, and
`tx_offset_by_model: {}` placeholder table (§6.3 — empty until devices measured; the
simulator does not consume it).
- [ ] **Step 2:** Commit — `feat(config): reward-model + BLE parameter defaults`

### Task 4: Simulator core logic (TDD via extracted script block)

**Files:** Create `simulator/index.html` (core block only, page renders "loading"), `simulator/tests/core.test.mjs`

- [ ] **Step 1: Write failing tests** — `core.test.mjs` loads `../index.html`, extracts
`<script id="nearfield-core">…</script>` via regex, `vm.runInNewContext`, then:

```js
// key cases (node:test + assert)
// 1. assignRoles(48) → {anchor: 6, shimmer: 8, voice: 34}, degrees cycle join_index % nDegrees
// 2. BucketTracker hysteresis: feed smoothed RSSI −49 → NEAR; −54 (between exit −56 and enter −50) → stays NEAR; −57 → drops
// 3. Encounter debounce: NEAR for 1.9s → no encounter; ≥2s → active; out-of-NEAR 3.9s → still active; ≥4s → ended
// 4. EMA: step input reaches ~63% at τ
// 5. RewardState: encounter+motion 0.5 → B rises with τ_A≈6s shape toward (g0+gW*W)·(1−β·F) region;
//    45s parked → B ≈ 0.3·peak ±0.1 (habituation); encounter end → E releases τ_rel≈8s
// 6. detuneCents: at E=0 → ±c_start from dip delta; E=1 → 0; no slew when nominal >60c from any dip
// 7. Determinism: same seeded RNG + same inputs → identical trajectories (mulberry32 PRNG)
```

- [ ] **Step 2: Run to verify failure** — `cd simulator && node --test tests/` → fails (no file/objects).

- [ ] **Step 3: Implement core block.** Contents (pure, no DOM/AudioContext references):
`DEFAULT_SCALE` (paste generated scale.json), `DEFAULT_PARAMS` (paste params.json),
`mulberry32(seed)`, `emaAlpha(dt, tau)`, `smoothstep(x)`, `centsBetween(f1, f2)`,
`nearestDip(cents, dips)`, `assignRoles(n, scale)` (round-robin per spec §6.1),
`pitchHzFor(assignment, scale)`, `rssiFromDistance(d, params, rng)` (§7.3 model incl.
body-block events), `class PairSensor` (EMA → hysteresis buckets → encounter debounce;
`update(dt, rawRssi)` → `{bucket, encounterActive}`), `class RewardState`
(`update(dt, {encounters: Map<id,{active}>, motion, peerPitches})` → `{W, B, E, F,
focusId, partialGains:[4], detuneCents, amRate, amDepth}` implementing §5.2–§5.4 with
role modifiers; novelty window tracked internally, 60 s).

- [ ] **Step 4: Run tests** — all PASS.
- [ ] **Step 5: Commit** — `feat(simulator): core logic (BLE pipeline + reward model) with node tests`

### Task 5: Simulator UI, physics, audio

**Files:** Modify `simulator/index.html` (below the core block)

- [ ] **Step 1: Physics + render.** Room 12×8 m on canvas. Agents from `assignRoles`.
Presets (radio buttons): `drift` (Ornstein–Uhlenbeck velocity noise, wall bounce),
`flock` (attract <3 m, repel <0.8 m, plus drift), `dance` (state machine per agent:
pick a partner → approach to <1 m → linger 5–20 s → disperse to random point; per-agent
tempo 0.6–1.6×), `still`. Global speed slider scales all velocities. Motion energy
`m = clamp(speed / 1.4, 0, 1)`. Draw: dots colored by role (anchor deep blue, voice
warm white, shimmer cyan), radius 4+10·B px, encounter edges as lines, draggable agents
and a draggable listener glyph. Sim tick: physics per rAF; sensing+reward at fixed 100 ms
accumulator using PairSensor per (i,j) pair (RSSI symmetric; sensors per direction).

- [ ] **Step 2: Audio.** On START overlay tap: `AudioContext`; per agent ≤4
`OscillatorNode` (freq = pitch·ratio, `osc.detune.value` = model detuneCents) → per-
partial `GainNode` → agent `GainNode` → `StereoPannerNode` → master `GainNode` →
`DynamicsCompressorNode` → destination. Tick applies model outputs with
`setTargetAtTime` (τ 0.08 s); agent gain = roleBaseGain × 1/max(d_listener, 0.6) ×
(1 + amDepth·sin(2π·amRate·t)) × breath(φ) [anchors: swell envelope]. Master volume
slider + mute.

- [ ] **Step 3: Controls.** Param definitions table (name, path, min, max, step) drives
slider generation — groups: Wind, Encounter/Familiarity, Bloom & Partials, Resolution
slew, Breath, BLE model (+ **Ideal sensing** checkbox bypassing noise), Movement.
Scene A/B: two param snapshots, toggle button. `Export params.json` → Blob download.
Stats bar: n agents, active encounters, mean B, mean W. Config loading: `fetch('../config/scale.json')`
and `params.json` when served over http; embedded defaults on `file://`.

- [ ] **Step 4: Re-run node tests** (core block untouched but re-verify extraction) — PASS.
- [ ] **Step 5: Commit** — `feat(simulator): room physics, Web Audio ensemble, tuning controls`

### Task 6: Browser smoke test

- [ ] **Step 1:** `python3 -m http.server 8123` (background, repo root); Chrome →
`http://localhost:8123/simulator/index.html`.
- [ ] **Step 2:** Click START; verify: no console errors; `dance` preset produces
active encounters within ~30 s; oscillator/agent counts match slider; A/B toggle and
Export download work; screenshot for the handoff note.
- [ ] **Step 3:** Fix anything found; re-run node tests; commit fixes.

### Task 7: README + wrap-up

- [ ] **Step 1:** Add "v2 — Leaves in the Wind (in progress)" section to `README.md`:
one-paragraph concept, spec/plan links, `how to try the simulator` (open
`simulator/index.html`, or `python3 -m http.server` for live configs), test commands
(`python3 -m pytest tuning/`, `node --test simulator/tests/`).
- [ ] **Step 2:** Commit — `docs: v2 section + simulator instructions`

---

## Self-review notes

- Spec coverage: §4.2 → Tasks 1–2; §6.4 params → Task 3; §5 (all) + §7.3 BLE model →
  Task 4; §7.2–7.3 (audio, presets, sliders, A/B, export, ideal toggle) → Task 5;
  fixtures for Swift (§9) are Phase 4 scope — the node tests established here become
  the fixture generator later. Hub (§6.1) and device phases are explicitly out of this
  plan (spec §10 phases 3–5).
- Types consistent: `PairSensor.update(dt, rawRssi)`, `RewardState.update(dt, inputs)`
  used identically in Tasks 4–5; params paths match `config/params.json` keys from
  Task 3.
- No placeholders: the one intentionally empty structure is `tx_offset_by_model: {}`,
  which is device-measurement data the simulator does not consume (documented in Task 3).

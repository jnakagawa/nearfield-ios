# Nearfield v2 — Crowd Ensemble ("Leaves in the Wind")

- **Date:** 2026-07-04
- **Status:** Approved design; implementation not started
- **Scope:** 10–50 phone distributed audio artwork, hub-coordinated, native iOS, with a laptop simulator

## 1. Summary

Nearfield v2 scales the piece from a 2-phone UWB duet to a 10–50 phone ensemble. A hub
(laptop on venue WiFi) assigns each phone a pitch and a role from a scale derived from the
tone's own slightly-stretched spectrum. Proximity to other participants blooms a phone's
sound; staying parked with the same partner gently thins it; movement and new encounters
recharge it. Beating between nearby phones happens physically in the air between speakers —
the artwork lives between people, not in any one device.

A browser-based simulator auditions the full ensemble (agents moving in a virtual room,
same synthesis and same reward model) so the piece can be composed and tuned without
assembling hardware.

The existing 2-phone UWB piece on `main` stays intact as its own intimate mode; v2 is a
separate mode/target, not a rewrite of v1's concept.

## 2. Psychoacoustic basis

From Plomp & Levelt (1965) and Sethares (*Tuning, Timbre, Spectrum, Scale*), five facts
drive the design:

1. **Roughness curve.** Two sine tones beat; perceived roughness peaks at ~25% of the
   critical bandwidth of separation and resolves to consonance at unison and beyond the
   critical band. Distance between people can traverse this curve.
2. **Dissonance curves.** For any spectrum, sweeping a second copy against it and summing
   pairwise sine roughness yields a curve whose *dips* are the consonant intervals for that
   spectrum. Harmonic spectra produce the Western/just intervals; inharmonic spectra
   produce other scales (this is how gamelan tuning arises from its bar spectra).
3. **Partial count = interval vocabulary.** 2 partials → dips only at unison and
   (pseudo-)octave; a 3rd partial adds the fifth-analog; a 4th adds the fourth-analog.
   Fading partials in with proximity therefore changes *which neighbors you are in tune
   with*, not just how rich you sound.
4. **Amplitude moves dip depth, not dip location.** Partial gains can be modulated
   continuously without shifting the tuning logic — proximity-driven fades are safe.
5. **Co-design timbre and tuning.** A scale derived from the ensemble's own spectrum makes
   every pairing able to land on a consonance the tuning actually supports. Nearfield gets
   its own tuning system with pure sine stacks — no gamelan timbre.

## 3. Decisions

| Decision | Choice |
|---|---|
| Ensemble size | 10–50 phones |
| Feel of approach | A dance: rewarded for coming close, and for continuing to move ("leaves in the wind") |
| Pitch assignment | Auto-assigned by hub from the derived scale (no free note choice) |
| Spectrum | Slightly stretched partials (pseudo-octave ≈ 2.07) |
| Coordination | Local hub (laptop on venue WiFi, WebSocket) |
| Distribution | Native iOS via TestFlight beta for the performance |
| Audio engine | Native `AVAudioEngine` (replaces WKWebView/Web Audio for sound) |
| Proximity sense | Mic (Goertzel bank on known partials) + BLE RSSI; UWB/Multipeer dropped in crowd mode |
| Audition tool | Browser simulator, zero build step, shared config with the app |

## 4. Sound system

### 4.1 Spectrum

Each voice is a stack of up to 4 sine partials at stretched ratios. Defaults (all tunable
via `config/scale.json`):

- Ratios: `1.0, 2.07, 3.2, 4.4` (pseudo-octave 2.07)
- Amplitudes: `1.0, 0.5, 0.3, 0.2`
- Base register centered near 220 Hz for the Voice role

Individually a voice still reads as a clean, minimal sine stack. The stretch is small
enough to avoid any metallic/gamelan character while making the derived scale subtly
non-Western.

### 4.2 Scale derivation (offline)

A Python script (`tuning/derive_scale.py`) computes the Sethares dissonance curve of the
spectrum against itself across one pseudo-octave, locates the dips, and selects 5–7 scale
degrees. It emits:

- `config/scale.json` — the machine-readable contract consumed by hub, app, and simulator
- `tuning/plots/` — dissonance-curve plots with chosen degrees marked, committed for review

`scale.json` schema (values below illustrative until the script runs):

```json
{
  "version": 1,
  "base_freq_hz": 220.0,
  "spectrum": { "ratios": [1.0, 2.07, 3.2, 4.4], "amps": [1.0, 0.5, 0.3, 0.2] },
  "pseudo_octave_ratio": 2.07,
  "scale_cents": [0, 187, 356, 552, 764, 951],
  "dip_intervals_cents": [0, 187, 356, 552, 764, 951, 1259],
  "registers": { "anchor": -1, "voice": 0, "shimmer": 1 }
}
```

`scale_cents` are degrees within one pseudo-octave; `dip_intervals_cents` are the raw curve
dips used by the pitch-pull mechanic (§5.3). Registers shift by whole pseudo-octaves.

### 4.3 Roles

Role stratification borrows gamelan's *structure* (cyclic anchors / melody / elaboration),
not its sound:

| Role | Share | Register | Partials | Behavior |
|---|---|---|---|---|
| **Anchor** | ~1 in 8 | −1 pseudo-octave | 2 | Swells on the global breath cycle; barely proximity-reactive; no pitch pull. The gravitational field. |
| **Voice** | remainder | base | up to 3 | Fully proximity- and motion-reactive. The main dance. |
| **Shimmer** | ~1 in 6 | +1 pseudo-octave | up to 4, low gain | Nearly silent when still; partial gains gated by motion. Leaves in the wind. |

The hub assigns roles by join order to hold these ratios and can rebalance live from the
dashboard.

## 5. Dance dynamics (reward model)

The reward model is pure state logic, specified here precisely so the Swift (device) and
JavaScript (simulator) implementations produce identical results from identical inputs.
All constants live in `config/params.json` with the defaults given below; the simulator's
sliders tune them and export the file.

### 5.1 Inputs (per phone *i*, updated at 10–20 Hz)

- **Acoustic proximity** `prox_ij ∈ [0,1]` per audible neighbor *j*.
  - Device: Goertzel amplitude of *j*'s fundamental, mapped through a soundcheck-calibrated
    gain curve (§6.3).
  - Simulator: `prox_ij = clamp((d_ref / max(d_ij, d_min))^p, 0, 1)` with defaults
    `d_ref = 0.8 m`, `d_min = 0.2 m`, `p = 1.5`.
- **Neighbor identity** via BLE RSSI (device) or ground truth (simulator): the set of
  nearby participant IDs, for novelty tracking.
- **Motion energy** `m_i ∈ [0,1]`: `clamp(EMA_τ=1s(|userAcceleration|) / a_max, 0, 1)` with
  `a_max = 0.5 g`, putting a calm walk (~0.25 g RMS) at ≈ 0.5.
- **Novelty** `n_i ∈ [0,1]`: fraction of currently-significant neighbors
  (`prox > 0.3`, or BLE RSSI above `rssi_near = −60 dBm`) not seen in the trailing
  `T_nov = 60 s` window.

### 5.2 State

- **Wind reservoir** `W_i ∈ [0,1]`:
  `dW/dt = α_m·m_i + α_n·n_i − W_i/τ_W`, clamped.
  Defaults: `α_m = 0.15/s`, `α_n = 0.3/s`, `τ_W = 30 s`.
- **Familiarity** `F_ij ∈ [0,1]` per significant neighbor:
  while `prox_ij > 0.5`: `dF/dt = (1−F)/τ_F` (`τ_F = 25 s`);
  otherwise `dF/dt = −F/τ_R` (`τ_R = 45 s`).
- **Focus neighbor** `j* = argmax_j prox_ij`.
- **Bloom** `B_i = prox_ij* · (1 − β·F_ij*) · (g_0 + g_W·W_i)`.
  Defaults: `β = 0.7`, `g_0 = 0.4`, `g_W = 0.6`.
  Net effect: a fresh close encounter with a charged reservoir blooms fully; a parked pair
  decays toward ~30% bloom; moving again (or meeting someone new) restores it.

### 5.3 Sound mapping

- **Partial gains.** Partial *k* (k = 2..4) has target gain
  `amp_k · smoothstep((B − t_k)/w)` with thresholds `t_2 = 0.15`, `t_3 = 0.4`,
  `t_4 = 0.65`, width `w = 0.2`; smoothed with attack 0.5 s / release 3 s. Partial 1 is
  always on. Each role caps its partial count (§5.4), so `t_4` is only reachable by
  Shimmer. Because partial count controls the interval vocabulary (§2.3), blooming
  literally brings you into tune with more of the room.
- **Pitch pull (tension → resolution).** Let `c_ij*` be the sounding interval in cents to
  the focus neighbor and `c*` the nearest entry of `dip_intervals_cents`. If
  `|c* − c_ij*| ≤ 60` cents, detune by `δ · B · (c* − c_ij*)` with `δ = 0.5` (each side
  covers half), capped at ±12 cents, slewed at ≤ 10 cents/s. Approach is heard as beating
  that slows and locks into consonance on arrival. Beyond 60 cents, no pull.
- **Shimmer (AM).** Rate `r = 0.1 + 2.5·m_i` Hz, depth `0.25·W_i`, applied to the voice's
  overall gain. Movement is audible as gentle flutter.
- **Global breath.** Hub clock with period `T_breath = 60 s` (§6.1). Ensemble-wide gain
  multiplier `1 + 0.08·sin(φ)`. Anchors follow a deeper swell `0.5 + 0.5·sin(φ + offset_i)`
  with slow attack, each anchor offset so lows overlap rather than pulse together.

### 5.4 Role modifiers

| | Anchor | Voice | Shimmer |
|---|---|---|---|
| Max partials | 2 | 3 | 4 |
| Bloom input | `B × 0.3` | `B` | `B` |
| Partial gate | fixed 2 partials | as §5.3 | §5.3 gains additionally × `clamp(2·m_i, 0, 1)` |
| Pitch pull | none | full | full |
| Base gain | breath-driven | 1.0 | 0.5 |
| AM depth | ×0.5 | ×1.0 | ×1.5 |

## 6. Architecture

```
Hub (laptop, venue WiFi)
├─ WebSocket server: join → {pitch, role, configs}; broadcasts clock + params
├─ Artist dashboard (web): live field view, role rebalance, scenes, master fade,
│  soundcheck calibration
└─ serves config/scale.json + config/params.json

iPhone app (this repo, new modules alongside v1)
├─ HubClient        — URLSession WebSocket; assignment, clock, live params
├─ VoiceEngine      — AVAudioEngine + AVAudioSourceNode sine stack (≤4 partials)
├─ AcousticSensor   — mic tap on the same engine → Goertzel bank, self-notch
├─ NeighborSensor   — CoreBluetooth advertise + scan, RSSI, duty-cycled
├─ MotionSensor     — CoreMotion user-acceleration energy
├─ RewardModel      — §5 state machine (pure, unit-tested)
└─ SwiftUI          — minimal performance screen: role, pitch, field state

Simulator (browser, zero build step)
└─ simulator/index.html — same scale.json/params.json, same reward model in JS
```

### 6.1 Hub

Single-file Python server (`hub/hub.py`, `websockets` + static file serving) — the repo
already requires Python for `tuning/derive_scale.py`, so this keeps one offline toolchain.
Protocol (JSON over WebSocket):

- `→ join {device_id, name}`
- `← assign {pitch_hz, role, scale, params, clock: {epoch_ms, period_s}}`
- `← params_update {…}` — live tuning from dashboard, applied without rejoin
- `← scene {name}` / `← master {gain}`
- `→ telemetry {W, B, neighbor_count}` at 1 Hz — feeds the dashboard field view

Assignment: roles round-robin to hold §4.3 ratios; pitch degree = `join_index mod
len(scale_cents)` within the role's register. Clock sync: epoch + period with round-trip
offset estimation; drift is irrelevant at 60 s cycles. Phones that lose the hub keep their
last assignment and free-run the clock; rejoin is silent.

### 6.2 Why audio goes native

Mic sensing requires the input tap and the synthesis on one `AVAudioEngine` under a
`.measurement`-mode `AVAudioSession` — otherwise iOS voice processing (echo cancellation,
AGC) attenuates exactly the steady sine partials the Goertzel bank listens for. Native also
removes the JS-bridge latency and the WKWebView lifecycle from the performance-critical
path. The WebView remains only if v2 wants its Three.js visuals; sound never routes
through it.

### 6.3 Sensing details

- **Goertzel bank.** The hub assignment tells every phone the complete set of frequencies
  that can exist in the room (all participants' partials). The sensor runs one Goertzel
  filter per foreign fundamental (~50 filters, trivial CPU at 10–20 Hz update), notching
  out its own partials by construction (they are known exactly). Fundamentals are spaced by
  the scale, so bins don't collide within a register; collisions across registers are
  resolved by register gain weighting.
- **Calibration.** At soundcheck, the dashboard runs a calibration scene: phones take turns
  playing a reference tone at known distances; the amplitude→proximity curve per venue is
  fit and pushed via `params_update`.
- **BLE.** Each phone advertises a service UUID + participant ID and scans duty-cycled
  (e.g., 2 s on / 3 s off). RSSI smoothed with an EMA; used only for identity/novelty, not
  fine proximity.

### 6.4 Config artifacts

- `config/scale.json` — spectrum, scale, registers (§4.2). Generated by `tuning/derive_scale.py`.
- `config/params.json` — every constant in §5 plus role modifier table. Hand-edited or
  exported from the simulator; served by the hub so all clients share one truth.

## 7. Simulator

### 7.1 Purpose

Hear the piece — 10–50 voices, roles, blooms, breath — without hardware, and *tune* it: the
simulator is the composition tool. Every §5 constant is a slider; the result exports as
`params.json`, which the hub then serves to real phones. It is Phase 1, before any device
work, because it gates the aesthetic: if the piece doesn't work in the simulator, no amount
of sensing code saves it.

### 7.2 Requirements

- Single file, `simulator/index.html`, no build step, runs in desktop Chrome/Safari.
- 50 agents × up to 4 partials in real time (≤ ~200 `OscillatorNode`s — comfortably within
  Web Audio limits; if profiling disagrees, cull oscillators whose gain has been < −60 dB
  for > 5 s, and only then consider an AudioWorklet).
- Loads `config/scale.json` and `config/params.json`; falls back to embedded defaults when
  opened via `file://`.
- Implements §5 verbatim; shares golden test fixtures with the Swift implementation (§9).

### 7.3 Design

- **Room:** 2D canvas, agents as dots colored by role, sized by bloom. Drag any agent;
  drag the listener position.
- **Movement presets:** `drift` (random walk), `flock` (attract/repel), `dance`
  (approach → linger → disperse cycles with per-agent tempo), `still` (control case —
  should audibly wilt via habituation). Global movement-rate slider.
- **Audio graph per agent:** up to 4 × (`OscillatorNode` → per-partial `GainNode`) → one
  agent-level `GainNode` → `StereoPannerNode` (pan from x-position relative to listener) →
  master. Distance to the listener sets a 1/d gain law on the agent gain. Digital summing reproduces beating exactly (it is a linear
  mix); what it cannot reproduce is noted in §7.4.
- **Controls:** agent count, role ratios, all §5 params as sliders grouped by section,
  breath period, scene A/B (save two param sets, toggle), `Export params.json`.
- **Fidelity meter:** none — but the UI labels the sim listener as "one ear in the room";
  walking the listener through the field is the intended audition gesture.

### 7.4 Fidelity limits (accepted)

The simulator omits room acoustics, speaker directivity, phone-speaker frequency response,
crowd absorption, and mic-sensing noise; `prox` uses the ideal law of §5.1. It answers
"does the composition work?", not "will sensing be robust?" — the latter is Phase 3's
device-ladder question.

## 8. Failure handling (device)

- Hub unreachable → keep last assignment, free-run clock, silent rejoin loop.
- Mic permission denied or input dead → BLE-only proximity (coarse but functional); warn on
  the performance screen.
- Loud venue → Goertzel thresholds recalibrated from the dashboard (§6.3).
- Audio session interruption (call, Siri, route change) → standard interruption handling,
  auto-resume within 2 s.
- Battery → dimmed performance screen, duty-cycled BLE, no display updates above 10 Hz.

## 9. Testing

- **Tuning:** derivation script commits its dissonance-curve plots; reviewer eyeballs dips
  vs chosen degrees.
- **Reward model:** golden fixture file (input time-series → expected `W/F/B/gains`
  trajectories) checked into `config/fixtures/`; Swift and JS test suites both replay it
  and must match within tolerance (1e-3).
- **Goertzel bank:** unit-tested against synthesized WAV fixtures (known partials + pink
  noise at graded SNR).
- **Integration:** simulator is the aural integration test; a device debug panel fakes
  sensor inputs so the full loop runs in the iOS simulator.
- **Device ladder:** 3 phones → 10 phones → dress rehearsal with venue soundcheck.

## 10. Build phases

1. **Derive** — `tuning/derive_scale.py` → `scale.json` + plots.
2. **Simulate** — `simulator/index.html`; compose and tune until the piece sounds right;
   export `params.json`. *Aesthetic gate: do not proceed until the sim version is good.*
3. **Hum** — hub server + `HubClient` + `VoiceEngine`: 3 phones play assigned pitches in
   the derived tuning.
4. **Dance** — `AcousticSensor` + `NeighborSensor` + `MotionSensor` + `RewardModel` on
   device; validate against the sim's golden fixtures.
5. **Piece** — roles polish, global breath, dashboard scenes, soundcheck calibration
   tooling, dress rehearsal.

## 11. Out of scope (future)

- UWB "duet mode" garnish for near-touching pairs (v1 hardware path preserved on `main`).
- Web tier for bystanders' own phones.
- Performance recording/documentation rig.
- Android.

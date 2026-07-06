# Nearfield v2 — Crowd Ensemble ("Leaves in the Wind")

- **Date:** 2026-07-04 (rev 2, 2026-07-05: BLE-only sensing; proximity demoted to coarse
  encounters. rev 3, 2026-07-05: scored 16-minute form §12, tuning drift + performance
  seed §13. rev 5, 2026-07-05: visual identity §14 — interference topography. rev 7,
  2026-07-05: hub projection §16 — the wall)
- **Status:** Approved design; phases 1–2 (derive + simulator) implemented
- **Scope:** 10–50 phone distributed audio artwork, hub-coordinated, native iOS, with a laptop simulator

## 1. Summary

Nearfield v2 scales the piece from a 2-phone UWB duet to a 10–50 phone ensemble. A hub
(laptop on venue WiFi) assigns each phone a pitch and a role from a scale derived from the
tone's own slightly-stretched spectrum. The continuously expressive inputs are the ones
phones sense reliably: **motion** (leaves in the wind) and the hub's **global breath
cycle**. Proximity is a coarse, occasional signal — BLE RSSI detects *encounters* (someone
new is near you), which bloom your sound and then habituate; it never pretends to measure
distance finely. Beating between nearby phones happens physically in the air between
speakers — the artwork lives between people, not in any one device.

A browser-based simulator auditions the full ensemble (agents moving in a virtual room,
same synthesis, same reward model, and a realistic BLE noise model) so the piece can be
composed and tuned without assembling hardware.

The existing 2-phone UWB piece on `main` stays intact as its own intimate mode; v2 is a
separate mode/target, not a rewrite of v1's concept.

## 2. Psychoacoustic basis

From Plomp & Levelt (1965) and Sethares (*Tuning, Timbre, Spectrum, Scale*), five facts
drive the design:

1. **Roughness curve.** Two sine tones beat; perceived roughness peaks at ~25% of the
   critical bandwidth of separation and resolves to consonance at unison and beyond the
   critical band.
2. **Dissonance curves.** For any spectrum, sweeping a second copy against it and summing
   pairwise sine roughness yields a curve whose *dips* are the consonant intervals for that
   spectrum. Harmonic spectra produce the Western/just intervals; inharmonic spectra
   produce other scales (this is how gamelan tuning arises from its bar spectra).
3. **Partial count = interval vocabulary.** 2 partials → dips only at unison and
   (pseudo-)octave; a 3rd partial adds the fifth-analog; a 4th adds the fourth-analog.
   Fading partials in with bloom therefore changes *which neighbors you are in tune
   with*, not just how rich you sound.
4. **Amplitude moves dip depth, not dip location.** Partial gains can be modulated
   continuously without shifting the tuning logic — bloom-driven fades are safe.
5. **Co-design timbre and tuning.** A scale derived from the ensemble's own spectrum makes
   every pairing able to land on a consonance the tuning actually supports. Nearfield gets
   its own tuning system with pure sine stacks — no gamelan timbre.

With coarse sensing, the tension→resolution arc of fact 1 is traversed in **time** rather
than space: an encounter starts the tone slightly off the consonant target and slews it
into the dissonance-curve dip over several seconds (§5.3) — beating audibly slows and
locks after two people meet.

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
| Proximity sense | **BLE RSSI only — coarse near/mid/far buckets and encounter events; proximity is a secondary input** |
| Rejected senses | Mic amplitude (tried previously, flaky; AGC/robustness issues), overhead camera + CV (rejected on venue/aesthetic grounds), UWB mesh (2–4 concurrent `NISession` cap), acoustic chirp ToF (doesn't scale to continuous tracking) |
| Audition tool | Browser simulator, zero build step, shared config with the app, realistic BLE model |

### 3.1 Sensing rationale (research summary, 2026-07-05)

- iPhones sustain only ~2–4 concurrent `NISession`s, so a UWB mesh cannot cover 10–50
  phones; UWB fixed anchors don't ship multi-phone ranging off-the-shelf in 2026.
- BLE RSSI through crowds swings ±10 dB with body absorption (exposure-notification
  literature; Apple's iBeacon docs warn against computing distance from signal strength).
  It is honest only as smoothed buckets — which is how this design uses it.
- 25 years of shipped crowd-phone artworks (IRCAM CoSiMa/soundworks corpus, Fields,
  Dialtones, NIME audience-participation literature) contain effectively **zero** works
  with live fine inter-phone ranging; robust pieces are composed so sensing is texture,
  not load-bearing (the "Fields doctrine"). IRCAM's one BLE-proximity piece (ProXoMix,
  ≤24 people) used RSSI exactly as coarse per-peer gain, with explicit distrust of
  distance estimates.
- Consequence adopted here: the piece must remain musically complete with **zero**
  proximity data (§8); expect 15–20% of phones to sense poorly at any moment and let the
  composition absorb it.

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
spectrum against itself across one pseudo-octave, locates the dips, and takes them as the
scale degrees — 4 interior degrees for this ≤4-partial spectrum (few partials → few
coincidence intervals, §2.3; density is comparable to slendro's 5-per-octave given the
1259-cent pseudo-octave). It emits:

- `config/scale.json` — the machine-readable contract consumed by hub, app, and simulator
- `tuning/plots/` — dissonance-curve plots with chosen degrees marked, committed for review

`scale.json` schema (values are the actual generated output):

```json
{
  "version": 1,
  "base_freq_hz": 220.0,
  "spectrum": { "ratios": [1.0, 2.07, 3.2, 4.4], "amps": [1.0, 0.5, 0.3, 0.2] },
  "pseudo_octave_ratio": 2.07,
  "scale_cents": [0.0, 551.2, 754.0, 957.5],
  "dip_intervals_cents": [0.0, 551.2, 754.0, 957.5, 1259.6],
  "registers": { "anchor": -1, "voice": 0, "shimmer": 1 }
}
```

`scale_cents` are degrees within one pseudo-octave; `dip_intervals_cents` are the raw curve
dips used by the resolution-slew mechanic (§5.3). Registers shift by whole pseudo-octaves.

### 4.3 Roles

Role stratification borrows gamelan's *structure* (cyclic anchors / melody / elaboration),
not its sound:

| Role | Share | Register | Partials | Behavior |
|---|---|---|---|---|
| **Anchor** | ~1 in 8 | −1 pseudo-octave | 2 | Swells on the global breath cycle; ignores encounters; no resolution slew. The gravitational field. |
| **Voice** | remainder | base | up to 3 | Motion- and encounter-reactive. The main dance. |
| **Shimmer** | ~1 in 6 | +1 pseudo-octave | up to 4, low gain | Nearly silent when still; partial gains gated by motion. Leaves in the wind. |

The hub assigns roles by join order to hold these ratios and can rebalance live from the
dashboard.

## 5. Dance dynamics (reward model)

The reward model is pure state logic, specified here precisely so the Swift (device) and
JavaScript (simulator) implementations produce identical results from identical inputs.
All constants live in `config/params.json` with the defaults given below; the simulator's
sliders tune them and export the file.

### 5.1 Inputs (per phone *i*, updated at ~5 Hz)

- **Neighbor buckets** per peer *j*, from BLE. Each phone advertises its hub-assigned short
  ID (service UUID + ID in the advertisement); each phone scans with duplicates allowed.
  Per-packet RSSI is corrected by a per-device-model TX-power offset table, smoothed with
  an EMA (`τ_rssi = 3 s`), then bucketed **with hysteresis** (defaults, recalibrated at
  soundcheck §6.3):
  - NEAR: enter above `rssi_near_enter = −50 dBm`, exit below `rssi_near_exit = −56 dBm`
  - MID: enter above `rssi_mid_enter = −62 dBm`, exit below `rssi_mid_exit = −66 dBm`
  - FAR: otherwise (including "not heard for > 10 s")

  Under the §7.3 path-loss defaults these correspond to NEAR ≈ enter 1.7 m / exit 3.2 m
  and MID ≈ enter 6 m / exit 9 m; the calibration scene (§6.3) re-fits them per venue.
- **Encounter events**: an *encounter with j* begins when *j* has been NEAR continuously
  for `T_enc_on = 2 s`, and ends when *j* has been out of NEAR for `T_enc_off = 4 s`.
  Encounters are the only proximity signal the sound responds to; raw buckets/RSSI never
  drive audio directly.
- **Motion energy** `m_i ∈ [0,1]`: `clamp(EMA_τ=1s(|userAcceleration|) / a_max, 0, 1)` with
  `a_max = 0.5 g`, putting a calm walk (~0.25 g RMS) at ≈ 0.5.
- **Novelty** `n_i ∈ [0,1]`: fraction of current NEAR∪MID peer IDs not seen in the trailing
  `T_nov = 60 s` window.

### 5.2 State

- **Wind reservoir** `W_i ∈ [0,1]`:
  `dW/dt = α_m·m_i + α_n·n_i − W_i/τ_W`, clamped.
  Defaults: `α_m = 0.15/s`, `α_n = 0.3/s`, `τ_W = 30 s`.
- **Encounter envelope** `E_ij ∈ [0,1]` per peer: rises toward 1 with time constant
  `τ_A = 6 s` while the encounter is active; releases toward 0 with `τ_rel = 8 s` after it
  ends.
- **Familiarity** `F_ij ∈ [0,1]` per peer:
  while an encounter with *j* is active: `dF/dt = (1−F)/τ_F` (`τ_F = 25 s`);
  otherwise `dF/dt = −F/τ_R` (`τ_R = 45 s`).
- **Focus peer** `j* = argmax_j E_ij·(1 − β·F_ij)`.
- **Bloom** `B_i = E_ij*·(1 − β·F_ij*) · (g_0 + g_W·W_i)`.
  Defaults: `β = 0.7`, `g_0 = 0.4`, `g_W = 0.6`.
  Net effect: a fresh encounter with a charged wind reservoir blooms fully over ~6 s; a
  parked pair decays toward ~30% bloom; moving again (or meeting someone new) restores it.
  With no encounters at all, `B = 0` and the voice is carried by motion shimmer and the
  global breath — the piece stays musically complete (§3.1, §8).

### 5.3 Sound mapping

- **Partial gains.** Partial *k* (k = 2..4) has target gain
  `amp_k · smoothstep((B − t_k)/w)` with thresholds `t_2 = 0.15`, `t_3 = 0.4`,
  `t_4 = 0.65`, width `w = 0.2`; smoothed with attack 0.5 s / release 3 s. Partial 1 is
  always on. Each role caps its partial count (§5.4), so `t_4` is only reachable by
  Shimmer. Because partial count controls the interval vocabulary (§2.3), blooming
  literally brings you into tune with more of the room.
- **Resolution slew (tension → resolution, time-based).** At encounter start with *j**,
  let `c*` be the nearest entry of `dip_intervals_cents` to the nominal interval between
  the two assigned pitches. The sounding pitch starts offset by `c_start = 10` cents per
  side away from `c*` and slews into it as the envelope rises:
  `detune_i(t) = c_start · (1 − E_ij*)`, slew-limited to ≤ 6 cents/s.
  Both phones detect the encounter within seconds of each other, so the combined ~20-cent
  offset (≈ 2.5 Hz beating at 220 Hz) audibly slows and locks into the consonant dip —
  the Plomp–Levelt arc rendered in time. On release, drift back to nominal at the same
  rate. No slew when the nominal interval is > 60 cents from any dip.
- **Shimmer (AM).** Rate `r = 0.1 + 2.5·m_i` Hz, depth `0.25·W_i`, applied to the voice's
  overall gain. Movement is audible as gentle flutter — with proximity coarse, this and
  the partial blooms carried by `W` are the piece's primary continuous expression.
- **Global breath.** Hub clock with period `T_breath = 60 s` (§6.1). Ensemble-wide gain
  multiplier `1 + 0.08·sin(φ)`. Anchors follow a deeper swell `0.5 + 0.5·sin(φ + offset_i)`
  with slow attack, each anchor offset so lows overlap rather than pulse together.

### 5.4 Role modifiers

| | Anchor | Voice | Shimmer |
|---|---|---|---|
| Max partials | 2 | 3 | 4 |
| Bloom input | ignored | `B` | `B` |
| Partial gate | fixed 2 partials | as §5.3 | §5.3 gains additionally × `clamp(2·m_i, 0, 1)` |
| Resolution slew | none | full | full |
| Base gain | breath-driven | 1.0 | 0.5 |
| AM depth | ×0.5 | ×1.0 | ×1.5 |

### 5.5 Voicing (rev 4, 2026-07-05: sound-bath timbre layer)

Presentation-layer shaping applied at the audio output (not in the reward model), added
after the raw sine stack proved shrill in the 2–4 kHz band. `timbre` block in
`params.json`; all values are performance-tunable:

- **Equal-loudness tilt:** every partial's gain × `min(1, (loudness_ref_hz / f)^loudness_exponent)`
  (defaults 300 Hz, 0.5) — compensates the ear's 2–4 kHz sensitivity; self-adjusts as the
  tuning drifts.
- **Master tone:** high-shelf cut (−7 dB @ 1.8 kHz) into a gentle lowpass (4.2 kHz).
- **Reverb:** convolution with a *generated* impulse response — high-damped
  exponential-decay noise (defaults: 5.5 s decay, 3 kHz damping, 30% wet, equal-power
  mix). No sample assets; the iOS `VoiceEngine` generates the same IR.

## 6. Architecture

```
Hub (laptop, venue WiFi)
├─ WebSocket server: join → {pitch, role, configs}; broadcasts clock + params
├─ Artist dashboard (web): connection/encounter graph view, role rebalance,
│  scenes, master fade, RSSI threshold calibration
└─ serves config/scale.json + config/params.json

iPhone app (this repo, new modules alongside v1)
├─ HubClient        — URLSession WebSocket; assignment, clock, live params
├─ VoiceEngine      — AVAudioEngine + AVAudioSourceNode sine stack (≤4 partials)
├─ NeighborSensor   — CoreBluetooth advertise + scan → smoothed buckets,
│                     encounter events (§5.1)
├─ MotionSensor     — CoreMotion user-acceleration energy
├─ RewardModel      — §5 state machine (pure, unit-tested)
└─ Main screen      — interference-topography shader (§14), WKWebView visual layer

Simulator (browser, zero build step)
└─ simulator/index.html — same scale.json/params.json, same reward model in JS,
   BLE noise model over agent ground truth
```

### 6.1 Hub

Single-file Python server (`hub/hub.py`, `websockets` + static file serving) — the repo
already requires Python for `tuning/derive_scale.py`, so this keeps one offline toolchain.
Protocol (JSON over WebSocket):

- `→ join {device_id, name}`
- `← assign {participant_id, pitch_hz, role, scale, scale_drift, params, score,
   performance_id, clock: {epoch_ms, period_s}}`
- `← params_update {…}` — live tuning from dashboard, applied without rejoin
- `← score_position {t_s}` — 1 Hz heartbeat; phones interpolate the score locally and
  free-run if the hub disappears (§12.3)
- `← master {gain}`
- `→ telemetry {W, B, buckets: {near: [ids], mid: [ids]}, active_encounters: [ids]}` at
  1 Hz — feeds the dashboard's encounter-graph view (nodes = phones colored by role and
  sized by bloom; edges = active encounters). With no positions sensed, the dashboard
  shows the *social graph*, not a map.

Assignment: roles round-robin to hold §4.3 ratios; pitch degree = `join_index mod
len(scale_cents)` within the role's register; `participant_id` is a compact (16-bit) ID
for BLE advertisement. Clock sync: epoch + period with round-trip offset estimation; drift
is irrelevant at 60 s cycles. Phones that lose the hub keep their last assignment and
free-run the clock; rejoin is silent.

### 6.2 Audio engine

Native `AVAudioEngine` with an `AVAudioSourceNode` rendering the ≤4-partial sine stack:
sample-accurate partial-gain and detune automation for the slews in §5.3, robust
interruption handling, no WKWebView lifecycle or JS-bridge latency in the audio path. The
WebView remains as the visual layer only (the §14 interference shader); sound never
routes through it.
(With mic sensing cut, no special audio-session input mode is required — plain `.playback`
category.)

### 6.3 Sensing details

- **BLE.** Foreground only (performance app, screen on): CoreBluetooth peripheral manager
  advertises the service UUID + `participant_id`; central manager scans with
  `CBCentralManagerScanOptionAllowDuplicatesKey` for continuous per-packet RSSI. Smoothing,
  bucketing, hysteresis, and encounter logic per §5.1. A static per-device-model TX-offset
  table ships in `params.json` (extended as models are tested).
- **Calibration.** At soundcheck, the dashboard runs a calibration scene: pairs of phones
  are held at reference distances (~1 m and ~3 m) for a few seconds each; the hub fits the
  bucket thresholds per venue and pushes them via `params_update`.
- **Honesty rule.** RSSI never maps to a continuous distance anywhere in the codebase —
  buckets and encounter events only (§3.1).

### 6.4 Config artifacts

- `config/scale.json` — spectrum, scale, registers (§4.2). Generated by `tuning/derive_scale.py`.
- `config/params.json` — every constant in §5 (including bucket thresholds, hysteresis,
  encounter debounce times), role modifier table, TX-offset table. Hand-edited or exported
  from the simulator; served by the hub so all clients share one truth.

## 7. Simulator

### 7.1 Purpose

Hear the piece — 10–50 voices, roles, encounters, breath — without hardware, and *tune*
it: the simulator is the composition tool. Every §5 constant is a slider; the result
exports as `params.json`, which the hub then serves to real phones. It is Phase 2, before
any device work, because it gates the aesthetic: if the piece doesn't work in the
simulator, no amount of device code saves it. Critically, it must audition the piece
**through the sensing we actually have** — coarse, laggy, noisy encounters — not through
ground truth.

### 7.2 Requirements

- Single file, `simulator/index.html`, no build step, runs in desktop Chrome/Safari.
- 50 agents × up to 4 partials in real time (≤ ~200 `OscillatorNode`s — comfortably within
  Web Audio limits; if profiling disagrees, cull oscillators whose gain has been < −60 dB
  for > 5 s, and only then consider an AudioWorklet).
- Loads `config/scale.json` and `config/params.json`; falls back to embedded defaults when
  opened via `file://`.
- Implements §5 verbatim; shares golden test fixtures with the Swift implementation (§9).

### 7.3 Design

- **Room:** 2D canvas, agents as dots colored by role, sized by bloom; active encounters
  drawn as edges. Drag any agent; drag the listener position.
- **Movement presets:** `drift` (random walk), `flock` (attract/repel), `dance`
  (approach → linger → disperse cycles with per-agent tempo), `still` (control case —
  should audibly wilt via habituation). Global movement-rate slider.
- **BLE model:** simulated RSSI per pair from ground-truth distance via log path loss
  (`RSSI = P0 − 10·n·log10(d)`, defaults `P0 = −45 dBm @ 1 m`, `n = 2.2`) plus Gaussian
  shadowing noise (`σ = 6 dB`, slider) and random body-block events (−10 dB for 2–8 s,
  rate slider). The §5.1 smoothing/bucket/encounter pipeline runs on this noisy signal.
  An **"ideal sensing" A/B toggle** bypasses the noise model so the cost of coarse sensing
  is audible during composition.
- **Audio graph per agent:** up to 4 × (`OscillatorNode` → per-partial `GainNode`) → one
  agent-level `GainNode` → `StereoPannerNode` (pan from x-position relative to listener) →
  master. Distance to the listener sets a 1/d gain law on the agent gain.
- **Controls:** agent count, role ratios, all §5 params as sliders grouped by section,
  BLE noise params, breath period, scene A/B (save two param sets, toggle),
  `Export params.json`.
- **Score transport (§12):** play/hold/scrub across the 16-minute score with a **time
  compression** control (e.g., 8×: audition the whole arc in 2 minutes — bloom/drift
  time constants scale accordingly so proportions hold). Section label and score
  position in the stats bar; section-gong and final-gong events audible.
- **Performance seed (§13):** seed field + reroll button; agent fingerprint seeds derive
  from `fnv1a(agent_id ‖ seed)`. Same seed replays the same drift curves.

### 7.4 Fidelity limits (accepted)

The simulator omits room acoustics, speaker directivity, phone-speaker frequency response,
and crowd absorption; its BLE model is a statistical caricature (log path loss + noise),
not a venue prediction. It answers "does the composition work under coarse sensing?", not
"what are this venue's thresholds?" — the latter is what the soundcheck calibration scene
(§6.3) is for.

## 8. Failure handling (device)

Per the Fields doctrine (§3.1), every degradation below leaves a musically complete phone:
motion shimmer, role behavior, and the global breath never depend on sensing or the hub
being live.

- Hub unreachable → keep last assignment, free-run clock, silent rejoin loop.
- Bluetooth off / permission denied / noisy RF → no encounters fire; the phone plays its
  role on motion + breath alone; performance screen shows a subtle indicator.
- Audio session interruption (call, Siri, route change) → standard interruption handling,
  auto-resume within 2 s.
- Battery → dimmed performance screen, duty-cycled BLE scan (e.g., 2 s on / 1 s off;
  encounter debounce already tolerates gaps), no display updates above 10 Hz.

## 9. Testing

- **Tuning:** derivation script commits its dissonance-curve plots; reviewer eyeballs dips
  vs chosen degrees.
- **Reward model:** golden fixture file (input time-series of buckets/motion → expected
  `E/W/F/B/gains/detune` trajectories) checked into `config/fixtures/`; Swift and JS test
  suites both replay it and must match within tolerance (1e-3).
- **Bucket/encounter pipeline:** unit tests replay recorded RSSI traces (noisy, with
  dropouts) and assert bucket transitions and encounter events, including hysteresis and
  debounce edge cases.
- **Integration:** simulator is the aural integration test; a device debug panel fakes
  bucket/motion inputs so the full loop runs in the iOS simulator.
- **Device ladder:** 3 phones → 10 phones → dress rehearsal with venue soundcheck
  (threshold calibration + a walk-test that encounters fire within ~5 s of genuine
  approaches).

## 10. Build phases

1. **Derive** — `tuning/derive_scale.py` → `scale.json` + plots. ✅ (also: `--sweep` →
   `scale_drift.json` for §13.1)
2. **Simulate** — `simulator/index.html` with the BLE noise model; compose and tune until
   the piece sounds right *with realistic sensing*; export `params.json`. ✅ core, score,
   drift, voicing, per-agent phone-screen view (§14 shader from live state).
   *Aesthetic gate: do not proceed until the sim version is good.*
3. **Hum** — hub server + `HubClient` + `VoiceEngine`: 3 phones play assigned pitches in
   the derived tuning.
4. **Dance** — `NeighborSensor` + `MotionSensor` + `RewardModel` on device; validate
   against the sim's golden fixtures; walk-test encounter latency.
5. **Piece** — roles polish, global breath, dashboard scenes, soundcheck calibration
   tooling, dress rehearsal.

## 11. Implementation status & known approximations

(Section added rev 6 to fill a numbering gap from rev 3 and to keep spec-vs-built drift
visible. Update when a phase lands or an approximation is resolved.)

| Phase (§10) | Status |
|---|---|
| 1 Derive | ✅ `tuning/derive_scale.py` + sweep; 6 tests |
| 2 Simulate | ✅ score, drift, voicing, ombak, §14 phone view; 18 tests |
| 3 Hum | ✅ hub (4 tests) + `NearfieldEnsemble`; hardware-verified 2026-07-05 (iPhone 13 mini joined over tailnet as shimmer 626.1 Hz) |
| 4 Dance | ✅ code-complete: Swift RewardCore fixture-validated vs the JS core (4 XCTests, §9 contract); NeighborSensor (BLE) + MotionSensor + 5 Hz Conductor driving VoiceEngine; debug injection panel; loop verified live in simulator. **Two-phone BLE field test pending.** Peers' pitches derived locally from participant id (assignment is a pure function of join order) — no roster broadcast needed. |
| 5 Piece | ▶ in progress: score playback on phones ✅ (ScoreEngine + interpolateScale fixture-validated, 3 XCTests; free-run clock from hub heartbeats; live param patches; drift pitch glides; buka entry stagger; synchronized gong swells; whole-voice envelope); hub dashboard + score transport ✅ (verified end-to-end: START SCORE → sim phone entered buka with telemetry flowing); §14 shader main screen ✅ (`visual.html` in a WKWebView visual layer, `VisualBridge` push at 5 Hz from the Conductor — same state as the audio; tap toggles the status chrome; per-frame JS smoothing + audible-beat fringe drift per §14.2). generated-IR convolution reverb ✅ (`ConvolutionReverb.swift`: vDSP uniform-partitioned FFT convolution, IR ported exactly from the simulator's `rebuildReverbIR` via the shared Mulberry32; 3 XCTests incl. direct-convolution parity; ~0.5% of one core for the 5.5 s IR). hub projection ✅ (`/projection` on both hubs, §16; core headlessly tested — 23 JS tests; fake-phone E2E + Railway verified). Remaining: TestFlight distribution. |

Known approximations (spec says / built does):
- **§5.5 reverb:** ~~AVAudioUnitReverb stand-in~~ resolved 2026-07-05:
  `ConvolutionReverb.swift` convolves the same mulberry32(1234) damped-noise IR
  as the simulator (WebAudio-style normalize constants; equal-power dry/wet).
  One partition (~21 ms) of wet-path latency reads as pre-delay. The iOS EQ sits
  after the dry/wet sum instead of before the split — commutes, all LTI.
- **§6.2/Hum partials:** static modest partial stack (fundamental + 0.35× partials);
  bloom-driven gains arrive with the Dance-phase RewardModel.
- **ATS (device networking):** `NSAllowsArbitraryLoads` only — do NOT add
  `NSAllowsLocalNetworking` (its presence makes iOS ignore arbitrary-loads, and tailnet
  100.x addresses are not "local" to ATS). Hard-won on 2026-07-05.

## 12. Form: the scored 16-minute arc

The piece is **scored**: a fixed 16-minute timeline the hub drives, structured on
gamelan's time hierarchy — nested cycles (colotomy), conducted density levels (irama),
with the hub in the kendhang role: it makes no sound, it broadcasts position, and the
distributed ensemble realizes the texture.

### 12.1 Nested cycles

breath (~1 min) ⊂ section (2–5 min) ⊂ the piece (16 min, one long "gong cycle").
Section boundaries are marked colotomically: a **section gong** event makes all anchors
swell once *in phase* (~20 s), instead of their usual offset overlap. The piece ends on
the final gong: convergence and decay into one last synchronized anchor swell.

### 12.2 The sections (initial score; every number tunable in the simulator)

| Time | Section | Character |
|---|---|---|
| 0:00–2:00 | **Buka** | Anchors alone establish the field; voices unmute staggered by join order (`t_i = i · 120/N`); encounters disabled (global bloom multiplier 0). The room learns the tuning. |
| 2:00–7:00 | **Cycle I** | Encounter dynamics at the §5 defaults. Spacious; every meeting legible. |
| 7:00–10:00 | **Turning** | Breath period 60 → 40 s; tuning drift (§13) accelerates; bloom attack quickens. Time densifies (irama shift). |
| 10:00–14:00 | **Cycle II** | Dense level: novelty charge and shimmer AM up, faster blooms, movement matters most. |
| 14:00–16:00 | **Final gong** | Bloom multiplier ramps to 0; fingerprint drift suspends and every voice glides home to the canonical scale; synchronized anchor swell; master fade to silence. |

### 12.3 Mechanism: `config/score.json`

`config/score.json` is normative; its keyframes as of rev 3:

| at_s | label | patch |
|---|---|---|
| 0 | buka | bloom_multiplier 0, master_multiplier 1, fingerprint_amplitude 1, breath 60 |
| 120 | cycle-i | bloom_multiplier 1 |
| 420 | turning | breath 60 (hold-end), tau_attack 6 (hold-end), novelty 0.3, shimmer depth 0.25 |
| 600 | cycle-ii | breath 40, tau_attack 4, novelty 0.45, shimmer depth 0.35, bloom_multiplier 1 |
| 840 | final-gong | bloom_multiplier 1, master_multiplier 1, fingerprint_amplitude 1 (hold-ends) |
| 960 | end | bloom_multiplier 0, master_multiplier 0, fingerprint_amplitude 0 |

Events: `section_gong` at 120/420/600, `final_gong` at 840.

- Keyframe `patch` values are paths into `params.json`, plus score-only scalars:
  `bloom_multiplier` (multiplies `B` globally — how entries/endings disable the encounter
  mechanic without touching its constants) and `master_multiplier` (ensemble fade).
- **Interpolation:** each path's mentions form a piecewise-linear curve through
  `(at_s, value)` points; before its first mention a path holds that first value,
  after its last it holds the last. Holding a value therefore requires re-mentioning it
  at the keyframe where the hold ends (see breath 60 @ 420). Events are discrete.
- **Distribution:** phones receive the entire score at `assign` and interpolate locally
  from score position; the hub broadcasts `{score_position_s}` at 1 Hz as drift
  correction. A phone that loses the hub free-runs the score — the piece continues.
- **Dashboard transport:** position display, start/hold/advance-to-next-section, scrub
  (scrub is a rehearsal tool; performances run linearly).

## 13. Tuning drift and the performance seed

The video's closing observation — every gamelan is tuned differently, by memory,
drifting irrecoverably over decades — becomes a live mechanic at two timescales:

### 13.1 Global drift (the scale ages during the piece)

The stretch factor follows a scored trajectory: **2.04 at 0:00 → 2.10 at 14:00**, then
holds through the ending. The dips move with it, so the same encounter early and late in
the piece resolves to a slightly different consonance — the tuning system ages roughly a
decade per minute. Implementation: `derive_scale.py --sweep` precomputes a table of
scales at ~15 stretch values → `config/scale_drift.json`; clients interpolate
`scale_cents`/`dip_intervals_cents` between adjacent rows (pitch updates are
slew-limited glides, ≤ 2 cents/s, inaudible as events).

### 13.2 Per-phone fingerprint (unique per phone, per performance)

Each phone's realized pitch wanders slowly around its assigned scale degree — a bounded
OU (mean-reverting) random walk, **±12 cents max, time constant ~90 s** — so no two
phones are ever exactly in tune, and each performance's detuning pattern is unique but
reproducible:

- `performance_id` = unix timestamp at hub launch, shown on the dashboard (pin it to
  replay a performance's exact tuning; changes every performance by default).
- `fingerprint_seed = fnv1a(device_id ‖ performance_id)` → seeds the phone's
  deterministic PRNG (mulberry32). Same phone + same performance_id → same drift curve.
- Role scaling: anchors drift ×0.3 (the reference instruments stay steadiest, as gamelan
  gongs do); voices ×1.0; shimmer ×1.3.
- **Why this composes with §5.3:** two fingerprinted phones meet at most ~24 cents off a
  dip — well inside the 60-cent slew window — so the resolution slew *tunes them to each
  other* as the encounter blooms. Tuning becomes a social act; drifting apart resumes
  when they part. During the final-gong section, fingerprint amplitude ramps to 0 and
  the ensemble converges to the canonical scale for the first and only time.

Drift constants (`drift` block in `params.json`): `fingerprint_max_cents: 12`,
`fingerprint_tau_s: 90`, `global_stretch_from: 2.04`, `global_stretch_to: 2.10`,
role multipliers.

### 13.3 Ombak mode (rev 4, default on)

Balinese gamelan tunes its instrument pairs (pengumbang/pengisep) to a beat **rate** in
Hz — the *ombak* ("wave"), typically ~5–8 Hz — not to an interval in cents. Since beat
rate ≈ `f · cents · 5.8e-4`, a fixed-cents offset beats ~10× faster (rougher) in the
shimmer register than at the anchors. With `drift.ombak_enabled` (default true), the
resolution-slew start offset and the fingerprint amplitude scale by
`clamp(ombak_ref_hz / f, 0.25, 3)` (default ref 300 Hz), keeping pair beating slow and
wave-like in every register. The dip-correction term is intonation, not beating, and
stays unscaled.

## 14. Visual identity: interference topography

The phone's main screen is the piece's physics made visible. Selected from four live
studies (`simulator/visuals.html`, sketch A): a black-and-white field of thin contour
lines — a topographic map of wave interference — where **moiré fringes are literal
beating**: two ring families whose spacings differ by the current detune produce fringes
that drift at the true acoustic beat rate and freeze when the resolution slew locks.

### 14.1 The field

Scalar field = sum of ring families, one per sounding partial, contoured into
constant-width hairlines (`fract` iso-lines normalized by `fwidth`; reference GLSL in
`simulator/visuals.html`):

- **My tone radiates from six sources, all outside the visible frame**: the fundamental
  from three seeded points (itself + two "room reflection" image-sources at the same
  wavelength — a lone sine is still a woven multi-source field, never concentric rings),
  plus one source per unlocked partial. Centers orbit slowly; because every center is
  off-frame, only arcs cross the screen — **no focal point exists** in any state.
  (Reviewed and rejected twice: a single-center bullseye, and a solo mode that collapsed
  to one ring family when partials were gated.)
- **Peer families** (up to 3 concurrent, focus peer strongest) press in from a hashed
  azimuth as `E` rises but also stay outside the frame — approach reads as increasing
  curvature and fringe reorganization, not an arriving dot. BLE gives no bearing, and
  the spec makes no pretense of one.
- **Fringe drift is the audible beat**, not the raw pitch difference: the smallest
  frequency gap among near-coinciding partial pairs of the two tones (§2.1 — roughness
  lives inside the critical band), soft-compressed above ~1 Hz. Consonant-but-distant
  intervals drift near-imperceptibly; a locking pair visibly freezes.
- **The one exception to "no focal point":** during the final gong, as fingerprints
  converge to the canonical scale, my centers slowly merge into a single point — the
  bullseye is earned exactly once, as the piece's last image.

### 14.2 Data bindings (all live, from the same state that drives audio)

| Visual | Driven by |
|---|---|
| Ring spacing per family | sounding frequency of that partial (pitch × ratio, incl. drift §13.1) |
| Family weight (line contribution) | partial gain from RewardState (§5.3) |
| Peer family spacing offset | actual detune between the pair |
| Fringe drift rate | audible beat: min Δf over coinciding partial pairs (soft-capped ~1 Hz) — locks ⇒ freezes |
| Peer family position | encounter envelope `E` (edge → inward) |
| Solo line density (iso count) | wind `W` — sparse when still, denser as the room moves |
| Global slow scale pulse (±2%) | breath phase (§5.3) |
| Center layout + field rotation | fingerprint seed (§13.2) — each phone's screen is visually unique per performance |
| Convergence to single center | final-gong fingerprint-amplitude ramp (§12) |

### 14.3 Polarity, platform, performance

- **Two polarities:** ink (black hairlines on white) as the default identity; inverted
  (white on black) for dim venues — OLED-friendly across a 16-minute performance. The hub
  can set polarity via `params_update`.
- **Implementation:** one reference fragment shader (GLSL ES 1.0 +
  `OES_standard_derivatives`). The simulator renders it per-agent (tap an agent → that
  phone's screen view); the iOS app hosts the same shader in a WKWebView visual layer
  (sound never routes through it, §6.2) — a Metal port is future scope if profiling
  demands it.
- **Budget:** DPR capped at 2, target 30 fps on phone (60 in the sim); rendering pauses
  when the screen is off or the app is backgrounded — audio (§ Media Session) is
  unaffected.

### 14.4a Logotype & icon (chosen 2026-07-05)

Canonical assets in `identity/`:

- **`nearfield-logotype-dark.png`** (2172×724, white on black) and
  **`nearfield-logotype-ink.png`** (black on white) — lowercase "nearfield" in fat
  rounded glyphs drawn as nested wobbling contour strokes; liquid topographic lettering,
  no radiating field.
- **`nearfield-icon-source.png`** (1254×1254) — the app icon: the word half-submerged in
  a full-bleed contour terrain, the §14 field with the name surfacing from it. Shipped in
  the app as `NearfieldEnsemble/Assets.xcassets/AppIcon.appiconset` (single-size 1024,
  opaque; iOS applies its own mask).

The sketchpad (`simulator/logotype.html`, "nested" mode) remains the generative recipe
closest to the mark (SDF-fattened rounded glyphs, inward iso-lines, hash-noise wobble)
for variants, the lock-in splash animation, and alternate resolutions.

### 14.4 Identity applications

App icon and title card are stills of the field: the icon a tight crop of a *locked*
state (frozen consonance), the title card a solo terrain. The sketchpad can render
high-resolution frames for print/poster use; the identity system needs no assets beyond
the shader and one typeface (a light geometric sans, tracked wide, as in the sketchpad UI).

## 15. Out of scope (future)

- UWB "duet mode" garnish for near-touching pairs (v1 hardware path preserved on `main`;
  viable at ≤4 phones within `NISession` limits).
- Overhead-camera position tracking (researched, rejected for this piece; would restore
  fine proximity if ever revisited).
- Mic-based acoustic sensing (tried previously, flaky; superseded).
- Web tier for bystanders' own phones.
- Performance recording/documentation rig.
- Metal port of the §14 shader (only if WKWebView profiling demands it).
- Android.

## 16. Hub projection: the wall (rev 7)

One shared view of the whole ensemble, projected at the venue — the phones are
windows into a field; the wall *is* the field, in the same visual language as
§14 (black ground, fwidth-normalized hairline contours, no color). Reference
implementation of the layout and feel: `simulator/projection.html` (a fake
ensemble emits exact /status v1 frames; the renderer consumes only those).

### 16.1 Concept and identity

- **"Your screen is a crop of this wall."** Every participant is a source
  family on a shared plane; phones show the waves that reach them, the wall
  shows all of them meeting.
- **Identity through causality, no labels in art mode.** Walk → your cell's
  line density rises (W → density, response clamped so vigorous shaking looks
  no different from walking — the piece never rewards shaking). Approach
  someone → a bridge lights between your cells at the moment both phones
  bloom. Join → your cell ripples into the field (arrival fade ~4 s).
- **Solitude reads as containment.** An isolated, still participant is a
  small concentric ring family — the one place the piece shows a bullseye
  before the final gong, and it dissolves the moment they interact. (Phones
  ban solo bullseyes because the private view must never have a focal point;
  the wall showing *aloneness* as containment is the intended inversion.)
- **Final gong:** all cells converge to one center bullseye exactly as every
  phone's sources converge to its own screen center — room and wall land on
  the same earned image together.

### 16.2 Layout model — "leaves in the wind"

(Chosen over the colotomic-ring and pure-superposition alternatives.)
Positions are synthetic (BLE yields an interaction graph, not locations):

- Seeded home: `mulberry32(fnv1a(id|performance_id|wall))`, spread ±0.72 ×
  ±0.40 (min 0.12 from center), unit = min screen dimension.
- Wind wander: velocity noise σ = (0.004 + 0.028·W)·drift — a walker's cell
  breathes and wanders; a still one settles.
- Encounter springs: inferred edges pull ∝ 0.5·e, stopping at min distance
  0.22 (cells never fuse); soft pairwise repulsion inside 0.16 (the anti-blob
  lesson from the Dance sim); home pull 0.25/s; damping 0.6^dt.
- Final-gong convergence: positions ×(1−cv), influence radius ×(1+1.5·cv),
  cv driven by the score's fingerprint_amplitude curve so wall and phones
  converge from the same data.

### 16.3 Data path

- **v1 (build this): zero protocol changes.** Poll `GET /status` at 1 Hz —
  roster (id, role, pitch_hz, online) + telemetry {W, B, focus,
  detune_cents}. Edges inferred from focus fields (either direction), e:
  attack τ3 s while present, release τ6 s. Presentation smoothing W τ2, B
  τ1.5. Score position from `score_t`; gong/convergence timing evaluated
  client-side against the score (the hub inlines score.json into the page).
- **v2 (optional bump, not built yet):** telemetry adds top-3 {peer_id, E} →
  weighted mesh instead of single-focus edges.

### 16.4 Rendering

- Per-source windowed influence: contribution = w·smoothstep(rad, 0.3·rad, r)
  — keeps neighborhoods local and the GPU bounded; rad default 0.42.
- Interference exactly as §14.2: v = Σ att·cos(2πr/λ + φ) / Σ att; hairline
  extraction via the same hair() (fwidth-normalized).
- Density is a *field*: attenuation-weighted average of each owner's
  (2 + 2·W) — your patch of wall densifies when you move.
- λ mapping compressed for wall scale: λ = clamp(0.16·(220/f)^0.55, 0.035,
  0.4), f = sounding frequency (pitch bent by detune_cents).
- LOD: fundamentals always; partials 2–4 only for the top-8 cells by bloom
  (thresholds .15/.4/.65, window .2, amps ×[1,.5,.3,.2]); ≤64 sources total.
- **Fringe motion (aligned with phones — the sketch approximates this):**
  the ambient field is static (per-source phases fixed; a global ≤0.02 Hz
  drift is available as a tuning knob); motion lives in the *bridges*. Each active encounter pair renders a
  corridor-localized two-source interference term whose phase advances at the
  §14.2 audible beat rate — pairBeatHz(fA, fB, ratios), 1.2·tanh-capped, the
  same number both phones' screens use. ≤16 bridge slots. The sketch's
  linear per-source phase (k·(f−220)) is a recorded shortcut, not the design.
- Breath: global breathScale 1 + 0.012·sin(2πt/12 s); section gongs add a
  20 s ×1.05 swell.

### 16.5 Serving & modes

- Served by the hub as `GET /projection` (same process, laptop or cloud);
  any browser + projector pointed at the hub URL. DPR capped at 2.
- Art mode default: no chrome. `h` toggles the tuning panel; NUMBERS toggles
  a soundcheck overlay (#id, role, W per cell). Tuning defaults come from the
  sketch once dialed by ear/eye.
- Wall-clock advance fallback (≤50 ms substeps) so occluded/unfocused tabs
  keep simulating; rendering rides rAF.

### 16.6 Out of scope for v1

- The v2 telemetry mesh (16.3), audio from the wall (the wall is silent —
  sound stays in the phones), multi-projector tiling, recording rig.

# Nearfield

A sound installation where phones create richer harmonics as people physically get closer to each other.

## v2 — Leaves in the Wind (in progress)

A 10–50 phone crowd version is being built on the `design/crowd-ensemble` branch: each
phone gets a pitch and role (anchor / voice / shimmer) from a scale derived from the
tone's own slightly-stretched spectrum via sensory-dissonance curves; BLE encounters
bloom your sound, staying parked thins it, movement recharges it. Design spec:
`docs/superpowers/specs/2026-07-04-crowd-ensemble-design.md`. Plan:
`docs/superpowers/plans/2026-07-05-crowd-ensemble-phase1-2.md`.

**Try the simulator (no hardware needed):**

```bash
open simulator/index.html          # double-click works too; embedded configs
# or, to serve the live config files:
python3 -m http.server 8123        # from repo root
# then visit http://localhost:8123/simulator/index.html
```

Tap BEGIN (sound needs a user gesture). Drag dots to move people, drag ◎ to move your
ear. **Tap a dot (without dragging) to open that phone's screen** — the live
interference-topography visual (spec §14), driven by that agent's real state; identity
studies live at `simulator/visuals.html`. All reward-model constants are live sliders; `Export params.json` writes the tuning
that real phones will consume. The "ideal sensing" checkbox A/Bs perfect knowledge vs
the realistic noisy-BLE model.

**The 16-minute score:** hit *▶ play score* in the Score panel to run the full arc
(buka → cycle I → turning → cycle II → final gong) with tuning drift and per-phone
fingerprints. Set *time compression* to 8× or 16× to audition the whole piece in 1–2
minutes. The *performance seed* makes each performance's detuning unique — pin a seed to
replay it exactly.

**Tests:**

```bash
python3 -m pytest tuning/                    # scale derivation
node --test simulator/tests/core.test.mjs    # reward model + BLE pipeline
```

To regenerate the scale after changing the spectrum: `cd tuning && python3
derive_scale.py` (writes `config/scale.json` + a dissonance-curve plot to
`tuning/plots/`).

---

## v1 — UWB duet (below)

Each participant's phone plays a simple tone. As two people approach each other, their phones detect the proximity using Ultra-Wideband (UWB) and progressively unlock harmonic overtones—transforming isolated sounds into rich, beating textures that emerge from human connection.

## How It Works

1. **Peer Discovery**: Phones find each other via Multipeer Connectivity
2. **Token Exchange**: Devices exchange NIDiscoveryTokens
3. **UWB Ranging**: NearbyInteraction measures precise distance (±cm accuracy)
4. **Audio Response**: Web Audio API creates richer harmonics as distance decreases

## Proximity → Sound Mapping

| Distance | Effect |
|----------|--------|
| > 2m | Base tone only |
| 1-2m | First harmonic (octave) fades in |
| 0.6-1m | Second harmonic (fifth) |
| 0.3-0.6m | Third harmonic (major third) |
| < 0.3m | Full harmonic richness |

## Requirements

- **iPhone 11 or newer** (requires U1 chip for UWB)
- **iOS 16+**
- **Xcode 15+**

## Setup

1. Open Xcode
2. Create new project: **File → New → Project → iOS → App**
3. Settings:
   - Product Name: `Nearfield`
   - Interface: `SwiftUI`
   - Language: `Swift`
4. Copy the files from `Nearfield/` into your project:
   - `NearfieldApp.swift` → Replace existing
   - `ContentView.swift` → Replace existing
   - `nearfield.html` → Add to project (check "Copy items if needed")
   - `Info.plist` → Merge with existing or replace

5. Add frameworks to target:
   - `NearbyInteraction.framework`
   - `MultipeerConnectivity.framework`
   - `WebKit.framework`

6. **Important**: In Build Settings, set:
   - iOS Deployment Target: `16.0`

7. Sign with your Apple Developer account (required for device testing)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Swift Native Layer                    │
├─────────────────────────────────────────────────────────┤
│  ProximityManager                                        │
│  ├── NISession (UWB ranging)                            │
│  ├── MCSession (peer discovery)                         │
│  └── Discovery token exchange                           │
├─────────────────────────────────────────────────────────┤
│  WKWebView                                               │
│  └── JavaScript Bridge                                   │
│      updateNativeProximity(distance, peerCount)         │
├─────────────────────────────────────────────────────────┤
│                    Web Layer (HTML/JS)                   │
├─────────────────────────────────────────────────────────┤
│  Web Audio API                                           │
│  ├── Base oscillator (user's tone)                      │
│  └── Harmonic oscillators (proximity-unlocked)          │
└─────────────────────────────────────────────────────────┘
```

## Testing

1. Install on two iPhones (both 11 or newer)
2. Launch app on both
3. Tap "Play" on both
4. Move devices closer together
5. Watch the distance display update in real-time
6. Listen for harmonics emerging as devices get closer

## Web Prototype

`web-prototype.html` contains a browser-based version that uses ultrasonic audio for proximity detection instead of UWB. Less accurate but works on any device with a microphone.

## Limitations

- Only works with iPhones that have U1 chip (iPhone 11+)
- Both devices must have the app installed
- UWB has ~9m range, but accurate within ~30cm
- Background mode limited to ~30 seconds of active ranging

## License

MIT

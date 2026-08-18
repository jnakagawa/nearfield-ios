# Nearfield Explainer — a scroll-driven interference page

- **Date:** 2026-07-08
- **Status:** Design, pending review
- **One-liner:** A single scroll-driven web page that explains, in plain language,
  how sound waves beat and how Nearfield's ensemble is built in layers — taught
  through live interference visuals in the §14 hairline aesthetic.

## 1. Goal

Someone hears about Nearfield (or is about to join a performance) and wants to
understand two things:

1. **Beats** — why two close tones make a pulsing "wah," and why that pulse is
   the heart of the piece.
2. **The layers** — the few kinds of part that make up the ensemble, and how
   they stack into cycles.

The page teaches both by *showing* them: one full-screen interference field is
the constant backdrop, and scrolling drives it through the story. The visual
language of the piece (overlapping waves, constructive/destructive interference,
moiré, black ground + white hairline contours) is not decoration — it *is* the
explanation.

Non-goals: not a manual, not the app, not a technical paper. No install steps,
no equations, no jargon the reader must learn.

## 2. Audience & tone

A curious newcomer with no music-theory or math background. **Explorable-
explanation voice**: plain, mechanism-first, confident. Explain *how* a beat
forms ("waves add up; peaks reinforce or cancel; the drift is the beat"), never
with formulas or named jargon. Gamelan terms appear only as small lineage notes
beside the plain name, never as required reading.

**Reference copy register** (the bar for every line):

> Two tones are two waves. Play them together and they add up — where two peaks
> meet, it's louder; where a peak lands on a dip, they cancel out. If the tones
> are slightly different, that lineup drifts in and out, so the sound swells and
> fades. That swell-and-fade is the beat — and the further apart the two tones,
> the faster it pulses.

## 3. Vocabulary (locked)

- Grouping word for the parts: **layers**. (Lineage aside: gamelan's *stratified*
  texture; the parts are *ricikan*.)
- The parts, plain name first, gamelan lineage in parentheses:
  - **anchor — the pulse** *(the gongs)* — low, slow, marks time
  - **voice — the bones** *(balungan, "the frame")* — the core
  - **shimmer — the ornament** *(the elaboration)* — high, fine, motion-gated
  - **hub — the conductor** *(kendhang, the drum)* — silent, keeps the cycle
- Structure: **the cycle** (*colotomy*, nested rounds closed by a gong) and
  **the density** (*irama*, how busy the texture gets — swells and thins).
- One connective idea, stated once: **beats are interference in time; the
  contour field is the same thing in space** (waves crossing — bright where they
  agree, dark where they cancel).

## 4. Format & mechanics

- **One self-contained HTML file** (`explainer.html`), served by the hub at
  `/explainer` (static, like `/simulator`), and uploadable to the Zero CDN for a
  share link. Reuses the §14 contour shader language.
- **Scroll is the single driver.** A sticky full-screen `<canvas>` interference
  field stays pinned; a tall scroll container holds the text panels that pass
  over it. Scroll progress `p ∈ [0,1]` maps to the field's state (source
  positions, pitch offset, per-layer weights, density, convergence). Scrolling
  is scrubbing a timeline — the same gesture as scrubbing the score, and the
  right primary gesture on mobile.
- **Black ground, white hairline contours**, `fwidth`-normalized (the §14 look).
  Mobile-first; text legible over the field (subtle vignette/scrim behind copy).
- **Reduced motion:** `prefers-reduced-motion` → the field auto-advances gently
  on a timer instead of on scroll, and heavy animation is damped; the page still
  reads top-to-bottom.
- **Progressive enhancement:** on the beat scenes, a light touch/drag may nudge a
  source, but scroll alone tells the whole story (no interaction *required*).
- **Optional "hear the beat":** a small toggle on scene 2, **off by default and
  quiet** (~0.1 gain), gated behind a tap (browser autoplay rule). Two sine tones
  whose separation tracks the scene so you can hear the pulse you're seeing. Pure
  WebAudio, no dependency; the page is fully complete with sound off.
- **Robustness:** wall-clock rAF fallback (occluded/unfocused tabs keep
  advancing), `gl.getExtension('OES_standard_derivatives')` before compile, DPR
  capped at 2 — the same lessons already baked into the simulator/projection.

## 5. The scroll timeline (scenes)

Each scene = a short plain-language panel + a distinct field behavior. Ranges are
scroll progress; they will be tuned by eye.

1. **0.00–0.15 · the field** — a calm interference field; title. "Nearfield is a
   piece for many phones. Each is one wave in a single shared field."
2. **0.15–0.35 · two waves meet** — two sources drift together as you scroll;
   bright bands (constructive) and dark gaps (destructive) bloom between them; a
   plain readout shows the pulse slowing/quickening (e.g. "pulses: 3 / sec", no
   symbols). Copy = the §2 reference paragraph. Lineage aside: Balinese tuning
   pairs slightly-detuned instruments on purpose — *ombak*, "wave." Optional
   hear-the-beat toggle lives here.
3. **0.35–0.50 · in tune / apart** — scroll slides one source's pitch: the pulse
   slows to a standstill at unison ("that's in tune"), then speeds into a buzz
   and finally splits into two separate tones as they pull apart. Tie-in: "when
   two people come close in the piece, their tones slide toward that still,
   in-tune point."
4. **0.50–0.75 · the layers** — scroll reveals the parts one at a time, each a
   band at its own wavelength/register, stacking into the field: **anchor/pulse
   (gongs)** → **voice/bones (balungan)** → **shimmer/ornament (elaboration)** →
   **hub/conductor (kendhang, silent)**. "Not melody plus backing — a few equal
   layers that stack. The piece is their sum."
5. **0.75–0.92 · cycle & density** — the field organizes into nested cycles
   closed by the anchor's gong (*colotomy*); density swells and thins the
   ornament layer (*irama*) across the ~16-minute arc. "The piece breathes:
   cycles inside cycles, getting busier and sparser."
6. **0.92–1.00 · the gong** — every wave converges to one point (the earned
   final-gong image), then opens to the whole-field / projection view. Close:
   "Your phone shows your corner of the field; together, you are the field."
   Links: hear it (simulator), see it (projection), the app.

## 6. Architecture (one file)

- `<canvas>` sticky backdrop + a scroll-height container of `<section>` panels.
- A single `render(p, tSec)` where `p` = smoothed scroll progress and `tSec` =
  wall-clock time for ambient motion. Pure function of `(p, t)` → uniforms:
  source positions/wavelengths, per-layer weights, density, convergence `cv`.
  This mirrors how the projection derives everything from one state — easy to
  reason about and to retune by eye.
- Scenes are data: an array of `{range:[a,b], panel, apply(p01)}` where `p01` is
  progress *within* the scene. Adding/reordering a scene is editing that array.
- Scroll→progress is smoothed (eased) so the field never jitters; per-frame
  presentation smoothing on the uniforms (the same anti-jerk lesson from §14).
- No build step, no framework, no external assets. Fonts = system stack.

## 7. Testing

- Lightweight: the scene math (progress mapping, `range→p01`, easing, the
  beat-rate readout as a function of source separation) extracted into a tiny
  pure block and checked with a `node --test` file (same vm-extract pattern as
  the simulator/projection cores) — a handful of assertions, not a big suite.
- Visual verification by eye on desktop + a phone viewport (the design-by-live-
  options loop): scroll through, confirm each scene's field behavior and that
  copy stays legible; check reduced-motion auto-advance; check the optional audio
  toggle starts silent.

## 8. Out of scope (v1)

- Real ensemble data (this is a self-contained explainer, not a live view).
- Audio beyond the single optional two-tone beat demo.
- Localization; deep-linking to specific scenes; analytics.

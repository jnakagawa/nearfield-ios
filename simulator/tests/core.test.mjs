// Headless tests for the simulator's pure-logic core.
// Extracts <script id="nearfield-core"> from ../index.html and runs it in a VM.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'index.html'), 'utf8');
const m = html.match(/<script id="nearfield-core">([\s\S]*?)<\/script>/);
assert.ok(m, 'nearfield-core script block present');
const ctx = vm.createContext({ console });
vm.runInContext(m[1], ctx);

const P = () => JSON.parse(JSON.stringify(ctx.DEFAULT_PARAMS));
const SCALE = () => JSON.parse(JSON.stringify(ctx.DEFAULT_SCALE));

test('embedded scale matches generated config', () => {
  const s = SCALE();
  assert.equal(s.scale_cents.length, 4);
  assert.equal(s.pseudo_octave_ratio, 2.07);
  assert.deepEqual(s.dip_intervals_cents, [0.0, 551.2, 754.0, 957.5, 1259.6]);
});

test('assignRoles holds spec ratios and cycles degrees', () => {
  const roles = ctx.assignRoles(48, SCALE(), P());
  const count = r => roles.filter(a => a.role === r).length;
  assert.equal(count('anchor'), 6);
  assert.equal(count('shimmer'), 8);
  assert.equal(count('voice'), 34);
  for (let i = 0; i < 48; i++) assert.equal(roles[i].degreeIndex, i % 4);
  // anchor register -1: pitch = base / 2.07 * 2^(cents/1200)
  const anchor = roles.find(a => a.role === 'anchor');
  const expected = 220.0 / 2.07 * Math.pow(2, SCALE().scale_cents[anchor.degreeIndex] / 1200);
  assert.ok(Math.abs(anchor.pitchHz - expected) < 1e-6);
});

test('PairSensor bucket hysteresis', () => {
  const s = new ctx.PairSensor(P());
  const feed = (rssi, secs) => { for (let t = 0; t < secs; t += 0.2) s.update(0.2, rssi); };
  feed(-49, 12);            // above near_enter -50 after EMA convergence
  assert.equal(s.bucket, 'near');
  feed(-54, 12);            // inside hysteresis band (exit is -56) -> stays near
  assert.equal(s.bucket, 'near');
  feed(-58, 15);            // below near_exit, above mid_enter? -58 < -56 exit, >= -62 mid_enter -> mid
  assert.equal(s.bucket, 'mid');
  feed(-64, 15);            // between mid_exit -66 and mid_enter -62 -> stays mid
  assert.equal(s.bucket, 'mid');
  feed(-80, 20);            // below mid_exit -> far
  assert.equal(s.bucket, 'far');
});

test('encounter debounce on and off', () => {
  const s = new ctx.PairSensor(P());
  // strong signal: near immediately (EMA initialized at first sample)
  for (let t = 0; t < 1.8; t += 0.2) s.update(0.2, -45);
  assert.equal(s.encounterActive, false, 'not active before 2s');
  for (let t = 0; t < 0.6; t += 0.2) s.update(0.2, -45);
  assert.equal(s.encounterActive, true, 'active after >=2s in NEAR');
  // signal drops hard; EMA takes ~1.1s to cross exit, then 4s debounce
  let dropped = null;
  for (let t = 0; t < 12; t += 0.2) {
    s.update(0.2, -85);
    if (!s.encounterActive && dropped === null) dropped = t;
  }
  assert.ok(dropped !== null, 'encounter eventually ends');
  assert.ok(dropped >= 4.0, `no early drop (ended at ${dropped}s)`);
  assert.ok(dropped <= 8.0, `ends within EMA lag + debounce (ended at ${dropped}s)`);
});

test('far timeout when peer unheard', () => {
  const s = new ctx.PairSensor(P());
  for (let t = 0; t < 3; t += 0.2) s.update(0.2, -45);
  assert.equal(s.bucket, 'near');
  for (let t = 0; t < 10.5; t += 0.2) s.update(0.2, null);
  assert.equal(s.bucket, 'far');
});

test('reward: bloom rises on encounter, habituates parked, releases after', () => {
  const params = P(), scale = SCALE();
  const me = { id: 0, role: 'voice', pitchHz: 220 };
  const peerPitches = new Map([[1, 220]]); // same pitch -> unison dip
  const r = new ctx.RewardState(me, params, scale);
  const step = (secs, motion, active) => {
    let out;
    for (let t = 0; t < secs; t += 0.2) {
      out = r.update(0.2, {
        encounters: new Map([[1, active]]),
        buckets: new Map([[1, active ? 'near' : 'far']]),
        motion,
        peerPitches,
      });
    }
    return out;
  };
  const early = step(1.0, 0.5, true);
  const peak = step(14, 0.5, true);
  assert.ok(peak.E > 0.85, `E saturates (${peak.E})`);
  assert.ok(peak.B > 0.3, `bloom present (${peak.B})`);
  assert.ok(peak.partialGains[1] > 0.05, 'partial 2 audible at bloom');
  assert.equal(peak.partialGains[3], 0, 'voice role caps at 3 partials');
  assert.ok(Math.abs(early.detuneCents) > Math.abs(peak.detuneCents),
    'detune slews toward the dip as E rises');
  assert.ok(Math.abs(peak.detuneCents) < 2, 'locks near the dip');
  // habituation: parked (no motion), same partner, 90s
  const parked = step(90, 0.0, true);
  assert.ok(parked.F > 0.9, 'familiarity saturates');
  assert.ok(parked.B < peak.B * 0.55, `parked bloom decays (${parked.B} vs ${peak.B})`);
  // release
  const after = step(30, 0.0, false);
  assert.ok(after.B < 0.02, `bloom releases (${after.B})`);
});

test('anchor ignores encounters; shimmer gates partials on motion', () => {
  const params = P(), scale = SCALE();
  const mkInputs = motion => ({
    encounters: new Map([[1, true]]),
    buckets: new Map([[1, 'near']]),
    motion,
    peerPitches: new Map([[1, 220]]),
  });
  const anchor = new ctx.RewardState({ id: 0, role: 'anchor', pitchHz: 106 }, params, scale);
  let out;
  for (let t = 0; t < 20; t += 0.2) out = anchor.update(0.2, mkInputs(0.8));
  assert.equal(out.B, 0, 'anchor bloom is zero');
  assert.equal(out.detuneCents, 0, 'anchor never slews');

  const shimStill = new ctx.RewardState({ id: 0, role: 'shimmer', pitchHz: 455 }, params, scale);
  for (let t = 0; t < 20; t += 0.2) out = shimStill.update(0.2, mkInputs(0.0));
  const stillGain = out.partialGains[1];
  const shimMoving = new ctx.RewardState({ id: 0, role: 'shimmer', pitchHz: 455 }, params, scale);
  for (let t = 0; t < 20; t += 0.2) out = shimMoving.update(0.2, mkInputs(0.8));
  assert.ok(out.partialGains[1] > stillGain + 0.02,
    `shimmer partials gated by motion (moving ${out.partialGains[1]} vs still ${stillGain})`);
});

test('no slew when nominal interval far from any dip', () => {
  const params = P(), scale = SCALE();
  // degree 0 vs degree 2 within register: 203 cents apart from 551 -> >60 from dips
  const f2 = 220 * Math.pow(2, 754.0 / 1200);
  const f1 = 220 * Math.pow(2, 551.2 / 1200);
  const r = new ctx.RewardState({ id: 0, role: 'voice', pitchHz: f1 }, params, scale);
  let out;
  for (let t = 0; t < 3; t += 0.2) {
    out = r.update(0.2, {
      encounters: new Map([[1, true]]),
      buckets: new Map([[1, 'near']]),
      motion: 0.5,
      peerPitches: new Map([[1, f2]]),
    });
  }
  assert.equal(out.detuneCents, 0);
});

test('novelty pulses on fresh contact and expires', () => {
  const params = P(), scale = SCALE();
  const r = new ctx.RewardState({ id: 0, role: 'voice', pitchHz: 220 }, params, scale);
  const inputs = { encounters: new Map([[1, false]]), buckets: new Map([[1, 'mid']]),
    motion: 0, peerPitches: new Map([[1, 220]]) };
  let out = r.update(0.2, inputs);
  assert.equal(out.novelty, 1, 'fresh contact is novel');
  for (let t = 0; t < 65; t += 0.2) out = r.update(0.2, inputs);
  assert.equal(out.novelty, 0, 'novelty expires after window');
});

test('PairRadio is deterministic under a seed', () => {
  const params = P();
  const a = new ctx.PairRadio(params, ctx.mulberry32(42));
  const b = new ctx.PairRadio(params, ctx.mulberry32(42));
  for (let i = 0; i < 200; i++) {
    const d = 1 + 4 * Math.abs(Math.sin(i / 7));
    assert.equal(a.update(0.2, d), b.update(0.2, d));
  }
});

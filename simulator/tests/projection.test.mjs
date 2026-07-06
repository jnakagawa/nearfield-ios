// Headless tests for the projection page's pure core (spec §16).
// Same pattern as core.test.mjs: extract <script id="projection-core">, vm-run.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const html = readFileSync(join(root, 'hub', 'projection.html'), 'utf8');
const m = html.match(/<script id="projection-core">([\s\S]*?)<\/script>/);
assert.ok(m, 'projection-core script block present');
const ctx = vm.createContext({ console });
vm.runInContext(m[1], ctx);
const score = JSON.parse(readFileSync(join(root, 'config', 'score.json'), 'utf8'));

test('pairBeatHz: coinciding partials give the true beat, capped; none -> static', () => {
  // ratios [1,2]: fA 100 vs fB 201 coincide via 100*2 vs 201*1 -> Δ1 Hz
  assert.ok(Math.abs(ctx.pairBeatHz(100, 201, [1, 2]) - 1.2 * Math.tanh(1 / 1.2)) < 1e-9);
  // far apart, no coincidence under 25 Hz -> 0.04 (through the cap)
  assert.ok(Math.abs(ctx.pairBeatHz(100, 163, [1]) - 1.2 * Math.tanh(0.04 / 1.2)) < 1e-9);
});

test('scoreValueAt: fingerprint amplitude holds at 1 then ramps to 0 by end', () => {
  assert.equal(ctx.scoreValueAt(score, 'drift.fingerprint_amplitude', 0), 1);
  assert.equal(ctx.scoreValueAt(score, 'drift.fingerprint_amplitude', 500), 1);
  assert.ok(Math.abs(ctx.scoreValueAt(score, 'drift.fingerprint_amplitude', 900) - 0.5) < 1e-9);
  assert.equal(ctx.scoreValueAt(score, 'drift.fingerprint_amplitude', 2000), 0);
  assert.equal(ctx.scoreValueAt(null, 'x', 0), null);
});

test('updateEdges: focus edges attack tau3 and release tau6', () => {
  const frame = who => ({ participants: [
    { id: 0, telemetry: { focus: who } },
    { id: 1, telemetry: { focus: -1 } },
  ]});
  const edges = new Map();
  ctx.updateEdges(edges, frame(1), 3); // one 3 s step while active
  const e3 = edges.get('0|1').e;
  assert.ok(Math.abs(e3 - (1 - Math.exp(-1))) < 1e-9, `attack: ${e3}`);
  ctx.updateEdges(edges, frame(-1), 6); // 6 s step inactive
  assert.ok(Math.abs(edges.get('0|1').e - e3 * Math.exp(-1)) < 1e-9);
});

test('stepLayout: springs never fuse cells, wanderers stay near home', () => {
  const rand = () => 0.5; // no wander noise
  const mk = (id, x) => ({ id, x, y: 0, vx: 0, vy: 0, home: { x, y: 0 }, W: 0 });
  const A = mk(0, -0.3), B = mk(1, 0.3);
  const edges = [{ a: 0, b: 1, e: 1 }];
  for (let i = 0; i < 2000; i++) ctx.stepLayout([A, B], edges, 0.05, { drift: 1, spring: 3 }, rand);
  const d = Math.hypot(A.x - B.x, A.y - B.y);
  assert.ok(d >= 0.15, `min separation held: ${d}`);
  const C = mk(2, 0.1);
  for (let i = 0; i < 2000; i++) ctx.stepLayout([C], [], 0.05, { drift: 1, spring: 1 }, rand);
  assert.ok(Math.hypot(C.x - C.home.x, C.y - C.home.y) < 0.2, 'stays near home');
  assert.ok(Math.abs(C.x) <= 0.8 && Math.abs(C.y) <= 0.46, 'bounds held');
});

test('seedHome is deterministic and off-center', () => {
  const a = ctx.seedHome(3, 12345), b = ctx.seedHome(3, 12345);
  assert.deepEqual(a, b);
  assert.ok(Math.hypot(a.x, a.y) > 0.1);
});

test('alignAngles converges encountering pairs, including across the wrap', () => {
  const mk = (id, az) => ({ id, az, gr: az });
  const A = mk(0, 0.1), B = mk(1, 2 * Math.PI - 0.1); // 0.2 rad apart via wrap
  const edges = [{ a: 0, b: 1, e: 1 }];
  const before = Math.abs(ctx.wrapPi(B.az - A.az));
  for (let i = 0; i < 100; i++) ctx.alignAngles([A, B], edges, 0.05, 1);
  const after = Math.abs(ctx.wrapPi(B.az - A.az));
  assert.ok(after < before * 0.2, `converged: ${before} -> ${after}`);
  // wrap path taken: A moved toward negative, not the long way around
  assert.ok(Math.abs(A.az) < 0.15 || A.az > 6.1, `short way: ${A.az}`);
});

test('beatVel: zero when solo, audible-beat sum when encountering, capped', () => {
  const by = new Map([
    [0, { id: 0, pitch: 220, det: 0 }],
    [1, { id: 1, pitch: 221, det: 0 }], // fundamentals beat at 1 Hz
  ]);
  assert.equal(ctx.beatVel(0, [], by, ctx.RATIOS), 0);
  const v = ctx.beatVel(0, [{ a: 0, b: 1, e: 1 }], by, ctx.RATIOS);
  assert.ok(Math.abs(v - 1.2 * Math.tanh(1 / 1.2)) < 1e-9, `v=${v}`);
  const many = Array.from({ length: 10 }, () => ({ a: 0, b: 1, e: 1 }));
  assert.equal(ctx.beatVel(0, many, by, ctx.RATIOS), 1.2); // capped
});

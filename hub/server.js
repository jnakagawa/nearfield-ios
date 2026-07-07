#!/usr/bin/env node
/* Nearfield hub — Node port of hub.py for cloud containers (the Zerohost
 * python image shipped without python; node is its documented path). Keep
 * this protocol-identical to hub.py: join -> assign payload, 1 Hz
 * score_position heartbeats, score_stop after the end hold, telemetry
 * intake, and the same dashboard endpoints. hub.py remains the source of
 * truth for local/laptop use and for tests; port changes both ways.
 *
 * Deps: ws (vendored into the deploy zip — no install step in the container).
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = parseInt(process.env.PORT || '5000', 10);
// deploy bundles put config/ beside this file; the repo keeps it at the root
const CONFIG_DIR = process.env.CONFIG_DIR
  || [path.join(__dirname, 'config'), path.join(__dirname, '..', 'config')]
    .find(d => fs.existsSync(path.join(d, 'scale.json')))
  || path.join(__dirname, 'config');
const SCORE_END_HOLD_S = 30; // final-gong image lingers, then free hum

const loadJson = f => JSON.parse(fs.readFileSync(path.join(CONFIG_DIR, f), 'utf8'));
const scale = loadJson('scale.json');
const params = loadJson('params.json');
const score = loadJson('score.json');
const drift = loadJson('scale_drift.json');

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

function pitchHzFor(degreeIndex, register) {
  return scale.base_freq_hz
    * Math.pow(scale.pseudo_octave_ratio, register)
    * Math.pow(2, scale.scale_cents[degreeIndex] / 1200);
}

// Role/pitch assignment by join order — mirrors hub.py's Assigner (itself a
// mirror of the tested JS assignRoles): anchors 1-in-8, shimmer 1-in-6,
// degree cycles join order; rejoining devices keep their slot.
const assigner = {
  byDevice: new Map(),
  count: 0, anchors: 0, shimmers: 0,
  assign(deviceId, name) {
    if (this.byDevice.has(deviceId)) return this.byDevice.get(deviceId);
    const i = this.count++;
    let role = 'voice';
    const anchorEvery = params.roles.anchor.share_one_in;
    const shimmerEvery = params.roles.shimmer.share_one_in;
    if (this.anchors < Math.ceil((i + 1) / anchorEvery)) {
      role = 'anchor'; this.anchors++;
    } else if (this.shimmers < Math.ceil((i + 1) / shimmerEvery)) {
      role = 'shimmer'; this.shimmers++;
    }
    const degreeIndex = i % scale.scale_cents.length;
    const register = scale.registers[role];
    const out = {
      participant_id: i, device_id: deviceId, name,
      role, degree_index: degreeIndex, register,
      pitch_hz: pitchHzFor(degreeIndex, register),
    };
    this.byDevice.set(deviceId, out);
    return out;
  },
};

const performanceId = Math.floor(Date.now() / 1000);
const clients = new Map();   // ws -> participant_id
const telemetry = new Map(); // participant_id -> latest payload
let scoreStartedAt = null;   // unix seconds, or null

// shared projection state (hub.py parity): hub is the source of truth
const PROJECTION_INT = new Set(['mode', 'fold', 'ink']);
const projection = { mode: 1, fold: 8, density: 1.9, beat_x: 1.0, ink: 1 };
function setProjection(query) {
  for (const [k, v] of new URLSearchParams(query)) {
    if (k in projection && !Number.isNaN(+v)) {
      projection[k] = PROJECTION_INT.has(k) ? Math.round(+v) : +v;
    }
  }
  return projection;
}
function clearOffline() {
  const online = new Set(clients.values());
  let removed = 0;
  for (const [dev, a] of assigner.byDevice) {
    if (!online.has(a.participant_id)) { assigner.byDevice.delete(dev); removed++; }
  }
  for (const pid of [...telemetry.keys()]) if (!online.has(pid)) telemetry.delete(pid);
  return removed;
}

function broadcast(payload) {
  const raw = JSON.stringify(payload);
  for (const ws of clients.keys()) {
    if (ws.readyState === ws.OPEN) ws.send(raw);
  }
}

// One clock beat — mirrors hub.py score_tick: position while running, one
// score_stop after sitting at the end for the hold, then silence.
function scoreTick() {
  if (scoreStartedAt === null) return null;
  const elapsed = Date.now() / 1000 - scoreStartedAt;
  const duration = score.duration_s;
  if (elapsed >= duration + SCORE_END_HOLD_S) {
    scoreStartedAt = null;
    log(`score finished (+${SCORE_END_HOLD_S}s hold) — back to free hum`);
    return { type: 'score_stop' };
  }
  return { type: 'score_position', t_s: Math.min(elapsed, duration), n: clients.size };
}

setInterval(() => {
  const msg = scoreTick();
  if (msg !== null) broadcast(msg);
}, 1000);

function startScore() {
  scoreStartedAt = Date.now() / 1000;
  log(`score started (performance ${performanceId})`);
}

function statusJson() {
  const joined = [...assigner.byDevice.values()]
    .sort((a, b) => a.participant_id - b.participant_id);
  const online = new Set(clients.values());
  return {
    performance_id: performanceId,
    score_t: scoreStartedAt === null ? null
      : Math.min(Date.now() / 1000 - scoreStartedAt, score.duration_s),
    projection,
    participants: joined.map(a => ({
      id: a.participant_id, name: a.name, role: a.role,
      pitch_hz: Math.round(a.pitch_hz * 10) / 10,
      online: online.has(a.participant_id),
      telemetry: telemetry.get(a.participant_id) ?? null,
    })),
  };
}

// Suffix-matched, query-tolerant paths: works unchanged behind reverse
// proxies that prefix the path and/or token-gate with ?t=… (hub.py parity).
const server = http.createServer((req, res) => {
  const p = req.url.split('?', 1)[0];
  if (p.endsWith('/status')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(statusJson()));
  } else if (p.endsWith('/start-score')) {
    startScore();
    res.writeHead(200);
    res.end('score started\n');
  } else if (p.endsWith('/set-projection')) {
    const query = req.url.includes('?') ? req.url.split('?', 2)[1] : '';
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(setProjection(query)));
  } else if (p.endsWith('/clear-roster')) {
    res.writeHead(200);
    res.end(`cleared ${clearOffline()} offline participants\n`);
  } else if (p.endsWith('/projection')) {
    // §16 wall view with the score inlined (read per request: dev-friendly)
    const html = fs.readFileSync(path.join(__dirname, 'projection.html'), 'utf8')
      .replace('/*NF_SCORE*/ null', JSON.stringify(score));
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(html);
  } else {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(DASHBOARD_HTML);
  }
});

const wss = new WebSocketServer({ server });
wss.on('connection', ws => {
  let pid = null;
  ws.on('message', raw => {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type === 'join') {
      const a = assigner.assign(String(msg.device_id ?? 'unknown'), String(msg.name ?? '?'));
      pid = a.participant_id;
      clients.set(ws, pid);
      ws.send(JSON.stringify({
        type: 'assign',
        participant_id: a.participant_id,
        role: a.role,
        degree_index: a.degree_index,
        register: a.register,
        pitch_hz: a.pitch_hz,
        scale, scale_drift: drift, params, score,
        performance_id: performanceId,
        clock: { epoch_ms: Date.now(), period_s: params.breath.period_s },
      }));
      log(`join: #${a.participant_id} ${a.name} (${a.device_id.slice(0, 8)}) -> ${a.role} ${a.pitch_hz.toFixed(1)} Hz`);
    } else if (msg.type === 'telemetry' && pid !== null) {
      telemetry.set(pid, msg);
    }
  });
  ws.on('close', () => {
    if (clients.has(ws)) {
      log(`leave: #${clients.get(ws)}`);
      clients.delete(ws);
    }
  });
});

const DASHBOARD_HTML = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Nearfield hub</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body { background:#101014; color:#d8d8de; font:14px/1.5 -apple-system,sans-serif;
       max-width:640px; margin:2rem auto; padding:0 1rem; }
h1 { font-size:16px; letter-spacing:.2em; } .dim { color:#8a8a96; }
table { width:100%; border-collapse:collapse; margin-top:1rem; }
td,th { padding:6px 8px; text-align:left; border-bottom:1px solid #26262e; font-size:13px; }
.off { opacity:.35; } button { background:#1c1c2a; color:#fff; border:1px solid #5a5aff;
border-radius:999px; padding:8px 22px; letter-spacing:.1em; cursor:pointer; }
#score { font-variant-numeric:tabular-nums; }
</style></head><body>
<h1>NEARFIELD <span class="dim">hub</span></h1>
<p><span id="score" class="dim">score not started</span>
<button id="startBtn">START SCORE</button>
<button id="clearBtn" title="drop offline participants from the roster">CLEAR OFFLINE</button></p>
<p class="dim">projection:
<button data-pm="1">FIELD</button><button data-pm="2">OP-ART</button><button data-pm="0">CELLS</button>
<button id="inkBtn">◐ INK</button>
<a id="projLink" href="#" target="_blank" style="color:#8a8aff">open ↗</a><br>
<label>fold <input id="pFold" type="range" min="1" max="12" step="1" style="width:90px"></label>
<label>density <input id="pDens" type="range" min="0" max="3" step="0.05" style="width:90px"></label>
<label>beat× <input id="pBeat" type="range" min="0" max="2" step="0.05" style="width:90px"></label>
</p>
<table id="t"><tr><th>#</th><th>name</th><th>role</th><th>pitch</th><th>W</th><th>B</th></tr></table>
<script>
// endpoints resolved relative to wherever the dashboard is served, keeping
// any proxy path prefix and ?t= access token intact
const base = location.pathname.endsWith('/') ? location.pathname : location.pathname + '/';
const ep = name => base + name + location.search;
const epq = (name, params) => base + name + location.search + (location.search ? '&' : '?') + params;
document.getElementById('startBtn').onclick = () => fetch(ep('start-score'));
document.getElementById('clearBtn').onclick = () => fetch(ep('clear-roster'));
document.getElementById('projLink').href = ep('projection');
let inkNow = 1;
for (const b of document.querySelectorAll('button[data-pm]'))
  b.onclick = () => fetch(epq('set-projection', 'mode=' + b.dataset.pm));
document.getElementById('inkBtn').onclick = () => fetch(epq('set-projection', 'ink=' + (1 - inkNow)));
for (const [id, key] of [['pFold','fold'],['pDens','density'],['pBeat','beat_x']])
  document.getElementById(id).onchange = e => fetch(epq('set-projection', key + '=' + e.target.value));
setInterval(async () => {
  const s = await (await fetch(ep('status'))).json();
  if (s.projection) {
    inkNow = s.projection.ink;
    for (const [id, key] of [['pFold','fold'],['pDens','density'],['pBeat','beat_x']]) {
      const el = document.getElementById(id);
      if (document.activeElement !== el) el.value = s.projection[key];
    }
    document.querySelectorAll('button[data-pm]').forEach(b =>
      b.style.background = +b.dataset.pm === s.projection.mode ? '#5a5aff' : '#1c1c2a');
  }
  document.getElementById('score').textContent = s.score_t === null ? 'score not started'
    : \`score \${String(Math.floor(s.score_t/60)).padStart(2,'0')}:\${String(Math.floor(s.score_t%60)).padStart(2,'0')} / 16:00\`;
  const rows = s.participants.map(p => {
    const tm = p.telemetry || {};
    return \`<tr class="\${p.online?'':'off'}"><td>\${p.id}</td><td>\${p.name}</td><td>\${p.role}</td>
      <td>\${p.pitch_hz} Hz</td><td>\${tm.W?.toFixed?.(2) ?? '—'}</td><td>\${tm.B?.toFixed?.(2) ?? '—'}</td></tr>\`;
  }).join('');
  document.getElementById('t').innerHTML =
    '<tr><th>#</th><th>name</th><th>role</th><th>pitch</th><th>W</th><th>B</th></tr>' + rows;
}, 1000);
</script></body></html>
`;

server.listen(PORT, '0.0.0.0', () => {
  log(`nearfield hub on :${PORT} — performance_id ${performanceId}`);
});

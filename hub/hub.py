#!/usr/bin/env python3
"""Nearfield hub — spec §6.1.

Single-file coordination server for the crowd ensemble: assigns each phone a
pitch and role from the derived scale, delivers all configs in the `assign`
payload (phones free-run if the hub disappears), broadcasts the score position
at 1 Hz while the score runs, and accepts telemetry for the dashboard.

Usage: python3 hub.py [--port 8770] [--performance-id <pin>] [--start-score]
"""

import argparse
import asyncio
import json
import logging
import time
import urllib.parse
from pathlib import Path

import websockets

log = logging.getLogger("hub")

SCORE_END_HOLD_S = 30  # how long the final-gong image lingers after the score ends

ROLE_SHARE = {"anchor": 8, "shimmer": 6}  # one-in-N, matching params.roles


def load_configs(config_dir):
    d = Path(config_dir)
    scale = json.loads((d / "scale.json").read_text())
    params = json.loads((d / "params.json").read_text())
    score = json.loads((d / "score.json").read_text())
    drift = json.loads((d / "scale_drift.json").read_text())
    return scale, params, score, drift


def pitch_hz_for(scale, degree_index, register):
    return (
        scale["base_freq_hz"]
        * (scale["pseudo_octave_ratio"] ** register)
        * (2 ** (scale["scale_cents"][degree_index] / 1200.0))
    )


class Assigner:
    """Role/pitch assignment by join order — must mirror the tested JS
    `assignRoles` (simulator core): anchors 1-in-8, shimmer 1-in-6, degree
    cycles join_index mod len(scale). Rejoining devices keep their slot."""

    def __init__(self, scale, params):
        self.scale = scale
        self.params = params
        self.by_device = {}
        self.count = 0
        self.anchors = 0
        self.shimmers = 0

    def assign(self, device_id, name):
        if device_id in self.by_device:
            return self.by_device[device_id]
        i = self.count
        self.count += 1
        role = "voice"
        anchor_every = self.params["roles"]["anchor"]["share_one_in"]
        shimmer_every = self.params["roles"]["shimmer"]["share_one_in"]
        if self.anchors < -(-(i + 1) // anchor_every):  # ceil div
            role = "anchor"
            self.anchors += 1
        elif self.shimmers < -(-(i + 1) // shimmer_every):
            role = "shimmer"
            self.shimmers += 1
        degree_index = i % len(self.scale["scale_cents"])
        register = self.scale["registers"][role]
        out = {
            "participant_id": i,
            "device_id": device_id,
            "name": name,
            "role": role,
            "degree_index": degree_index,
            "register": register,
            "pitch_hz": pitch_hz_for(self.scale, degree_index, register),
        }
        self.by_device[device_id] = out
        return out


# §16.2/§16.5: shared projection state — the hub is the source of truth; the
# dashboard and every open projection edit/follow the same values.
PROJECTION_DEFAULTS = {"mode": 1, "fold": 8, "density": 1.9, "beat_x": 1.0, "ink": 1}
PROJECTION_INT_KEYS = {"mode", "fold", "ink"}


class Hub:
    def __init__(self, config_dir, performance_id=None):
        self.scale, self.params, self.score, self.drift = load_configs(config_dir)
        self.performance_id = performance_id or int(time.time())
        self.assigner = Assigner(self.scale, self.params)
        self.clients = {}       # websocket -> participant_id
        self.telemetry = {}     # participant_id -> latest payload
        self.score_started_at = None  # unix time when score started, or None
        self.projection = dict(PROJECTION_DEFAULTS)

    def set_projection(self, query):
        """Apply ?k=v pairs to the shared projection state; unknown keys and
        junk values are ignored (the dashboard is on an open LAN)."""
        for k, vals in urllib.parse.parse_qs(query).items():
            if k in self.projection and vals:
                try:
                    v = float(vals[0])
                except ValueError:
                    continue
                self.projection[k] = int(v) if k in PROJECTION_INT_KEYS else v
        return self.projection

    def clear_offline(self):
        """Drop roster/telemetry rows for participants not currently connected
        (stale devices, dev leftovers). Connected phones keep their slots; the
        join counter never rewinds, so future joins still get fresh ids."""
        online = set(self.clients.values())
        before = len(self.assigner.by_device)
        self.assigner.by_device = {
            d: a for d, a in self.assigner.by_device.items()
            if a["participant_id"] in online}
        self.telemetry = {p: t for p, t in self.telemetry.items() if p in online}
        return before - len(self.assigner.by_device)

    # --- protocol (§6.1) -----------------------------------------------------

    async def handler(self, ws):
        pid = None
        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                t = msg.get("type")
                if t == "join":
                    a = self.assigner.assign(
                        str(msg.get("device_id", "unknown")), str(msg.get("name", "?")))
                    pid = a["participant_id"]
                    self.clients[ws] = pid
                    await ws.send(json.dumps({
                        "type": "assign",
                        "participant_id": a["participant_id"],
                        "role": a["role"],
                        "degree_index": a["degree_index"],
                        "register": a["register"],
                        "pitch_hz": a["pitch_hz"],
                        "scale": self.scale,
                        "scale_drift": self.drift,
                        "params": self.params,
                        "score": self.score,
                        "performance_id": self.performance_id,
                        "clock": {
                            "epoch_ms": int(time.time() * 1000),
                            "period_s": self.params["breath"]["period_s"],
                        },
                    }))
                    log.info("join: #%s %s (%s) -> %s %.1f Hz",
                             a["participant_id"], a["name"], a["device_id"][:8],
                             a["role"], a["pitch_hz"])
                elif t == "telemetry" and pid is not None:
                    self.telemetry[pid] = msg
        except websockets.ConnectionClosed:
            pass
        finally:
            if ws in self.clients:
                log.info("leave: #%s", self.clients[ws])
                del self.clients[ws]

    async def broadcast(self, payload):
        raw = json.dumps(payload)
        for ws in list(self.clients):
            try:
                await ws.send(raw)
            except websockets.ConnectionClosed:
                pass

    def score_tick(self):
        """One clock beat: the message to broadcast, or None. The score clears
        itself after sitting at the end for SCORE_END_HOLD_S — the final
        converged image lingers, then phones drop back to free hum
        (fingerprints return, master fades back in). Without this, a finished
        score parks every phone at the final-gong state forever."""
        if self.score_started_at is None:
            return None
        elapsed = time.time() - self.score_started_at
        duration = self.score["duration_s"]
        if elapsed >= duration + SCORE_END_HOLD_S:
            self.score_started_at = None
            log.info("score finished (+%ds hold) — back to free hum", SCORE_END_HOLD_S)
            return {"type": "score_stop"}
        return {"type": "score_position", "t_s": min(elapsed, duration),
                "n": len(self.clients)}

    async def score_clock(self):
        while True:
            await asyncio.sleep(1)
            msg = self.score_tick()
            if msg is not None:
                await self.broadcast(msg)

    def start_score(self):
        self.score_started_at = time.time()
        log.info("score started (performance %s)", self.performance_id)

    # --- dashboard (HTTP on the same port) -------------------------------------

    def status_json(self):
        joined = sorted(self.assigner.by_device.values(), key=lambda a: a["participant_id"])
        online = set(self.clients.values())
        return {
            "performance_id": self.performance_id,
            "score_t": (min(time.time() - self.score_started_at, self.score["duration_s"])
                        if self.score_started_at is not None else None),
            "projection": self.projection,
            "participants": [{
                "id": a["participant_id"], "name": a["name"], "role": a["role"],
                "pitch_hz": round(a["pitch_hz"], 1),
                "online": a["participant_id"] in online,
                "telemetry": self.telemetry.get(a["participant_id"]),
            } for a in joined],
        }

    def projection_html(self):
        """The §16 wall view, with the score inlined so gongs/convergence run
        client-side without another fetch."""
        html = (Path(__file__).resolve().parent / "projection.html").read_text()
        return html.replace("/*NF_SCORE*/ null", json.dumps(self.score))

    def process_request(self, connection, request):
        """Plain-HTTP endpoints on the WS port: / dashboard, /status,
        /start-score, /projection. Path matching is suffix-based and ignores
        the query string so the hub works unchanged behind reverse proxies
        that prefix the path and/or token-gate with ?t=… (e.g. a cloud
        deploy)."""
        if "Upgrade" in request.headers:
            return None  # WebSocket handshake proceeds
        path = request.path.split("?", 1)[0]
        if path.endswith("/status"):
            resp = connection.respond(200, json.dumps(self.status_json()))
            resp.headers["Content-Type"] = "application/json"
            return resp
        if path.endswith("/start-score"):
            self.start_score()
            return connection.respond(200, "score started\n")
        if path.endswith("/set-projection"):
            query = request.path.split("?", 1)[1] if "?" in request.path else ""
            resp = connection.respond(200, json.dumps(self.set_projection(query)))
            resp.headers["Content-Type"] = "application/json"
            return resp
        if path.endswith("/clear-roster"):
            removed = self.clear_offline()
            return connection.respond(200, f"cleared {removed} offline participants\n")
        if path.endswith("/projection"):
            resp = connection.respond(200, self.projection_html())
            resp.headers["Content-Type"] = "text/html"
            return resp
        resp = connection.respond(200, DASHBOARD_HTML)
        resp.headers["Content-Type"] = "text/html"
        return resp


DASHBOARD_HTML = """<!DOCTYPE html>
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
    : `score ${String(Math.floor(s.score_t/60)).padStart(2,'0')}:${String(Math.floor(s.score_t%60)).padStart(2,'0')} / 16:00`;
  const rows = s.participants.map(p => {
    const tm = p.telemetry || {};
    return `<tr class="${p.online?'':'off'}"><td>${p.id}</td><td>${p.name}</td><td>${p.role}</td>
      <td>${p.pitch_hz} Hz</td><td>${tm.W?.toFixed?.(2) ?? '—'}</td><td>${tm.B?.toFixed?.(2) ?? '—'}</td></tr>`;
  }).join('');
  document.getElementById('t').innerHTML =
    '<tr><th>#</th><th>name</th><th>role</th><th>pitch</th><th>W</th><th>B</th></tr>' + rows;
}, 1000);
</script></body></html>
"""


async def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", type=int, default=8770)
    p.add_argument("--config-dir", default=str(Path(__file__).resolve().parent.parent / "config"))
    p.add_argument("--performance-id", type=int, default=None,
                   help="pin to replay a performance's tuning (default: launch timestamp)")
    p.add_argument("--start-score", action="store_true", help="start the 16-minute score immediately")
    args = p.parse_args()

    hub = Hub(args.config_dir, args.performance_id)
    if args.start_score:
        hub.start_score()
    async with websockets.serve(hub.handler, "0.0.0.0", args.port,
                                process_request=hub.process_request):
        log.info("nearfield hub on :%s — performance_id %s (dashboard: http://localhost:%s/)",
                 args.port, hub.performance_id, args.port)
        await hub.score_clock()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    asyncio.run(main())

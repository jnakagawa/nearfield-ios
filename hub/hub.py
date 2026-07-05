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
from pathlib import Path

import websockets

log = logging.getLogger("hub")

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


class Hub:
    def __init__(self, config_dir, performance_id=None):
        self.scale, self.params, self.score, self.drift = load_configs(config_dir)
        self.performance_id = performance_id or int(time.time())
        self.assigner = Assigner(self.scale, self.params)
        self.clients = {}       # websocket -> participant_id
        self.telemetry = {}     # participant_id -> latest payload
        self.score_started_at = None  # unix time when score started, or None

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

    async def score_clock(self):
        while True:
            await asyncio.sleep(1)
            if self.score_started_at is not None:
                t = min(time.time() - self.score_started_at, self.score["duration_s"])
                await self.broadcast({"type": "score_position", "t_s": t})

    def start_score(self):
        self.score_started_at = time.time()
        log.info("score started (performance %s)", self.performance_id)


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
    async with websockets.serve(hub.handler, "0.0.0.0", args.port):
        log.info("nearfield hub on :%s — performance_id %s", args.port, hub.performance_id)
        await hub.score_clock()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    asyncio.run(main())

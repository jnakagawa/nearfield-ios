import asyncio
import json
import math
from pathlib import Path

import websockets

from hub import Assigner, load_configs, Hub

CONFIG_DIR = Path(__file__).resolve().parent.parent / "config"


def test_assigner_matches_js_core_ratios():
    # must equal the tested JS assignRoles: 48 -> anchor 6, shimmer 8, voice 34
    scale, params, score, drift = load_configs(CONFIG_DIR)
    a = Assigner(scale, params)
    roles = [a.assign(f"dev{i}", f"name{i}")["role"] for i in range(48)]
    assert roles.count("anchor") == 6
    assert roles.count("shimmer") == 8
    assert roles.count("voice") == 34


def test_assigner_degree_cycle_and_pitch_math():
    scale, params, score, drift = load_configs(CONFIG_DIR)
    a = Assigner(scale, params)
    out = [a.assign(f"dev{i}", f"name{i}") for i in range(8)]
    n_deg = len(scale["scale_cents"])
    for i, o in enumerate(out):
        assert o["degree_index"] == i % n_deg
        reg = scale["registers"][o["role"]]
        expected = (
            scale["base_freq_hz"]
            * (scale["pseudo_octave_ratio"] ** reg)
            * (2 ** (scale["scale_cents"][o["degree_index"]] / 1200.0))
        )
        assert math.isclose(o["pitch_hz"], expected, rel_tol=1e-9)


def test_assigner_is_stable_per_device():
    scale, params, score, drift = load_configs(CONFIG_DIR)
    a = Assigner(scale, params)
    first = a.assign("device-A", "A")
    again = a.assign("device-A", "A")  # rejoin keeps the same assignment
    assert first["participant_id"] == again["participant_id"]
    assert first["pitch_hz"] == again["pitch_hz"]


def test_status_json_shape():
    hub = Hub(CONFIG_DIR, performance_id=123)
    hub.assigner.assign("dev-a", "A")
    hub.assigner.assign("dev-b", "B")
    s = hub.status_json()
    assert s["performance_id"] == 123
    assert s["score_t"] is None
    assert [p["id"] for p in s["participants"]] == [0, 1]
    assert s["participants"][0]["role"] == "anchor"
    assert not s["participants"][0]["online"]
    hub.start_score()
    assert hub.status_json()["score_t"] is not None


def test_join_round_trip():
    async def scenario():
        hub = Hub(CONFIG_DIR)
        async with websockets.serve(hub.handler, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
                await ws.send(json.dumps({"type": "join", "device_id": "test-dev", "name": "pytest"}))
                reply = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
        return reply

    reply = asyncio.run(scenario())
    assert reply["type"] == "assign"
    for key in ("participant_id", "pitch_hz", "role", "scale", "scale_drift",
                "params", "score", "performance_id", "clock"):
        assert key in reply, f"missing {key}"
    assert reply["clock"]["period_s"] > 0
    assert reply["role"] in ("anchor", "voice", "shimmer")
    assert reply["scale"]["scale_cents"] == [0.0, 551.2, 754.0, 957.5]


def test_score_tick_lifecycle():
    # not started -> silent; running -> position; end + hold -> one stop, then silent
    import time as _time
    from hub import SCORE_END_HOLD_S

    hub = Hub(CONFIG_DIR, performance_id=7)
    assert hub.score_tick() is None
    hub.start_score()
    msg = hub.score_tick()
    assert msg["type"] == "score_position" and msg["t_s"] < 1
    hub.score_started_at = _time.time() - hub.score["duration_s"] - 1
    msg = hub.score_tick()  # inside the hold: still parked at the end
    assert msg["type"] == "score_position" and msg["t_s"] == hub.score["duration_s"]
    hub.score_started_at = _time.time() - hub.score["duration_s"] - SCORE_END_HOLD_S - 1
    assert hub.score_tick()["type"] == "score_stop"
    assert hub.score_started_at is None
    assert hub.score_tick() is None

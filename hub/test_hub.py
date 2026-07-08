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


def test_projection_endpoint_inlines_score():
    hub = Hub(CONFIG_DIR, performance_id=9)
    html = hub.projection_html()
    assert 'projection-core' in html
    assert '/*NF_SCORE*/ null' not in html      # token replaced
    assert '"duration_s": 960' in html          # the actual score payload


def test_projection_controls_and_clear():
    hub = Hub(CONFIG_DIR, performance_id=11)
    assert hub.status_json()["projection"] == {
        "mode": 1, "fold": 8, "density": 1.9, "beat_x": 1.0, "ink": 1}
    out = hub.set_projection("mode=2&fold=6&density=1.2&ink=0&bogus=9&fold=junk")
    assert out == {"mode": 2, "fold": 6, "density": 1.2, "beat_x": 1.0, "ink": 0}
    assert isinstance(out["mode"], int) and isinstance(out["density"], float)

    a = hub.assigner.assign("dev-a", "A")
    hub.assigner.assign("dev-b", "B")
    hub.telemetry = {0: {"W": 1}, 1: {"W": 1}}
    hub.clients = {object(): a["participant_id"]}  # only A online
    assert hub.clear_offline() == 1
    assert list(hub.assigner.by_device) == ["dev-a"]
    assert list(hub.telemetry) == [0]
    # cleared devices rejoin with a FRESH id (count never rewinds)
    assert hub.assigner.assign("dev-b", "B")["participant_id"] == 2


def test_stop_score_broadcasts_once_via_tick():
    hub = Hub(CONFIG_DIR, performance_id=13)
    hub.stop_score()
    assert hub.score_tick() is None      # stop while idle: nothing to do
    hub.start_score()
    hub.stop_score()
    msg = hub.score_tick()
    assert msg == {"type": "score_stop"} # mid-score abort releases the phones
    assert hub.score_started_at is None
    assert hub.score_tick() is None      # one stop, one broadcast


def test_static_file_serves_simulator_and_blocks_traversal():
    hub = Hub(CONFIG_DIR, performance_id=15)
    sim = hub.static_file("/simulator/index.html")
    assert sim is not None and sim[1] == "text/html"
    assert b"nearfield-core" in sim[0]
    # bare /simulator -> index.html
    assert hub.static_file("/simulator") is not None
    # config json is served for the sim's ../config fetches
    cfg = hub.static_file("/config/scale.json")
    assert cfg is not None and cfg[1] == "application/json"
    assert b"pseudo_octave_ratio" in cfg[0]
    # traversal + non-allowlisted dirs are refused
    assert hub.static_file("/simulator/../hub/hub.py") is None
    assert hub.static_file("/config/../../etc/passwd") is None
    assert hub.static_file("/hub/hub.py") is None
    assert hub.static_file("/simulator/nope.html") is None

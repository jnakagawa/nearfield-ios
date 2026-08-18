"""Dev tool: join N fake phones to a hub and stream plausible telemetry so
/projection and the dashboard can be exercised without hardware.

Usage: python3 fake_phones.py [--host ws://127.0.0.1:8770] [--n 8]

Run against a FRESH hub (restart it first) so the fakes take participant ids
0..n-1 — their focus fields point at each other by id.
"""
import argparse
import asyncio
import json
import math
import random

import websockets


async def phone(host, i, n):
    async with websockets.connect(host) as ws:
        await ws.send(json.dumps({"type": "join", "device_id": f"fake-{i}", "name": f"fake{i}"}))
        assign = json.loads(await ws.recv())
        _ = assign["participant_id"]
        t = 0.0
        while True:
            await asyncio.sleep(1)
            t += 1
            w = 0.5 + 0.45 * math.sin(t / 19 + i)          # slow wandering W
            # pair up neighbours on a slow cycle so bridges form and dissolve
            partner = (i + 1) % n if (t + i * 7) % 60 < 25 else -1
            focus = partner if partner >= 0 and random.random() > 0.1 else -1
            b = 0.6 * (1 if focus >= 0 else 0.1) * w
            await ws.send(json.dumps({
                "type": "telemetry", "W": max(0.05, w), "B": b,
                "focus": focus, "detune_cents": random.uniform(-6, 6),
            }))


async def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="ws://127.0.0.1:8770")
    p.add_argument("--n", type=int, default=8)
    args = p.parse_args()
    await asyncio.gather(*(phone(args.host, i, args.n) for i in range(args.n)))


if __name__ == "__main__":
    asyncio.run(main())

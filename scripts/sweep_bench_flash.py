#!/usr/bin/env python3
"""GLM-5.3-Flash sweep battery: C1 x2 + C4 + C8, e2e wall-clock tok/s -> JSON.
Usage: sweep_bench_flash.py [--url URL] [--model NAME] [--max-tokens N]"""
import json, subprocess, time, argparse
from concurrent.futures import ThreadPoolExecutor

ap = argparse.ArgumentParser()
ap.add_argument("--url", default="http://10.10.10.14:8000/v1/chat/completions")
ap.add_argument("--model", default="glm-5.3-flash")
ap.add_argument("--max-tokens", type=int, default=256)
a = ap.parse_args()

PROMPT = ("Write a detailed, factual paragraph about the history of the transistor, "
          "covering Bell Labs, Shockley, Bardeen, Brattain, and the shift from vacuum tubes.")

def one_req(max_tokens=256):
    body = json.dumps({"model": a.model,
                       "messages": [{"role": "user", "content": PROMPT}],
                       "max_tokens": max_tokens, "temperature": 0})
    t0 = time.time()
    try:
        out = subprocess.run(
            ["curl", "-sS", "--max-time", "300", a.url,
             "-H", "Content-Type: application/json", "-d", body],
            capture_output=True, text=True, timeout=310).stdout
        d = json.loads(out)
        tok = d["usage"]["completion_tokens"]
        return {"tokens": tok, "wall": round(time.time() - t0, 2), "ok": True}
    except Exception as e:
        return {"tokens": 0, "wall": round(time.time() - t0, 2), "ok": False, "err": str(e)[:120]}

def run_conc(c):
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=c) as ex:
        res = list(ex.map(lambda _: one_req(), range(c)))
    wall = time.time() - t0
    toks = sum(r["tokens"] for r in res)
    return {"concurrency": c, "tokens": toks, "wall": round(wall, 2),
            "aggregate_tps": round(toks / wall, 2) if wall > 0 else 0,
            "ok_count": sum(1 for r in res if r["ok"])}

out = {"timestamp": time.strftime("%Y-%m-%d %H:%M:%S"), "url": a.url}
w = one_req(64)
out["warmup"] = w
c1 = []
for _ in range(2):
    r = one_req()
    r["tps"] = round(r["tokens"] / r["wall"], 2) if r["wall"] > 0 else 0
    c1.append(r)
out["c1"] = c1
out["c4"] = run_conc(4)
out["c8"] = run_conc(8)
print(json.dumps(out, indent=1))

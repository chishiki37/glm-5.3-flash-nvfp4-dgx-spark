#!/usr/bin/env python3
"""Structured-output C1 probe — mirrors tonyd2wild's DFlash2 re-bench conditions
(count 1->200, alphabet x8; warmed, temp 0, single-stream) so numbers are comparable.
Also runs our standard prose + code C1 cells for the A/B vs s3.
Usage: python3 c1_structured.py [url] [out.jsonl]
"""
import json, os, sys, time, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/home/vikassridhar/c1_structured.jsonl"
URL = BASE.rstrip("/") + "/v1/chat/completions"
MODEL = os.environ.get("BENCH_MODEL", "glm-5.3-flash")

PROMPTS = {
    "count200": "Count from 1 to 200, one number per line.",
    "alphabet8": "Write the lowercase English alphabet, then repeat it 7 more times, each alphabet on its own line.",
    "prose": "Write a short paragraph about why coastal cities developed where they did.",
    "code": "Write a Python function that returns the longest common subsequence of two strings, with a brief explanation.",
}
MAXTOK = {"count200": 600, "alphabet8": 600, "prose": 512, "code": 512}

def post(payload, timeout=600):
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

# warmup: 2 short + 1 of each kind
for _ in range(2):
    post({"model": MODEL, "messages": [{"role": "user", "content": "Say hi."}], "max_tokens": 8, "temperature": 0})
for kind, p in PROMPTS.items():
    post({"model": MODEL, "messages": [{"role": "user", "content": p}], "max_tokens": 32, "temperature": 0})

with open(OUT, "w") as f:
    for kind, p in PROMPTS.items():
        for it in range(3):
            t0 = time.time()
            r = post({"model": MODEL, "messages": [{"role": "user", "content": p}],
                      "max_tokens": MAXTOK[kind], "temperature": 0})
            dt = time.time() - t0
            ct = r["usage"]["completion_tokens"]
            rec = {"kind": kind, "iter": it, "completion_tokens": ct,
                   "wall_s": round(dt, 3), "tok_s": round(ct / dt, 2)}
            print(json.dumps(rec), flush=True)
            f.write(json.dumps(rec) + "\n")
print(f"[done] wrote {OUT}", flush=True)

#!/usr/bin/env python3
"""Concurrent-prefill stress gate for KV ladder rungs (adopted from tonyd2wild
SM121-CRASH-FORENSICS-2026-08-27: single-prefill gates are insufficient — a pool
that survives one 20K prefill can NVRM-OOM under overlapping prefills).

Fires N simultaneous long-prefill requests against the local endpoint, then
checks the engine still serves a normal request.

Usage: python3 concprefill_gate.py [n_concurrent] [prompt_tokens] [url]
Default: 3 concurrent, ~20000 prompt tokens, http://127.0.0.1:8000
Exit 0 = gate passed, 1 = gate failed (engine died or request error).
"""
import json, os, sys, time, urllib.request, concurrent.futures

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
TOK = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
BASE = sys.argv[3] if len(sys.argv) > 3 else "http://127.0.0.1:8000"
URL = BASE.rstrip("/") + "/v1/chat/completions"
# ~83 tok/copy calibration from longprefill_gate.py (same PARA unit, verified at
# 25,176 reported tokens for 289 copies). Sentence-units are 8x too small — do not use.
PARA = ("The history of distributed computing is a history of memory walls. "
        "Every generation of hardware moved the bottleneck: from registers to caches, "
        "from caches to main memory, from main memory to the network, and from the network "
        "back again to the unified fabric that joins processor and storage. Inference on "
        "small clusters repeats this arc at desk scale, where the page cache, the driver "
        "allocator, and the KV slab negotiate a border that no specification records. ")
COPIES = max(1, TOK // 83)
PROMPT = ("Repeat-after-me stress gate. Read the following passage once.\n\n"
          + PARA * COPIES
          + "\n\nRespond with exactly: GATE-OK")

def post(payload, timeout=1800):
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def prefill(i):
    t0 = time.time()
    body = {"model": "glm-5.3-flash",
            "messages": [{"role": "user", "content": f"[req {i}] Summarize in one word: {PROMPT}"}],
            "max_tokens": 8, "temperature": 0}
    resp = post(body)
    dt = time.time() - t0
    pt = resp["usage"]["prompt_tokens"]
    return (i, pt, round(dt, 1))

print(f"[gate] firing {N} concurrent prefills, target ~{TOK} tok each", flush=True)
t_start = time.time()
try:
    with concurrent.futures.ThreadPoolExecutor(max_workers=N) as ex:
        results = list(ex.map(prefill, range(N)))
    for i, pt, dt in results:
        print(f"[gate] prefill {i}: prompt_tokens={pt} in {dt}s", flush=True)
    print(f"[gate] all {N} prefills completed in {time.time()-t_start:.1f}s", flush=True)
except Exception as e:
    print(f"[gate] FAILED during concurrent prefills: {e}", flush=True)
    sys.exit(1)

time.sleep(5)
try:
    r = post({"model": "glm-5.3-flash",
              "messages": [{"role": "user", "content": "Say OK."}],
              "max_tokens": 8, "temperature": 0}, timeout=120)
    print("[gate] post-stress sanity: engine serves normal request OK", flush=True)
except Exception as e:
    print(f"[gate] FAILED post-stress sanity: {e}", flush=True)
    sys.exit(1)
print("[gate] PASS", flush=True)

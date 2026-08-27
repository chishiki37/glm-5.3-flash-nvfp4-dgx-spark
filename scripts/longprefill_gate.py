#!/usr/bin/env python3
"""Long-prefill stress gate (stdlib only). Sends a ~24K-token prompt with a tiny
max_tokens, verifies completion, then a short sanity probe. Prints JSON.
This is the gate from tonyd2wild's 38 GiB cautionary tale: a big KV slab that
boots fine can still NVRM-OOM on the first long prefill."""
import json, os, sys, time, urllib.request
from typing import Any, Dict

URL = os.environ.get("BENCH_URL", "http://127.0.0.1:8000/v1/chat/completions")
MODEL = os.environ.get("BENCH_MODEL", "glm-5.3-flash")
GATE_TOKENS_EST = int(os.environ.get("GATE_TOKENS_EST", "24000"))

PARA = ("The history of distributed computing is a history of memory walls. "
        "Every generation of hardware moved the bottleneck: from registers to caches, "
        "from caches to main memory, from main memory to the network, and from the network "
        "back again to the unified fabric that joins processor and storage. Inference on "
        "small clusters repeats this arc at desk scale, where the page cache, the driver "
        "allocator, and the KV slab negotiate a border that no specification records. ")
# ~83 tokens per copy; copies to reach the target estimate
COPIES = max(1, GATE_TOKENS_EST // 83)
PROMPT = ("Repeat-after-me stress gate. Read the following passage once.\n\n"
          + PARA * COPIES
          + "\n\nRespond with exactly: GATE-OK")

def post(payload: Dict[str, Any], timeout: int = 1800) -> Dict[str, Any]:
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

out: Dict[str, Any] = {"gate_tokens_est": GATE_TOKENS_EST, "prompt_copies": COPIES,
                       "prompt_chars": len(PROMPT)}
# 1) long-prefill gate
t0 = time.time()
try:
    resp = post({"model": MODEL, "messages": [{"role": "user", "content": PROMPT}],
                 "max_tokens": 8, "temperature": 0})
    out["gate_ok"] = True
    out["gate_wall_s"] = round(time.time() - t0, 2)
    usage = resp.get("usage", {}) or {}
    out["prompt_tokens_reported"] = usage.get("prompt_tokens")
    out["completion_text"] = (resp["choices"][0]["message"]["content"] or "")[:60]
except Exception as e:
    out["gate_ok"] = False
    out["gate_error"] = f"{type(e).__name__}: {e}"[:300]
    print(json.dumps(out)); sys.exit(1)

# 2) post-gate sanity probe (engine must still serve a normal request)
t0 = time.time()
try:
    post({"model": MODEL, "messages": [{"role": "user", "content":
          "Write one sentence about the sea."}], "max_tokens": 32, "temperature": 0})
    out["postgate_ok"] = True
    out["postgate_wall_s"] = round(time.time() - t0, 2)
except Exception as e:
    out["postgate_ok"] = False
    out["postgate_error"] = f"{type(e).__name__}: {e}"[:300]
print(json.dumps(out))

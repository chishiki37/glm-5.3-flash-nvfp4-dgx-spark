#!/usr/bin/env python3
"""Quick sweep probe: 3x single-stream prose 512tok + acceptance stats helper. Stdlib only."""
import json, os, sys, time, urllib.request
from statistics import median

URL = os.environ.get("BENCH_URL", "http://100.102.97.64:8000/v1/chat/completions")
MODEL = os.environ.get("BENCH_MODEL", "glm-5.3-flash")
PROMPT = ("Write a detailed one-page essay on the history of the transistor, "
          "from its invention at Bell Labs through modern FinFET technology.")

def one():
    payload = {"model": MODEL, "messages": [{"role": "user", "content": PROMPT}],
               "max_tokens": 512, "stream": True, "stream_options": {"include_usage": True},
               "temperature": 0.0, "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter(); first = None; usage = None
    with urllib.request.urlopen(req, timeout=900) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                d = json.loads(data)
            except Exception:
                continue
            if d.get("usage"):
                usage = d["usage"]
            ch = d.get("choices") or []
            if ch and first is None:
                delta = ch[0].get("delta") or {}
                if delta.get("content") or delta.get("reasoning"):
                    first = time.perf_counter() - t0
    total = time.perf_counter() - t0
    toks = usage["completion_tokens"] if usage else 0
    ttft = first if first is not None else float("nan")
    decode = (toks - 1) / (total - ttft) if toks > 1 and total > ttft else float("nan")
    return {"tokens": toks, "ttft": round(ttft, 4), "decode": round(decode, 2),
            "total": round(total, 2)}

def health_wait(timeout_s=2400):
    t0 = time.time()
    base = URL.rsplit("/v1/", 1)[0]
    while time.time() - t0 < timeout_s:
        try:
            with urllib.request.urlopen(base + "/v1/models", timeout=10) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(15)
    return False

if __name__ == "__main__":
    if not health_wait():
        print(json.dumps({"error": "never healthy"})); sys.exit(1)
    # warm
    one()
    runs = [one() for _ in range(3)]
    print(json.dumps({
        "decode_med": round(median(r["decode"] for r in runs), 2),
        "ttft_med": round(median(r["ttft"] for r in runs), 4),
        "tokens": [r["tokens"] for r in runs],
        "runs": runs,
    }))

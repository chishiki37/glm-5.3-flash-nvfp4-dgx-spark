#!/usr/bin/env python3
"""GLM/Qwen speed battery: single-stream + C4 + C8, median-of-3, streaming, stdlib only.

Env: BENCH_URL (default http://100.102.97.64:8000/v1/chat/completions)
     BENCH_MODEL (default glm-5.3-flash)
     OUT_JSON (default battery_result.json)

Protocol (fleet standard): two-pass warm (warmup pass discarded), fixed prompts,
512 max_tokens, aggregate = sum(completion_tokens)/wall-clock of the concurrent run.
"""
import json, os, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from statistics import median

URL = os.environ.get("BENCH_URL", "http://100.0.0.1:8000/v1/chat/completions")
MODEL = os.environ.get("BENCH_MODEL", "glm-5.3-flash")
OUT = os.environ.get("OUT_JSON", "battery_result.json")

PROMPTS = {
    "prose": ("Write a detailed one-page essay on the history of the transistor, "
              "from its invention at Bell Labs through modern FinFET technology."),
    "code": ("Implement a binary search tree in Python with insert, search, delete, "
             "and in-order traversal methods. Include docstrings and type hints, "
             "and a short usage example at the end."),
}
MAX_TOKENS = 512

def one_request(prompt):
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_TOKENS,
        "stream": True,
        "stream_options": {"include_usage": True},
        "temperature": 0.0,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    first = None
    usage = None
    try:
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
    except Exception as e:
        return {"error": str(e)}
    total = time.perf_counter() - t0
    toks = usage["completion_tokens"] if usage else 0
    ttft = first if first is not None else float("nan")
    decode = (toks - 1) / (total - ttft) if toks > 1 and total > ttft else float("nan")
    return {"tokens": toks, "total_s": round(total, 3), "ttft_s": round(ttft, 4),
            "decode_tps": round(decode, 2), "e2e_tps": round(toks / total, 2)}

def cell(prompt, conc, iters=3):
    runs = []
    for i in range(iters):
        wall0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=conc) as ex:
            results = list(ex.map(lambda _: one_request(prompt), range(conc)))
        wall = time.perf_counter() - wall0
        errs = [r for r in results if "error" in r]
        if errs:
            runs.append({"error": errs[0]["error"]})
            continue
        agg_tokens = sum(r["tokens"] for r in results)
        runs.append({
            "wall_s": round(wall, 3),
            "agg_tps": round(agg_tokens / wall, 2),
            "per_stream_decode_med": round(median(r["decode_tps"] for r in results), 2),
            "ttft_med_s": round(median(r["ttft_s"] for r in results), 4),
            "tokens": [r["tokens"] for r in results],
        })
    ok = [r for r in runs if "error" not in r]
    summary = {
        "concurrency": conc, "prompt_kind": None, "runs": runs,
        "agg_tps_med": round(median(r["agg_tps"] for r in ok), 2) if ok else None,
        "per_stream_med": round(median(r["per_stream_decode_med"] for r in ok), 2) if ok else None,
        "ttft_med_s": round(median(r["ttft_med_s"] for r in ok), 4) if ok else None,
    }
    return summary

def health_wait(timeout_s=2400):
    t0 = time.time()
    base = URL.rsplit("/v1/", 1)[0]
    while time.time() - t0 < timeout_s:
        try:
            with urllib.request.urlopen(base + "/v1/models", timeout=10) as r:
                if r.status == 200:
                    print("endpoint healthy", flush=True)
                    return True
        except Exception:
            pass
        time.sleep(15)
    print("endpoint never became healthy", flush=True)
    return False

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "full"
    if not health_wait():
        sys.exit(1)
    out = {"url": URL, "model": MODEL, "started": time.strftime("%Y-%m-%d %H:%M:%S"),
           "max_tokens": MAX_TOKENS, "cells": []}
    if mode in ("warmup", "full"):
        print("== warmup pass (discarded) ==", flush=True)
        for kind, p in PROMPTS.items():
            for conc in (1, 4, 8):
                print(f"warm {kind} C{conc}", flush=True)
                cell(p, conc, iters=1)
    if mode in ("measure", "full"):
        print("== measure pass ==", flush=True)
        for kind, p in PROMPTS.items():
            for conc in (1, 4, 8):
                print(f"measure {kind} C{conc}", flush=True)
                c = cell(p, conc, iters=3)
                c["prompt_kind"] = kind
                out["cells"].append(c)
                print(f"  -> agg_med={c['agg_tps_med']} per_stream_med={c['per_stream_med']} ttft={c['ttft_med_s']}", flush=True)
    out["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(OUT, "w") as f:
        json.dump(out, f, indent=2)
    print(f"saved {OUT}", flush=True)

if __name__ == "__main__":
    main()

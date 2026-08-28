# Report 05 — TP4 KV Ladder: 16 → 40 GiB, Stress-Gated

**Date:** 2026-08-27 · **Topology:** TP4 · **Config base:** winner t1 (fp8 KV + MTP3), KV slab and `--max-model-len` varied per rung

## Question

The source recipe's same-day update moved from a 9 GiB KV pin to 32 GiB → 5.03M fp8 tokens at 1M context via a "residual-headroom rule" (grow the slab until only ~8–10 GB MemAvailable remains per node). Their 38 GiB attempt famously **booted fine and died on the first 20K-token prefill** — "serving is not the bar." How far can our fleet climb, safely?

## Method — the stress gate

Every rung must pass all four stages or the ladder halts:

1. Boot (worker-first, flushers + `drop_caches`, full teardown between rungs)
2. Decode probe (512 tok, median of 3)
3. **Long-prefill gate: a real 25,176-token prompt** (prompt calibrated at ~83 tok/copy, verified via `usage.prompt_tokens`), `max_tokens 8` — the exact failure class that killed their 38 GiB slab
4. Post-gate sanity probe (engine must still serve a normal request)

Residual MemAvailable logged on all 4 nodes after each boot (the edge-band check).

## Results — all five rungs PASS

| Rung | KV slab | Context | Pool tokens | Concurrency | Decode tok/s | Residual MemAvail GiB (bdea/9105/3b24/cb98) | Gate (25K prefill) |
|---|---:|---|---:|---|---:|---|---|
| L1 | 16 GiB | 262K | 2,298,801 | 8.8× | 42.6 | 36.4 / 35.8 / 36.4 / 31.8 | 30.6 s ✅ |
| L2 | 24 GiB | 262K | 3,448,201 | 13.2× | 40.9 | 28.1 / 27.9 / 28.2 / 25.1 | 30.7 s ✅ |
| L3 | 32 GiB | 262K | 4,597,602 | 17.5× | 39.3 | 20.2 / 19.5 / 19.8 / 15.8 | 33.0 s ✅ |
| L4 | 32 GiB | **1M** | 4,597,602 | 4.6 full-1M reqs | 38.3 | 20.1 / 19.3 / 19.7 / 15.4 | 32.5 s ✅ |
| **L5** | **40 GiB** | **1M** | **5,747,003** | **21.9× / 5.75 full-1M reqs** | 39.6 | 11.8 / 11.4 / 11.7 / **9.0** | 31.0 s ✅ |

## Findings

1. **The fleet passes 40 GiB where the source fleet died at 38 GiB.** The stress gate is the difference-maker — it catches the long-prefill NVRM-OOM class before shipping.
2. **Decode is essentially slab-insensitive:** 42.6 → 39.6 tok/s across a 4.4× pool growth — within probe variance.
3. **Residual headroom behaves linearly:** ~8 GiB slab growth ≈ ~8 GiB residual loss per node. L5 lands cb98 at 9.0 GiB — the bottom of the source fleet's 8–10 GiB edge band. **40 GiB is the production ceiling; do not go higher.**
4. Pool-per-GiB in our stack ≈ 143,675 tok/GiB (bytes/token ≈ 7474) — slightly below the source's implied ~157K tok/GiB at the same 32 GiB slab (block-rounding/metadata differences; same class).

## Verdict

**Production max-capacity config adopted:**

```
--kv-cache-memory 42949672960 --max-model-len 1048576
(+ all winner flags: fp8_e4m3, MTP3, block-size 2304, gmu 0.85, max-num-seqs 6)
```

5,747,003 fp8 KV tokens = **5.75 concurrent full-1M-context requests** on 4× DGX Spark, at 39.6 tok/s single-stream. For 262K-serving with more headroom, L3 (32 GiB / 17.5×) is the comfortable choice.

## Re-gate (2026-08-28): concurrent-prefill stress

Upstream's 2026-08-27 crash forensics showed the single-prefill gate above is **insufficient**: their 32 GiB config passed a single 20K prefill, then NVRM-OOM'd under three overlapping 20K prefills from real traffic (they shipped 24 GiB as a result). We re-ran L3/L4/L5 with a harder gate: the original 25K single prefill **plus** 3× simultaneous 20,925-token prefills, then a post-stress sanity request.

| Rung | Pool | Single gate | 3× concurrent 20K prefill | Residual boot → post-gate (GiB, bdea/9105/3b24/cb98) | Verdict |
|---|---:|---|---|---|---|
| L3 32 GiB @ 262K | 4,597,602 | ✅ 30.4 s | ✅ 67 s wall | 18.6/19.2/19.4/14.7 → 18.2/18.8/19.2/14.2 | **PASS** |
| L4 32 GiB @ 1M | 4,597,602 | ✅ | ✅ | 20.0/19.5/19.6/15.5 → 19.2/18.8/19.5/14.3 | **PASS** |
| L5 40 GiB @ 1M | 5,747,003 | ✅ 30.0 s | ✅ 61 s wall | 11.7/10.9/11.7/6.6 → 11.0/10.4/11.1/5.7 | **PASS** |

**L3 (32 GiB) is the exact config that OOM'd the source fleet under the same 3-way prefill load.** The difference on our fleet is Report 06's `rpc.nfsd -r` fix: the portlist-echo NFS-RDMA registration reclaims ~21 GiB of unified memory on the head node, which is precisely the headroom the concurrent-prefill activation transient demands.

Caveat: L5 now runs the head node to **5.7 GiB residual post-gate** — below the source's 8–10 GiB edge band and close to typical anti-OOM watchdog thresholds. L5 passed, but **L4 (32 GiB @ 1M, ~14–19 GiB residual) is the recommended 1M-context default**; reserve L5 for when 5.75 resident 1M-requests is actually needed and watch cb98 MemAvailable.

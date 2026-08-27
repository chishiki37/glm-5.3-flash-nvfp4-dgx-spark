# Report 04 — TP4 Winner Battery (fp8 KV + MTP3)

**Date:** 2026-08-27 · **Topology:** TP4 (cb98 + 3b24 + 9105 + bdea) · **Config:** sweep winner t1 — fp8_e4m3 KV pinned 9,663,676,416 bytes, MTP3, 262K context

## Question

Does the TP4 winner hold up across concurrency and content type?

## Method

Two-pass protocol (warmup discarded, then measure), median of 3, 512 output tokens, temp 0, thinking off, on-box localhost. Note: the first battery attempt on this config was lost to an infrastructure fault (head-node NFS-RDMA memory stranding — see Report 06); the successful run below was performed after the root-cause fix with identical flags.

## Results

| Cell | Aggregate tok/s | Per-stream tok/s | TTFT s |
|---|---:|---:|---:|
| Prose C1 | 40.00 | 40.60 | 0.216 |
| Prose C4 | 109.96 | 28.28 | 0.285 |
| Prose C8 | **114.35** | 24.37 | 0.337 |
| Code C1 | 40.55 | 41.21 | 0.226 |
| Code C4 | 109.95 | 28.55 | 0.317 |
| Code C8 | 110.91 | 23.94 | 0.353 |

## Findings

1. **Harness consistency:** C1 prose 40.0–40.6 vs sweep probe 38.63 — warm-state uplift, same harness class.
2. **Near-linear scaling to C4** (2.75× aggregate), still climbing at C8 (2.86×) — `--max-num-seqs 6` queues 2 of the 8 streams.
3. **TTFT stays flat** (0.22→0.35 s across the whole grid) — a notably better TTFT-at-concurrency profile than TP2 (which hit 0.74 s at code C8).
4. MTP acceptance under load: mean accept len 2.71–3.03, per-position ~0.83/0.59/0.42, draft acceptance 57–68%.

## Verdict

Validated. vs the source recipe's published TP4 flagship (35.7 tok/s): **+12–14% single-stream, 3.2× at C8 aggregate** on our fleet.

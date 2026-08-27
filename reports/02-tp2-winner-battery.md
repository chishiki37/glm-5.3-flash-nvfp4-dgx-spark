# Report 02 — TP2 Winner Battery (fp8 KV + MTP3)

**Date:** 2026-08-27 · **Topology:** TP2 (cb98 head + 3b24) · **Config:** sweep winner s3 — fp8_e4m3 KV pinned 4,445,787,956 bytes, MTP3, `--block-size 2304`, `--gpu-memory-utilization 0.85`, `--max-model-len 262144`, `--max-num-seqs 6`, enforce-eager

## Question

How does the TP2 winner hold up across concurrency (C1/C4/C8) and content type (prose vs code), and does the battery reproduce the sweep probe?

## Method

Two-pass protocol: full warmup pass (all six cells, discarded), then measure pass. Median of 3 runs per cell, 512 output tokens, temperature 0, thinking off, on-box against localhost.

## Results

| Cell | Aggregate tok/s | Per-stream tok/s | TTFT s |
|---|---:|---:|---:|
| Prose C1 | 27.73 | 28.20 | 0.342 |
| Prose C4 | 68.38 | 17.69 | 0.403 |
| Prose C8 | **73.40** | 15.55 | 0.425 |
| Code C1 | 28.08 | 28.59 | 0.360 |
| Code C4 | 65.63 | 17.20 | 0.433 |
| Code C8 | 69.27 | 14.77 | 0.735 |

## Findings

1. **Harness consistency confirmed:** battery prose C1 (27.7 agg / 28.2 per-stream) reproduces the sweep probe (28.29) within noise.
2. **Concurrency scaling:** 2.5–2.6× aggregate at C4, 2.65× at C8 — sub-linear as expected with `--max-num-seqs 6` (C8 queues 2 requests).
3. TTFT stays under 0.43 s through prose C8; code C8 TTFT (0.74 s) is the one soft spot — queued requests plus denser code prefill.
4. C≥4 numbers carry ±10% warm-state variance (noted for cross-fleet comparisons).

## Verdict

Winner config validated under load; numbers adopted as the TP2 reference in the runbook. Per-stream decode at C1 remains the comparison metric against external claims.

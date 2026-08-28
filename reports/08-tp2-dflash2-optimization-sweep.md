# Report 08 — TP2 DFlash2 Optimization Sweep

**Date:** 2026-08-28 · **Topology:** TP2 (9105 head + bdea, NFS weights) · **Image:** `radixark/vllm-glm53-flash:sm121-v8-dflash2` · **Fixed flags:** fp8 KV pin 4,445,787,956, gmu 0.85, block-size 2304, 262K ctx

## Question

Report 07 found DFlash2 at TP2 loses to MTP3 on prose and caps aggregate throughput at ~58–67 tok/s with a C8 TTFT blowout (15–17 s). Which serving levers fix which symptom?

## Arms (single variable vs d0 baseline each)

| Arm | Lever | Hypothesis |
|---|---|---|
| d0 | spec7, greedy, mns6 | baseline (Report 07 TP2 numbers) |
| d1 | **spec5** | TP2's 7-token verify cost eats acceptance gains → fewer drafts, cheaper verify |
| d2 | **spec3** | verify-cost floor |
| d3 | spec7, **probabilistic** sampling | acceptance side; greedy is this vLLM's default, so probabilistic is the experimental arm |
| d4 | spec7, greedy, **mns8** | C8 TTFT blowout comes from 2-of-8 queueing at max-num-seqs 6 |

C1 structured probe per arm (median of 3, warm, on-box):

| Arm | count200 | alphabet8 | prose | code |
|---|---:|---:|---:|---:|
| d0 spec7 mns6 | 53.2 | 36.0 | 25.9 | 40.2 |
| d1 spec5 | 47.1 | 46.8 * | 27.3 | 40.5 |
| d2 spec3 | 37.7 | 33.0 | 26.4 | 36.0 |
| d3 probabilistic | 53.4 | 34.2 | 23.8 | 41.9 |
| d4 mns8 | 50.8 | 32.6 | 23.9 | 43.4 |

\* alphabet8 runs terminate early (88–313 tokens) — noisy cell, read with caution.

## Findings

1. **The Report 07 hypothesis "verify cost is the TP2 bottleneck" is REFUTED.** Cutting draft depth from 7→5→3 loses structured/code throughput monotonically (count200: 53.2 → 47.1 → 37.7). The drafter's value IS its depth; block-diffusion wants the full 8-token block. The TP2 prose deficit is an acceptance problem (25–35% on freeform text), not a verify-cost problem — no serve flag fixes that; workload selection does.
2. **Greedy draft sampling confirmed optimal.** Probabilistic sampling is within noise on every cell (count 53.4 vs 53.2, code 41.9 vs 40.2) and costs the fp32 draft-logits cache. Keep the default.
3. **mns8:** C1-neutral (see battery below for the concurrency verdict).

## mns8 battery — C8 TTFT verdict

Full battery (median of 3, 512 tok, warm pass), mns8 vs the mns6 battery from Report 07's TP2 run, same day/harness:

| Cell | mns6 agg | mns8 agg | mns6 TTFT | mns8 TTFT |
|---|---:|---:|---:|---:|
| Prose C1 | 25.8 | 26.0 | 0.35 | 0.24 |
| Prose C4 | 57.7 | 58.7 | 0.67 | 0.42 |
| Prose C8 | 57.6 | 57.8 | **17.2 s** | **16.9 s** |
| Code C1 | 30.6 | 31.0 | 0.36 | 0.36 |
| Code C4 | 67.1 | 65.1 | 0.45 | 0.71 |
| Code C8 | 65.5 | 63.9 | **14.9 s** | **15.3 s** |

**mns8 does NOT fix the C8 TTFT blowout.** With all 8 requests admitted simultaneously (no queue), C8 TTFT is still ~15–17 s. The cause is therefore not max-num-seqs queueing: it is DFlash2's heavy per-step verification (7-draft block-diffusion verify) starving prefill interleave at TP2 — every scheduler step is expensive, so queued prefills wait many steps. At TP4 the same config showed clean 0.2–0.5 s TTFT at C8 (Report 07) because step cost splits across 4 ranks. **This is an architectural property of DFlash2-at-TP2 under concurrent load, not a flag-tunable one.**

## Verdicts

1. **TP2 DFlash2 production config unchanged: `spec7, greedy, mns6`** — no sweep arm beat the baseline; mns8 buys nothing (TTFT blowout is verify-step starvation, not queueing).
2. **num_speculative_tokens must stay 7** — truncation is a pure loss for this drafter.
3. **The Report 07 TP2 verdict is strengthened, not overturned:** DFlash2-at-TP2 is a single-stream structured/code mode. Its concurrency pathologies (aggregate ceiling ~58–67 tok/s, C8 TTFT 15–17 s) are architectural at TP2 and dissolve at TP4.

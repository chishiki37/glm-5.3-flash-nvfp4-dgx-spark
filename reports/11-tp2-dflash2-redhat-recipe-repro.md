# Report 11 — TP2 262K DFlash2 Lane on Clean Weights + Upstream Recipe Reproduction

**Date:** 2026-08-31 · **Topology:** TP2 (3b24 head + cb98, NFS weights from cb98) · **Image:** `radixark/vllm-glm53-flash:sm121-v8-dflash2` · **Fixed flags:** RedHatAI compressed-tensors, gmu 0.88, fp8 KV pin 5,325,147,587, block 2304, 262K ctx, k=7, mnbt 8192

## Question

Report 08 established the TP2 DFlash2 production config (`spec7, greedy, mns6`) on the then-current ModelOpt weights. With the Report 10 swap to corruption-free compressed-tensors weights, re-sweep the TP2 lane and test whether our measured throughput reproduces the upstream 2×-Spark recipe it is based on.

## TP2 sweep (our prose/code battery, 4 cells)

All cells: KV pin 5,325,147,587 (sized so 262K ctx clears with ~1.86× concurrency headroom), gmu 0.88. Battery: C1×2 + C4 + C8, e2e, temp 0, 256 tokens. KV pool: **488,656 tokens**.

| cell | knobs | C1 (tok/s) | C4 agg | C8 agg |
|---|---|---|---|---|
| T0-repo-default | mns 6, eager | 21.21 / 19.06 | 31.64 | 37.59 |
| T1-mns8 | mns 8 | 18.91 / 17.61 | 29.11 | 30.72 |
| T2-noeager | mns 6, no eager | 18.48 / 19.19 | 32.12 | 39.65 |
| T3-combo | mns 8, no eager | 25.63 / 20.46 | **34.85** | **39.73** |

T3-combo wins. Note the absolute C1 here (~20–26) is our low-acceptance **prose/freeform** battery — Report 08's finding that DFlash2-at-TP2 is a single-stream structured/code mode, not a prose mode. That matters for the comparison below.

## Upstream recipe reproduction (code/reasoning prompts)

The upstream recipe's headline numbers were measured with **code/reasoning-flavored prompts** (realistic draft-acceptance). To compare like-for-like we ran the same class of harness — `bench_c1c6.py`, code/reasoning prompts, temp 1.0, 400 tokens, concurrency 1→6 — against the live T3-combo engine.

| concurrency | upstream agg tok/s | ours agg tok/s | ours per-stream | Δ (ours vs upstream) |
|---|---|---|---|---|
| C1 | 35.1 | **38.7** | 38.8 | **+10%** |
| C2 | 41.6 | **42.8** | 24.0 | +3% |
| C3 | 40.6 | **44.8** | 18.3 | +10% |
| C4 | 47.5 | **54.7** | 17.0 | +15% |
| C5 | 56.2 | **63.7** | 15.2 | +13% |
| C6 | 47.7 | **61.1** | 13.1 | **+28%** |

**We match or better the upstream recipe at every concurrency level (C1–C6), on identical prompt class, zero failures.** Draft-acceptance ratio over the window ran 0.39–0.55 (vs upstream's quoted 0.741 single-stream), consistent with a mixed code/reasoning batch vs a best-case prompt.

## Findings

1. **Recipe reproduces.** On clean weights and a code/reasoning prompt class, the TP2 DFlash2 lane meets or exceeds the upstream 2×-Spark numbers across the entire C1–C6 sweep — best gap +28% at C6. The deployment is faithful to its source recipe.
2. **The apparent TP2 "slowness" is prompt-class, not a regression.** The same engine that does ~20–26 tok/s on freeform prose (T3 C1 above) does ~39 tok/s single-stream on code/reasoning. DFlash2 acceptance is content-driven (Report 08); quote the prompt with any number.
3. **Clean weights carried no speed cost.** The corruption fix (Report 10) is throughput-neutral here — the acceptance tax belongs to the abliterated variant (Report 09), not to compressed-tensors vs ModelOpt.
4. **Operational:** this sweep ran head on 3b24 (.12) — **not** 9105 (.1). See Report 12: a TP2 rank + co-resident controller stack OOM'd .1 twice; .1 is banned for TP2 rank duty.

Raw per-cell JSONs + sweep log + upstream-prompt bench: [`results/redhat_tp2_lane/`](../results/redhat_tp2_lane/).

# Report 01 — TP2 Autoresearch Sweep

**Date:** 2026-08-27 · **Topology:** TP2 (aitopatom-cb98 head + edgexpert-3b24) · **Image:** `radixark/vllm-glm53-flash:sm121-v8` (local build)

## Question

Which serving-parameter combination maximizes single-stream decode for GLM-5.3-Flash NVFP4 on a 2-node Spark pair — and does the source recipe's flagship (fp8 KV + MTP4) hold up on our fleet?

## Method

- On-box probes against `http://127.0.0.1:8000` on the head (no tailnet hop in timing)
- Prose prompt, 512 output tokens, temperature 0, thinking off, median of 3 runs
- Full teardown + `drop_caches` + cache-flusher sidecar before every arm
- KV pinned to vLLM's suggested value for MTP arms (the KV-ladder doctrine: GB10's NVRM allocator grants KV from MemFree only and fails fast; unpinned MTP boots die)

## Config matrix & results

| Arm | KV dtype | KV pin | MTP | Decode tok/s | TTFT s | KV pool tokens |
|---|---|---|---|---:|---:|---:|
| s0 (their day-1 baseline) | bf16 | — | off | 14.75 | 0.252 | 588,225 |
| s1 | fp8_e4m3 | — | off | 14.65 | 0.229 | ~1,020,772 |
| s2 (their TP2 flagship) | fp8_e4m3 | 4,445,787,956 (4.14 GiB) | 4 | 25.99 | 0.266 | 507,041 |
| **s3 — winner** | fp8_e4m3 | 4,445,787,956 (4.14 GiB) | **3** | **28.29** | 0.338 | 527,879 |

Per-arm runs: s0 [14.78, 14.71, 14.75] · s1 [14.68, 14.65, 14.65] · s2 [26.36, 25.99, 25.20] · s3 [28.29, 28.45, 27.37]

## Findings

1. **bf16 baseline reproduces the source claim**: 14.75 vs their published 14.3 (+3%) — the fleet and harness track the source methodology.
2. **fp8 KV alone buys nothing for speed** (14.65 vs 14.75) but **doubles the KV pool** (1.02M vs 588K tokens) — the draft head's absence leaves +5 GiB of headroom.
3. **MTP is the big lever**: +77% decode over no-MTP at fp8 KV.
4. **MTP3 beats MTP4: 28.29 vs 25.99 (+8.8%)** — the sweep's headline result. Per-position acceptance shows why: position 4 drafts were accepted only ~0.18 of the time, so the fourth token mostly paid verification cost without returning tokens. (TP2 rates ≈ 0.83 / 0.59 / 0.34 / 0.18; mean accept len 2.83–2.97.)
5. Arm s3's pool (527,879) is slightly larger than s2's (507,041): fewer speculative slots reserved → more KV headroom.

## Verdict

**s3 (fp8 KV pinned 4.14 GiB + MTP3) adopted as the TP2 production config**, beating the source recipe's own flagship (21.8 tok/s published) by +30% on our fleet. Proceeds to the winner battery → [Report 02](02-tp2-winner-battery.md).

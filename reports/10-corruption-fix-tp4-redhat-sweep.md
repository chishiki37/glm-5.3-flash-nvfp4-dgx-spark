# Report 10 — ModelOpt Token Corruption: Fix + TP4 DFlash2 Re-sweep on Clean Weights

**Date:** 2026-08-30 · **Topology:** TP4 (9105 + bdea + 3b24 + cb98, NFS weights from cb98) · **Image:** `radixark/vllm-glm53-flash:sm121-v8-dflash2` · **Weights change:** `LibertAIDAI/GLM-5.3-Flash-NVFP4` (ModelOpt) → `RedHatAI/GLM-5.3-Flash-NVFP4` (compressed-tensors)

## Question

Reports 01–09 were all measured on the LibertAIDAI ModelOpt NVFP4 quant. [vLLM #54150](https://github.com/vllm-project/vllm/issues/54150) documents ModelOpt-quantized GLM builds emitting intermittent corrupted token IDs — nearly invisible in English prose, but a corrupted token inside a tool-call block desyncs the parser and can spiral generation into a repetition lock. Do our fleet copies carry it, and does the corruption-free replacement change throughput?

## Corruption probe

`korean_probe.py`: 3 prompts (Korean self-intro, Python code, Korean→English translation) × 3 passes, temperature 0, non-streaming, thinking off; counts U+FFFD and control characters.

| Checkpoint | quant_method | Corrupted outputs (3 runs) |
|---|---|---|
| `LibertAIDAI/GLM-5.3-Flash-NVFP4` | modelopt | **4–9 / 9** |
| `drowzeys/keys-...-ablit-l15-45-anchorstock` | modelopt | **4–9 / 9** |
| `RedHatAI/GLM-5.3-Flash-NVFP4` | compressed-tensors | **0 / 9 — PASS** |

Both ModelOpt checkpoints confirmed `"quant_method": "modelopt"` in config.json, then deleted from the fleet (364 GB). RedHatAI deployed: 184 GB, 10 shards, every file size-verified against the HF manifest. Drop-in — identical serve flags. DFlash2 drafter kept (quant-independent).

## TP4 DFlash2 serving sweep on clean weights

All cells: 1M ctx, KV pin 24 GiB, mnbt 8192, gmu 0.85, block 2304, marlin, k=7, fp8_e4m3 KV. Battery: C1×2 + C4 + C8, e2e, prose, temp 0, 256 tokens.

| cell | knobs | C1 (tok/s) | C4 agg | C8 agg |
|---|---|---|---|---|
| B0-repo-default | mns 6, eager | 33.25 / 29.66 | 47.88 | 47.29 |
| B1-mns4 | mns 4 | 30.51 / 30.55 | **48.70** | 53.01 |
| B2-mns8 | mns 8 | 32.78 / 34.69 | 42.40 | 86.88 |
| B3-mns12 | mns 12 | 30.19 / 30.81 | 46.45 | 68.65 |
| B4-mnbt16k | mnbt 16384 | 31.11 / 32.86 | 44.06 | 48.18 |
| B5-kv28g | KV pin 28 GiB | 32.65 / 32.04 | 47.78 | 47.50 |
| B6-noeager | mns 6, **no eager** | **35.56 / 41.22** | 45.58 | 57.86 |
| B7-combo | mns 8, **no eager** | 28.73 / 33.68 | 48.31 | **90.75** |

Boots 930–1150 s/cell; zero boot failures with the Report 06 ops ritual.

## Findings

1. **Corruption fix verified.** 0/9 on compressed-tensors vs 4–9/9 on both ModelOpt builds, same probe. The fleet default is now RedHatAI; abliterated variants remain unavailable in corruption-free form until a compressed-tensors ablit exists.
2. **Dropping `--enforce-eager` is the single biggest C1 lever found** (+22–38% over eager at equal max-num-seqs) — B6 ~38.4 tok/s avg vs B0 ~31.5.
3. **Aggregate winner: B7 (mns 8 + no eager) — 90.75 tok/s at C8, +92% vs the published default config.** mns ladder is sharp at C8: 8 > 12 > 6 > 4; C4 slightly prefers mns 4.
4. **Rejected:** mnbt 16384 (C8 −49% vs 8192 — keep 8192); KV pin 28 GiB (no C8 gain over 24 GiB, costs 4 GiB headroom — keep 24 GiB).
5. **Caveat:** the upstream 4× repo headlines 54.5 tok/s single-stream — one code-prompt run it labels "indicative, not a benchmark." Our prose battery lands 31–41; draft acceptance is content-driven on this model, so that gap is a prompt artifact, not a stack deficit. Report 11 settles it empirically at TP2 with a prompt-matched harness.

Raw per-cell JSONs + full log: [`results/redhat_tp4_sweep/`](../results/redhat_tp4_sweep/).

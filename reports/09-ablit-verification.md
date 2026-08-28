# Report 09 — Abliterated GLM-5.3-Flash NVFP4 (drowzeys keys-anchorstock): speed cost, refusal, and correctness

**Date:** 2026-08-28 · **Weights:** `drowzeys/keys-GLM-5.3-Flash-NVFP4-ablit-l15-45-anchorstock` (182 GB, 120 shards, gated) · **Image:** `radixark/vllm-glm53-flash:sm121-v8` (+ `-dflash2` variant for the DFlash2 arm)

## Question

An abliterated NVFP4 GLM-5.3-Flash claims full uncensoring (32/32 refusal bypass, 0 refuses) at 22.3 tok/s C1 on the publisher's box. Three questions on our fleet: (1) what is the **speed cost** of the abliteration on our tuned topologies, (2) does the **refusal claim verify** under our stack, (3) is **reasoning intact** (GSM8K)?

## What the weights actually are

From the repo's `ABLIT_META.json` + `METHOD.md` (verified against the download):

- **Method:** dealign-oproj-transplant — `LibertAIDAI/GLM-5.3-Flash-NVFP4` body with `dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4` **BF16 `o_proj` tensors byte-copied into layers 15–45** (31 tensors, **MTP layer included**), L0–14 stock, experts/QKV/vision untouched.
- Mean weight delta 0.126 relative Frobenius; L44 is Dealign's own 0.737 outlier.
- Publisher's motivation: residual refusal on GLM-5.3 lived **late + in the MTP head** — early-layer-only edits (their "Blackfrost" attempts, 6–9/32 bypass) never cleared it; keeping MTP stock let the draft head keep proposing refusals. Hence the deliberate MTP edit.
- Config + chat template **byte-identical** to our stock LibertAI NVFP4 reference — same launcher flags work unchanged.

## TP4 MTP3 battery (winner config t1, unchanged)

fp8 KV pin 9,663,676,416 B, MTP3, gmu 0.85, block-size 2304, max-num-seqs 6, 262K ctx. Same two-pass battery as Report 04 (C1/C4/C8 × prose/code, 512 tok, temp 0, median of 3, on-box).

| Cell | Stock (Rep 04) | Ablit | Δ |
|---|---:|---:|---:|
| Prose C1 | 40.6 | 34.9 | −14.1% |
| Prose C4 | 28.3 | 25.0 | −11.7% |
| Prose C8 | 24.4 | 21.2 | −13.0% |
| Code C1 | 41.2 | 36.4 | −11.7% |
| Code C4 | 28.6 | 25.5 | −10.9% |
| Code C8 | 23.9 | 21.0 | −12.2% |

(Aggregate: prose C8 99.1 vs 114.4 tok/s; code C8 99.0 vs 110.9.)

**Root cause — speculative acceptance.** MTP acceptance telemetry under battery load:

- Stock (Rep 04): 57–68% avg draft acceptance, mean accept length 2.71–3.03
- Ablit: **46–59% avg acceptance, mean accept length 2.37–2.78**

The transplanted L45 `o_proj` (the MTP head) drafts slightly differently than stock, so the target verifies fewer of its proposals. TTFT is unchanged across the grid (0.17–0.53 s) — prefill is untouched; the tax is decode-only, exactly where MTP lives. This is the measured price of editing MTP to kill draft-head refusal.

## Refusal battery — two tiers

**Tier 1 (soft, 12 prompts):** benign-but-edgy content (fiction crime/violence, security explainers, dual-use chemistry, political opinion, OSINT, medical/legal candor, + benign control).

- Ablit: 0/12 refused (100% compliance)
- **Stock: also 0/12 refused** — the soft tier does not discriminate; stock already complies on edgy-but-legal content under this serving config (thinking off, no system prompt).

**Tier 2 (hard, 6 prompts):** items safety-tuned models reliably refuse (working ransomware, phishing kit with fake login URL, methamphetamine synthesis route with reagents/quantities, household explosive device, carding guide, unauthorized WPA2 intrusion). Added after Tier 1 failed to discriminate; run on both models with identical flags.

- **Stock: 6/6 refused (0% compliance)**
- **Ablit: 0/6 refused (100% compliance)**

Perfect discrimination on the hard tier. Scoring note: stock refuses **late** — it emits a long deliberation preamble ("The user is asking me to…") before the actual refusal, so refusal-pattern scoring must scan the full response text; scanning only the first ~600 chars mis-scores 3/6 as compliance. Ablit responses also carry deliberation-style preambles but proceed to comply.

The publisher's gate (32/32 bypass, 0 refuse, raw vLLM) is consistent with our hard-tier result.

## GSM8K (logic preservation)

50 questions, temp 0.2, thinking off, max 4096 tokens, same harness on both models:

- **Ablit: 49/50 = 98.0%**
- **Stock: 49/50 = 98.0%**

Identical. The abliteration does not measurably damage grade-school reasoning.

## TP2 MTP3 battery (winner config s3, unchanged)

fp8 KV pin 4,445,787,956 B, MTP3, cb98 + 3b24. Same battery as Report 02:

| Cell | Stock (Rep 02) | Ablit | Δ |
|---|---:|---:|---:|
| Prose C1 | 28.2 | 24.5 | −13.1% |
| Prose C4 | 17.7 | 14.6 | −17.6% |
| Prose C8 | 15.6 | 12.6 | −18.8% |
| Code C1 | 28.6 | 25.2 | −12.0% |
| Code C4 | 17.2 | 15.1 | −12.3% |
| Code C8 | 14.8 | 13.0 | −11.8% |

The tax is **larger at TP2 than TP4** (−12 to −19% vs −11 to −14%), worst at prose high-concurrency: at TP2 the speculative verify/redo bandwidth is tighter, so each rejected draft costs more of the stream.

## Autoresearch re-sweep on ablit weights

Stock winner configs were inherited initially, then re-swept on the ablit weights (same arms as Reports 01/03, single C1 probe per arm, on-box).

**TP2 (cb98 + 3b24):**

| Arm | Stock (Rep 01) | Ablit | Δ |
|---|---:|---:|---:|
| bf16-nomtp | 14.75 | 14.52 | −1.6% |
| fp8-nomtp | 14.65 | 14.51 | −1.0% |
| fp8-mtp4 | 25.99 | 21.68 | −16.6% |
| fp8-mtp3 | 28.29 | 25.38 | −10.3% |

**The headline isolation:** raw decode (no speculation) is at stock parity (−1 to −2%, within noise). The abliteration did not slow the base model. The entire battery tax is speculative-decode mismatch, and it scales with draft depth: nomtp −1% → mtp3 −10% → mtp4 −17%. Each extra drafted position is another position where the transplanted `o_proj` activations diverge from what the (stock-trained) acceptance path expects.

**Ranking unchanged:** MTP3 still wins at TP2 (25.38 > 21.68 > 14.5); fp8 KV still free. No config-level recovery exists — the loss is intrinsic to the weight edit, and spec=0 is the only lever (at the cost of the speedup itself).

**TP4 (cb98 + 3b24 + 9105 + bdea):**

| Arm | Stock (Rep 03) | Ablit | Δ |
|---|---:|---:|---:|
| fp8-mtp4 | 38.18 | 34.48 | −9.7% |
| fp8-mtp3 | 38.63 | 35.78 | −7.4% |
| nomtp | (crashed) | (crashed) | — |

Same verdict as TP2: **MTP3 still wins; ranking unchanged.** The nomtp arm crashes with `Executor failed` on this image at TP4 **identically for stock and ablit** (it also failed in the original campaign, Report 03) — image-level limitation, not an abliteration effect. Raw decode separation therefore rests on the TP2 arms, where it is unambiguous (−1 to −2% = parity).

## TP4 DFlash2 (stock-trained drafter vs abliterated target)

Same flags as Report 07's TP4 arm (dflash, num_speculative_tokens 7, fp8 KV 9 GiB pin). The open question: the DFlash2 drafter (`incoai/GLM-5.3-Flash-DFlash2`) was trained against **stock** activations; the target's L15–45 `o_proj` are now Dealign's. Does acceptance survive the mismatch?

**Yes — dramatically better than MTP.** Per-stream tok/s:

| Cell | Stock DF2 (Rep 07) | Ablit DF2 | Δ | vs Ablit MTP3 |
|---|---:|---:|---:|---:|
| Prose C1 | 41.6 | 40.1 | **−3.6%** | 34.9 (+15%) |
| Prose C4 | 26.0 | 22.9 | −11.9% | 25.0 |
| Prose C8 | 21.6 | 18.9 | −12.5% | 21.2 |
| Code C1 | 45.6 | 45.5 | **−0.2%** | 36.4 (+25%) |
| Code C4 | 29.3 | 26.3 | −10.1% | 25.4 |
| Code C8 | 23.5 | 21.6 | −7.8% | 21.0 |

Acceptance telemetry under battery load: 29–46% avg per-position acceptance, mean accept length 3.0–4.2 — essentially the same as stock DFlash2's TP4 numbers in Report 07 (31–49%, 3.2–4.4). The separately-trained block-diffusion drafter is robust to the `o_proj` transplant; the edited **MTP head** is where the tax lives.

**Verdict flip at C1.** On stock weights, MTP3 and DFlash2 were near-parity at prose C1 (40.6 vs 41.6) with DFlash2 ahead only on code. On ablit weights, MTP3 fell 12–14% while DFlash2 fell 0–4%, so **DFlash2 becomes the ablit C1 config at TP4**: 45.5 tok/s code (−0.2% vs stock DFlash2 — abliteration is effectively free for this workload) and 40.1 prose. DFlash2's concurrent-aggregate penalty (Reports 07/08) persists, so MTP3 remains the concurrency/aggregate choice.

## Verdicts

1. **Uncensoring verified.** Hard tier: stock 6/6 refuse → ablit 0/6 refuse; GSM8K identical (98% vs 98%). The weight edit buys full hard-prompt compliance without measurable reasoning loss.
2. **The speed cost is a speculative-decode tax, not a slower model.** Raw decode (no spec) is at stock parity at TP2 (14.5 vs 14.7 tok/s, −1 to −2%). The transplanted MTP head (L45 `o_proj`) loses draft acceptance (TP4: ~60% → ~50%; TP2: 54–68% → 37–49%), costing −7 to −19% on speculative configs, scaling with draft depth and hitting TP2 prose-C8 hardest (−18.8%).
3. **Winner configs don't change** — MTP3 still beats MTP4 at both scales; fp8 KV still free — but **DFlash2 becomes the ablit flagship at TP4 C1**: its separately-trained drafter is robust to the transplant (code C1 45.5 tok/s, −0.2% vs stock DFlash2; prose C1 −3.6%). For single-stream code/agentic serving of ablit weights, abliteration is effectively free. MTP3 retains the concurrency/aggregate slot at both scales; DFlash2's C4/C8 penalty persists.
4. **Recommendation:** serve ablit TP4 DFlash2 (spec7, fp8 KV 9 GiB pin) for interactive/agentic workloads; ablit TP4 MTP3 for concurrent throughput. TP2 remains a 2-node fallback at −10% (MTP3) with the same acceptance caveat. Expect ~−7 to −14% vs stock on speculative configs; ~0% on raw decode.

## Reproduce

- Launchers: `scripts/launch_tp4_ablit.sh`, `scripts/launch_tp2_ablit.sh`, `scripts/launch_tp4_ablit_dflash2.sh` (stock launchers with the model path swapped; served name `glm-5.3-flash-ablit`)
- Batteries/sweeps: `scripts/battery_tp4_ablit.sh`, `scripts/battery_tp2_ablit.sh`, `scripts/sweep_tp2_ablit.sh`, `scripts/sweep_tp4_ablit.sh`, `scripts/battery_tp4_ablit_dflash2.sh`
- Refusal + GSM8K harnesses: `scripts/refusal_bench.py`, `scripts/refusal_bench_hard.py`, `scripts/gsm8k_benchmark.py`
- Raw results: `results/ablit/` (batteries, sweep jsonl, refusal jsonl, GSM8K json)

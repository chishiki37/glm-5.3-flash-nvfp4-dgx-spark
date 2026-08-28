# Report 07 — DFlash2 Speculative Decoding Port (TP2 + TP4)

**Date:** 2026-08-28 · **Image:** `radixark/vllm-glm53-flash:sm121-v8-dflash2` (upstream `tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark` overlay applied verbatim to our v8 base — all 4 guarded patches clean) · **Drafter:** `incoai/GLM-5.3-Flash-DFlash2` (2.2 GB, block-diffusion, block_size 8 → `num_speculative_tokens 7`)

## Question

The upstream repo's day-0 stack is the one our Reports 01–06 built on; its new addition is DFlash2 speculative decoding, published only at TP2 (46.9 tok/s C1 code vs 21.8 MTP-4). Two questions: (1) does DFlash2 beat our MTP3 winner on our fleet, and (2) what happens at TP4, which upstream never ran?

## Method

- Single-variable A/B: identical flags to sweep winners s3 (TP2) and t1 (TP4) — same fp8 KV pins (4,445,787,956 / 9,663,676,416 B), gmu 0.85, block-size 2304, max-num-seqs 6 — only the speculative method swapped MTP3 → DFlash2.
- Pre-boot: upstream's KV-geometry simulation harness run inside the image — **all checks passed** (drafter SWA block rescaled 2048→2304, real page == MLA page, no padding, per-block pool cost bit-identical).
- Startup signatures verified on every boot: `Using Eagle3 auxiliary layers from config: (6, 15, 25, 34, 43)`, rejection-sampler warmup at num_spec=7.
- Same two-pass battery as Reports 02/04 (C1/C4/C8 × prose/code, 512 tok, temp 0, median of 3, on-box) plus a structured-output C1 probe (count 1→200, alphabet ×8) mirroring upstream's re-bench conditions.

## TP2 results (9105 + bdea, NFS-mounted weights)

Battery vs Report 02 (MTP3):

| Cell | MTP3 | DFlash2 | Δ |
|---|---:|---:|---:|
| Prose C1 | 27.7 | 25.8 | −7% |
| Prose C4 | 68.4 | 57.7 | −16% |
| Prose C8 | 73.4 | 57.6 | −22% |
| Code C1 | 28.1 | 30.6 | +9% |
| Code C4 | 65.6 | 67.1 | +2% |
| Code C8 | 69.3 | 65.5 | −5% |

Structured C1: count200 **53.2 tok/s**, code prompt 40.2, prose 25.9. TTFT at C8 blew out to 15–17 s (MTP3: 0.4–0.7 s) — DFlash2's TP2 aggregate ceiling sits ~58–67 tok/s, consistent with upstream's own C5 ≈ 56.2 peak.

**TP2 verdict: rejected as default.** MTP3 keeps the TP2 production slot; DFlash2's TP2 win is confined to single-stream structured output.

## TP4 results (cb98 + 3b24 + 9105 + bdea)

Battery vs Report 04 (MTP3):

| Cell | MTP3 | DFlash2 | Δ |
|---|---:|---:|---:|
| Prose C1 | 40.0 | 41.2 | +3% |
| Prose C4 | 110.0 | 99.5 | −9.5% |
| Prose C8 | 114.4 | 103.8 | −9% |
| Code C1 | 40.6 | 45.0 | +11% |
| Code C4 | 110.0 | 110.2 | +0.2% |
| Code C8 | 110.9 | 113.2 | +2% |

Structured C1 (the probe's prompt set): count200 **84.1 tok/s**, alphabet 73.5, code **70.1** (vs MTP3's ~40 single-stream — up to 2.1×), prose 38.5 (parity with MTP3's 40.0). TTFT clean across the grid (0.21–0.53 s) — no TP2-style queue blowout.

**Why TP4 flips the verdict:** DFlash2 verifies 7 draft tokens per step; at TP2 that verification cost ate the acceptance advantage on everything but highly-predictable text. At TP4 the verification compute splits across 4 ranks, so the drafter cashes out: C1 wins in every category, code wins at all concurrencies, and even prose is parity at C1.

## Acceptance telemetry

- TP2: structured outputs 57–65% draft acceptance (mean accept length ~5.5 of 7); freeform prose 25–35%.
- TP4 under battery load: 31–49% acceptance, mean accept length 3.2–4.4 (vs MTP3's 2.6–3.0 at 54–68% per-token acceptance — DFlash2 drafts 7 positions, so net accepted tokens per verify step stays higher despite lower per-position rates).
- Confirms upstream's central finding: acceptance tracks output predictability. Structured/agentic output (tool args, lists, counts) lives in the high-acceptance zone; freeform prose does not.

## KV pool impact

Per-block KV cost is **zero** (sim-verified; the drafter slot-shares MLA tensors). Measured pool still shrinks vs the same pin due to runtime buffers (draft logits cache, selector codebooks): TP2 527,879 → 427,990 tokens (−19%) at the 4.14 GiB pin; TP4 pool at the 9 GiB pin: 1,182,184 tokens.

## Verdicts

1. **TP4: DFlash2 adopted as the code/agentic flagship config** — C1 wins everywhere, code wins at all concurrencies, up to 2.1× on structured output. Launch: `launch_tp4_dflash2.sh` (image `sm121-v8-dflash2`, `--speculative-config '{"method":"dflash","model":"/models/dflash2-draft","num_speculative_tokens":7}'`, drafter mounted from `/home/vikassridhar/models/GLM-5.3-Flash-DFlash2`).
2. **TP4 prose-heavy multi-user:** MTP3 retained (−9% prose-C8 aggregate with DFlash2).
3. **TP2: MTP3 retained**; DFlash2 available as a structured-output mode only.
4. vs upstream's TP2 claims we ran ~13% lower on like-for-like prompts (NFS-mounted weights + prompt-text differences), but the shape of every result reproduced.

## Credits

Overlay, patches, drafter integration, and the KV-layout fast-path fix: [tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark). TP4 evaluation is new in this report — upstream had not run DFlash2 beyond TP2.

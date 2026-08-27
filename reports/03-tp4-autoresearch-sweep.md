# Report 03 — TP4 Autoresearch Sweep

**Date:** 2026-08-27 · **Topology:** TP4 (cb98 head + 3b24 + 9105 + bdea) · **Image:** `sm121-v8` · **KV pin:** 9,663,676,416 bytes (9 GiB, vLLM-suggested)

## Question

Does the TP2 finding (MTP3 > MTP4) survive at 4-node scale, and what does the source recipe's TP4 flagship (fp8 KV + MTP4, 35.7 tok/s published) measure on our fleet?

## Method

Same harness as the TP2 sweep (on-box, 512 tok, temp 0, thinking off, median of 3, full teardown between arms). Worker-first launch order (ranks 3→2→1, head last, ~22 s apart). Fleet-specific fix applied vs the source launcher: `NCCL_IB_GID_INDEX` omitted — bdea's IPv4 RoCE GID sits at index 4–5 while the other nodes are at 2–3; hardcoding the source's `=3` makes bdea pick a link-local GID → `ibv_modify_qp failed with 22` → all-rank rendezvous death (validated across 4 boots with the var omitted).

## Config matrix & results

| Arm | MTP | Decode tok/s | TTFT s | KV pool tokens |
|---|---|---:|---:|---:|
| t0 (their flagship) | 4 | 38.18 | 0.223 | 1,263,415 (~1.26M) |
| **t1 — winner** | **3** | **38.63** | 0.216 | **1,292,571** (4.93× @262K) |

Per-arm runs: t0 [41.29, 37.86, 38.18] · t1 [39.97, 38.63, 37.84]

A third arm (bf16 KV, no MTP, unpinned) was attempted and rejected: it profiled 50.37 GiB KV-available, attempted the ~50 GiB single-slab allocation, and died in the allocator — the KV-ladder mechanism at TP4 scale (and the event that wedged the head node; see Report 06). It confirmed the doctrine rather than competing: **every sweep arm must pin `--kv-cache-memory`**.

## Findings

1. **Both completed arms beat the source's 35.7 tok/s TP4 headline on our fleet** (38.18 / 38.63, +7–8%) — same config family, fabric and node differences account for the gap.
2. **MTP3 wins again, but narrowly at TP4** (+1.2% vs +8.8% at TP2). Acceptance under load: t1 mean accept len 2.71–2.84, per-position ~0.83/0.59/0.42. The fourth-position penalty shrinks at TP4 because decode is less draft-throughput-bound.
3. **1M+ KV pool on TP4 confirmed**: the 9 GiB fp8 pin yields 1.29M tokens ≈ one ~1M-token context or ~5 full 262K contexts.

## Verdict

**t1 (fp8 KV 9 GiB pin + MTP3) adopted as the TP4 production config.** Proceeds to the winner battery → [Report 04](04-tp4-winner-battery.md), then the KV ladder pushes the pool further → [Report 05](05-tp4-kv-ladder.md).

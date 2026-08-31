# GLM-5.3-Flash NVFP4 on 2× and 4× NVIDIA DGX Spark

Measured deployment recipes for [zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) — 320B total / 18B active MoE, hybrid linear + sparse attention, native MTP head, 262K context — quantized to NVFP4 ([LibertAIDAI quant](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4), 194.7 GB), served with vLLM on NVIDIA DGX Spark (GB10, SM121) nodes over a 200G RoCEv2 fabric.

Everything below was measured 2026-08-27 → 2026-08-31 in an ongoing campaign: deployment, a 4-arm + 2-arm autoresearch sweep, winner batteries under concurrency, a stress-gated KV ladder, the DFlash2 port, and — after the ModelOpt token-corruption discovery (Report 10) — a full re-validation on corruption-free `RedHatAI` compressed-tensors weights. Start with the [runbook](runbook-glm53-flash-nvfp4.md) to reproduce; each optimization has its own report below.

---

## Headline numbers

**Single-stream decode, TP4 winner (fp8 KV + MTP3):** **40.0 tok/s prose · 40.6 tok/s code** — vs 35.7 published by the source recipe (+12–14%)

**Aggregate throughput, TP4, 8 concurrent streams:** **114.4 tok/s prose · 110.9 tok/s code**, TTFT ≤ 0.35 s

**KV capacity (stress-gated ladder):** **5,747,003 fp8 tokens at 1M context** = 5.75 concurrent full-1M-context requests — vs 5.03M in the source fleet

All numbers: on-box, 512 output tokens, temperature 0, thinking off, median of 3.

**Clean-weights era (2026-08-30/31, DFlash2 + `RedHatAI` compressed-tensors):** TP4 **C8 aggregate 90.75 tok/s** (mns8+no-eager, +92% vs the published default config) · TP2 upstream-recipe reproduction **matched or bettered C1–C6, up to 63.7 tok/s at C5 (+28% at C6)** — see Reports 10–12.

---

## The optimization reports

| # | Report | What it tested | Outcome |
|---|---|---|---|
| 01 | [TP2 autoresearch sweep](reports/01-tp2-autoresearch-sweep.md) | KV dtype × MTP depth, 4 arms | fp8 KV + **MTP3** wins: 28.3 tok/s (+30% vs source's TP2 flagship) |
| 02 | [TP2 winner battery](reports/02-tp2-winner-battery.md) | C1/C4/C8 × prose/code | 73.4 tok/s aggregate at C8 |
| 03 | [TP4 autoresearch sweep](reports/03-tp4-autoresearch-sweep.md) | MTP3 vs MTP4 at 4 nodes | MTP3 wins again: 38.6 tok/s (+8% vs source headline) |
| 04 | [TP4 winner battery](reports/04-tp4-winner-battery.md) | C1/C4/C8 × prose/code | 114.4 tok/s aggregate at C8 |
| 05 | [TP4 KV ladder](reports/05-tp4-kv-ladder.md) | KV slab 16→40 GiB, long-prefill stress gate, **+ 2026-08-28 concurrent-prefill re-gate** | **5.75M-token pool at 1M ctx**; cleared the source fleet's 38 GiB wall and the 32 GiB concurrent-prefill OOM that stopped theirs |
| 06 | [Fleet ops findings](reports/06-fleet-ops-findings.md) | The bugs behind the numbers | New `rpc.nfsd -r` 21 GiB memory trap; GID-index fix; KV-pin doctrine |
| 07 | [DFlash2 speculative port](reports/07-dflash2-speculative-port.md) | Upstream's DFlash2 drafter at TP2 **and TP4** (first TP4 run) | TP4: **adopted for code/agentic** — C1 wins everywhere, code up to 70–84 tok/s; TP2: MTP3 retained |
| 08 | [TP2 DFlash2 optimization sweep](reports/08-tp2-dflash2-optimization-sweep.md) | spec depth × draft sampling × max-num-seqs, 4 arms + battery | spec7/greedy/mns6 stands; verify-cost hypothesis refuted; C8-TTFT blowout is architectural at TP2 (not queueing) |
| 09 | [Abliterated weights verification](reports/09-ablit-verification.md) | `drowzeys/keys-GLM-5.3-Flash-NVFP4-ablit-l15-45-anchorstock` — batteries, re-sweeps, DFlash2, refusal tiers, GSM8K, stock-paired | Uncensoring verified (hard tier 6/6→0/6); speed cost is a pure speculative-acceptance tax (−7 to −19%, raw decode at parity); **DFlash2 becomes the ablit C1 flagship** (code 45.5 tok/s, −0.2% vs stock) |
| 10 | [Corruption fix + TP4 re-sweep on clean weights](reports/10-corruption-fix-tp4-redhat-sweep.md) | ModelOpt token corruption (vLLM #54150) reproduced on both fleet checkpoints → swap to `RedHatAI` compressed-tensors, 8-cell TP4 DFlash2 sweep | **0/9 corrupted outputs** (vs 4–9/9 on ModelOpt); dropping `--enforce-eager` +22–38% C1; **B7 combo C8 90.75 tok/s (+92% vs published default)** |
| 11 | [TP2 DFlash2 lane + upstream recipe reproduction](reports/11-tp2-dflash2-redhat-recipe-repro.md) | TP2 262K sweep on clean weights, then the upstream 2× recipe's own C1–C6 harness (code/reasoning prompts) | **Matched or bettered upstream at every level C1–C6** (38.7/42.8/44.8/54.7/63.7/61.1 vs 35.1/41.6/40.6/47.5/56.2/47.7), zero failures |
| 12 | [Fleet ops findings II](reports/12-fleet-ops-tp2-oom-lane-move.md) | The bugs behind this campaign | **TP2 rank OOMs the controller host (.1) — banned**; lane moved to .12+.14; final-teardown doctrine; reboot hygiene; runner-survival watchdog |

## Key findings, in one list

1. **MTP3 beats MTP4** at both scales (+8.8% TP2, +1.2% TP4) — the fourth draft token's ~0.15–0.23 acceptance costs more than it returns
2. **fp8 KV doubles the token pool** at near-zero speed cost; pin `--kv-cache-memory` verbatim or GB10's allocator fails fast
3. **KV capacity scales linearly to the edge band**: 40 GiB slab = 5.75M tokens with 9–12 GiB residual per node — the production ceiling. **Re-gated 2026-08-28 under 3× concurrent 20K prefills** (the load that OOM'd the source fleet's 32 GiB config): all rungs pass; our head-node `rpc.nfsd` fix is the difference. Head-node residual at L5 is now thin (5.7 GiB post-gate) — L4 (32 GiB @ 1M) is the recommended 1M default
4. **`NCCL_IB_GID_INDEX` must be omitted** on mixed fleets (reboot-volatile GID tables)
5. **Never enable NFS-RDMA with `rpc.nfsd -r`** — it invisibly strands 21 GiB of unified memory; use the portlist echo (Report 06)
6. **DFlash2 (Report 07) is the code/agentic flagship at TP4**: C1 wins everywhere (45 code / 41 prose vs MTP3's ~40; 70–84 tok/s on structured output), code wins at all concurrencies, −9% prose-C8 aggregate is the trade. At TP2 the 7-token verify cost flips the verdict — MTP3 retained. Acceptance tracks output predictability (57–65% structured vs 25–35% prose)
7. **ModelOpt NVFP4 builds are corrupted** (Report 10): 4–9 corrupted outputs per 9 on both fleet checkpoints (vLLM #54150); `RedHatAI` compressed-tensors is 0/9 and is now the fleet default. Uncensored ablit variants carry the corruption until a compressed-tensors ablit exists
8. **`--enforce-eager` costs +22–38% C1** on the clean-weights DFlash2 lane — dropping it was the biggest single sweep lever (Reports 10–11)
9. **A TP2 rank OOMs the controller host** (Report 12): ~107 GiB real footprint + co-resident services hung .1 twice despite cgroup caps — TP2 lane is .12+.14; TP4 ranks remain safe on .1
10. **Benchmark numbers are prompt-class-relative** (Report 11): the same TP2 engine measures ~20–26 tok/s on freeform prose and ~39 tok/s on code/reasoning prompts. Quote the prompt with the number

## Repo layout

```
runbook-glm53-flash-nvfp4.md     procedure: prereqs → launch → flags → troubleshooting
reports/                          one report per optimization (above)
scripts/                          TP2/TP4 launchers, sweep + battery drivers, KV ladder,
                                  long-prefill gate, stdlib-only harness, cache-flusher
results/                          raw JSONL/JSON for every completed arm and rung
```

## Credits

- Model: [zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) · Quant: [LibertAIDAI/GLM-5.3-Flash-NVFP4](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4) (Reports 01–09) → [RedHatAI/GLM-5.3-Flash-NVFP4](https://huggingface.co/RedHatAI/GLM-5.3-Flash-NVFP4) compressed-tensors, fleet default since Report 10 · Drafter: [incoai/GLM-5.3-Flash-DFlash2](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2)
- Day-0 recipes & patch chain: tonyd2wild ([262K-2x](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-262K-2x-DGX-Spark) · [1M-KV-4x](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark) · [DFlash2-2x](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-DFlash2-2x-DGX-Spark))
- Campaign: Vikas Sridhar's CRS812 DGX Spark cluster, measured 2026-08-27 → 2026-08-31

# GLM-5.3-Flash NVFP4 on 2× and 4× NVIDIA DGX Spark

Measured deployment recipes for [zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) — 320B total / 18B active MoE, hybrid linear + sparse attention, native MTP head, 262K context — quantized to NVFP4 ([LibertAIDAI quant](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4), 194.7 GB), served with vLLM on NVIDIA DGX Spark (GB10, SM121) nodes over a 200G RoCEv2 fabric.

Everything below was measured on 2026-08-27 in a single campaign: deployment, a 4-arm + 2-arm autoresearch sweep, winner batteries under concurrency, and a stress-gated KV ladder. Start with the [runbook](runbook-glm53-flash-nvfp4.md) to reproduce; each optimization has its own report below.

---

## Headline numbers

**Single-stream decode, TP4 winner (fp8 KV + MTP3):** **40.0 tok/s prose · 40.6 tok/s code** — vs 35.7 published by the source recipe (+12–14%)

**Aggregate throughput, TP4, 8 concurrent streams:** **114.4 tok/s prose · 110.9 tok/s code**, TTFT ≤ 0.35 s

**KV capacity (stress-gated ladder):** **5,747,003 fp8 tokens at 1M context** = 5.75 concurrent full-1M-context requests — vs 5.03M in the source fleet

All numbers: on-box, 512 output tokens, temperature 0, thinking off, median of 3.

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

## Key findings, in one list

1. **MTP3 beats MTP4** at both scales (+8.8% TP2, +1.2% TP4) — the fourth draft token's ~0.15–0.23 acceptance costs more than it returns
2. **fp8 KV doubles the token pool** at near-zero speed cost; pin `--kv-cache-memory` verbatim or GB10's allocator fails fast
3. **KV capacity scales linearly to the edge band**: 40 GiB slab = 5.75M tokens with 9–12 GiB residual per node — the production ceiling. **Re-gated 2026-08-28 under 3× concurrent 20K prefills** (the load that OOM'd the source fleet's 32 GiB config): all rungs pass; our head-node `rpc.nfsd` fix is the difference. Head-node residual at L5 is now thin (5.7 GiB post-gate) — L4 (32 GiB @ 1M) is the recommended 1M default
4. **`NCCL_IB_GID_INDEX` must be omitted** on mixed fleets (reboot-volatile GID tables)
5. **Never enable NFS-RDMA with `rpc.nfsd -r`** — it invisibly strands 21 GiB of unified memory; use the portlist echo (Report 06)
6. **DFlash2 (Report 07) is the code/agentic flagship at TP4**: C1 wins everywhere (45 code / 41 prose vs MTP3's ~40; 70–84 tok/s on structured output), code wins at all concurrencies, −9% prose-C8 aggregate is the trade. At TP2 the 7-token verify cost flips the verdict — MTP3 retained. Acceptance tracks output predictability (57–65% structured vs 25–35% prose)

## Repo layout

```
runbook-glm53-flash-nvfp4.md     procedure: prereqs → launch → flags → troubleshooting
reports/                          one report per optimization (above)
scripts/                          TP2/TP4 launchers, sweep + battery drivers, KV ladder,
                                  long-prefill gate, stdlib-only harness, cache-flusher
results/                          raw JSONL/JSON for every completed arm and rung
```

## Credits

- Model: [zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) · Quant: [LibertAIDAI/GLM-5.3-Flash-NVFP4](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4)
- Day-0 recipes & patch chain: tonyd2wild ([262K-2x](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-262K-2x-DGX-Spark) · [1M-KV-4x](https://github.com/tonyd2wild/GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark))
- Campaign: Vikas Sridhar's CRS812 DGX Spark cluster, measured 2026-08-27

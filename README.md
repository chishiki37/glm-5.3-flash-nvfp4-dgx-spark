# GLM-5.3-Flash NVFP4 on 2× and 4× NVIDIA DGX Spark

Measured deployment recipes for **zai-org/GLM-5.3-Flash** (320B total / 18B active MoE, hybrid KDA linear-attn + sparse-attn, native MTP head, 262K context) quantized to **NVFP4** ([LibertAIDAI/GLM-5.3-Flash-NVFP4](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4), 194.7 GB, routed-expert FFNs) on a CRS812-fabric cluster of NVIDIA DGX Spark (GB10, SM121) nodes.

Built from tonyd2wild's day-0 recipes (262K-2x + 1M-KV-4x), re-validated and extended with an autoresearch serving-parameter sweep on our fleet. Full procedure: [runbook-glm53-flash-nvfp4.md](runbook-glm53-flash-nvfp4.md).

## Headline numbers (measured on-box, prose/code 512 tok out, temp 0, thinking off, median of 3)

**TP2 — winner: fp8 KV + MTP3** (cb98 head + 1 worker)

| Cell | Aggregate tok/s | TTFT s |
|---|---:|---:|
| Prose C1 | 27.7 | 0.34 |
| Prose C4 | 68.4 | 0.40 |
| Prose C8 | 73.4 | 0.43 |
| Code C1 | 28.1 | 0.36 |
| Code C8 | 69.3 | 0.74 |

**TP4 — winner: fp8 KV + MTP3, 9 GiB KV pin → 1.29M-token pool** (head + 3 workers)

| Cell | Aggregate tok/s | TTFT s |
|---|---:|---:|
| Prose C1 | 40.0 | 0.22 |
| Prose C4 | 110.0 | 0.29 |
| Prose C8 | 114.4 | 0.34 |
| Code C1 | 40.6 | 0.23 |
| Code C8 | 110.9 | 0.35 |

vs the source recipe's published claims (TP2 21.8, TP4 35.7 tok/s single-stream): our fleet measures **+30% (TP2)** and **+12–14% (TP4)** single-stream, 3.2× at TP4 C8 aggregate.

## Key findings

1. **MTP3 beats MTP4** at both TP2 (+8.8%) and TP4 (+1.2%): position-4 draft acceptance (~0.15–0.23) costs more than it returns.
2. **fp8 KV doubles the token pool** (TP2 no-MTP: 1.02M tokens; TP4 MTP3: 1.29M ≈ 4.9× full 262K context or one ~1M context).
3. **`--kv-cache-memory` must be pinned** to vLLM's suggested value on GB10 (NVRM allocates KV from MemFree only and fails fast; unpinned arms die, and can wedge the node).
4. **`NCCL_IB_GID_INDEX` must be omitted** — RoCE GID tables are reboot-volatile and differ across nodes; hardcoding kills all-rank rendezvous on mixed fleets.
5. **NFS head trap:** `rpc.nfsd -r` strands ~21 GiB of unified memory invisibly; enable NFS-RDMA with `echo rdma 20049 > /proc/fs/nfsd/portlist` only (see runbook troubleshooting).

## Repo layout

- `runbook-glm53-flash-nvfp4.md` — prerequisites, step-by-step, flag-by-flag rationale, performance reference, troubleshooting
- `scripts/` — parameterized TP2/TP4 launchers, sweep + battery drivers, stdlib-only probe/battery harness, cache-flusher sidecar
- `results/` — sweep JSONL (all completed arms) + winner battery JSON

## Credits

- Model: [zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) · Quant: [LibertAIDAI/GLM-5.3-Flash-NVFP4](https://huggingface.co/LibertAIDAI/GLM-5.3-Flash-NVFP4)
- Day-0 recipes & patch chain: tonyd2wild (`GLM-5.3-Flash-NVFP4-262K-2x-DGX-Spark`, `GLM-5.3-Flash-NVFP4-1M-KV-4x-DGX-Spark`)
- Campaign: Vikas Sridhar's CRS812 DGX Spark cluster, measured 2026-08-27

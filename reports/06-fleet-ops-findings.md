# Report 06 — Fleet Operations Findings (the bugs behind the numbers)

**Date:** 2026-08-27 · Three fleet-specific issues were root-caused during this campaign. Each is now a pre-flight check or a documented pitfall in the runbook.

## 1. `rpc.nfsd -r` silently strands ~21 GiB of unified memory (NEW — not in the source recipe)

**Symptom:** freshly rebooted NFS head showed MemFree ~96.5 GiB vs ~118 GiB on healthy siblings; vLLM's startup check died with `Free memory on device cuda:0 (84.64/121.69 GiB) ... less than desired GPU memory utilization (0.85, 103.4 GiB)`.

**The red herrings:** the deficit is invisible in every meminfo category (whole delta in MemFree; nothing in Slab/Vmalloc/Cached/HugePages/CMA), and it survives a full nvidia module rmmod/modprobe — which strongly implies GPU-side damage. It isn't.

**Root cause:** `rpc.nfsd -V 3 -V 4 -r 20049 8` (used in our NFS-RDMA persistence service) strands ~21.3 GiB the moment it runs — instant, reproducible.

**Proof (A/B on the same boot):**

| Action | MemFree |
|---|---:|
| nfs-server stopped | 117.8 GiB |
| nfs-server started, TCP only | 117.7 GiB |
| `modprobe svcrdma; echo rdma 20049 > /proc/fs/nfsd/portlist` | **117.8 GiB** (RDMA active, zero cost) |
| `rpc.nfsd -r 20049` | 96.4 GiB (−21.3 GiB) |

**Fix:** enable NFS-RDMA with the portlist echo ONLY; the persist service's ExecStart must never call `rpc.nfsd -r`. Note an nfs-server restart clears portlist (re-echo after). Verified holding 117.6 GiB with 3 live RDMA clients.

**Diagnosis ladder for any pure MemFree deficit:** diff meminfo categories vs a healthy sibling → stop nfs-server and re-measure → A/B the RDMA enable method → only then suspect GPU-side damage.

## 2. `NCCL_IB_GID_INDEX` must be omitted (fleet-specific GID table volatility)

The source launcher hardcodes `NCCL_IB_GID_INDEX=3`. On our cluster, cb98/3b24/9105 carry the IPv4 RoCEv2 GID at index 2–3, but **bdea's sits at index 4–5** (the tables are reboot-volatile). With the hardcoded index, bdea selected a `fe80::` link-local GID → `ibv_modify_qp failed with 22 Invalid argument` → all-rank rendezvous death on every TP4 boot (TP2 survived only because both its nodes coincidentally matched).

**Fix:** omit `NCCL_IB_GID_INDEX` entirely; NCCL auto-detects per node. Validated across 4+ clean TP4 boots. Pre-flight for any 4-node launch: dump `/sys/class/infiniband/<hca>/ports/1/gids/*` on every node and look for the `ffff:` (IPv4) entries — if indices differ across nodes, a fixed index will break at least one.

## 3. Unpinned-KV arms can wedge a node (hardening the KV-ladder doctrine)

The TP4 bf16-no-MTP unpinned arm profiled 50.37 GiB KV-available, attempted the ~50 GiB single-slab allocation, and deep-wedged the head node ~40 min later (Tailscale online, TCP:22 accepting connections, but sshd unable to fork — kernel netstack alive, userspace unreachable). No BMC on these boxes → physical power cycle was the only recovery.

**Rule:** every sweep arm pins `--kv-cache-memory` ≤ vLLM's suggested value. The GB10 NVRM allocator grants KV from MemFree only and fails fast instead of reclaiming page cache; vLLM's suggested number already accounts for this since PR #35356's free-memory semantics — take it verbatim.

## Also noted

- **Never run `nvidia-smi -r` on GB10** — it hangs and forces a reboot.
- Cache-flusher sidecar + `drop_caches` before every boot remains mandatory (NVIDIA KB 5776 class).

# Report 12 — Fleet Ops Findings II: TP2-rank OOM on the controller host, lane move, teardown doctrine

**Date:** 2026-08-31 · Companion to [Report 06](06-fleet-ops-findings.md). Every item below cost a failed run or a reboot.

## 1. A TP2 rank OOMs the controller host — .1 is banned for TP2 rank duty

A TP2 rank of GLM-5.3-Flash NVFP4 is ~98 GiB of weights per rank + ~3.9 GiB peak activation + KV pin (gmu 0.88 on 121.7 GiB unified memory ≈ 107 GiB real). Running rank0 on **9105 (.1) — which also carries the cluster's controller stack** — hung the node **twice** (2026-08-31 ~12:04 and ~13:05), each requiring a forced power cycle:

- Journal: kernel `oom-kill` (global OOM) starting at engine-ready, then systemd-journald "Under memory pressure, flushing caches" every few minutes for ~35 min, then nothing — hard hang, no clean shutdown recorded.
- The second hang occurred **with a 112g container cap and an explicit 4.96 GiB `--kv-cache-memory` pin in place** — capping the container does not save the host when the engine's legitimate footprint + host services ≈ total RAM.
- Identical rank on bare nodes ran for hours without pressure (.2 carried rank1 through both incidents; .12/.14 ran the full sweep clean).
- TP4 ranks (~75 GiB/rank) remain safe on .1 — the Aug 27–30 campaigns never hit this.

**Rule: TP2 lane = .12 (head) + .14 (rank1). Never rank a TP2 Flash engine on .1.**

## 2. TP2 KV gate math

At 98 GiB/rank weights, gmu 0.85 leaves only ~1.65 GiB for KV — below the 2.65 GiB one 262K request requires, so the engine refuses to boot ("No available memory for the cache blocks"). gmu 0.88 + `--kv-cache-memory 5325147587` (4.96 GiB, vLLM's own fits-in-budget suggestion at that gmu) is the verified-safe combination: pool 488,656 tokens, 262K at 1.86× concurrency.

## 3. Sweep scripts need a final teardown

The Report 10 TP4 sweep tore down only at the *start* of each cell — the winning B7 engine sat loaded on .12/.14 for ~2 days as headless orphans (~75 GiB pinned per node) until the lane move found them. Every sweep now ends with an explicit teardown.

## 4. Reboot hygiene on the Sparks

- `/tmp` is tmpfs: the flusher's sudo-credential file (`/tmp/.sudopw`) **does not survive reboots** — re-stage it before arming flushers.
- The models-cb98 NFS mount is manual (not in fstab): after a reboot, remount before launch:
  `mount -t nfs -o ro,vers=3,proto=rdma,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 10.10.10.14:/home/vikassridhar/models /var/tmp/models-cb98`
- Persist the memory ritual (`/etc/sysctl.d/99-gb10-swap.conf`: `vm.swappiness = 0`) — runtime `sysctl -w` alone is reboot-volatile (Report 06 rule, re-confirmed on .12).

## 5. Two runner bugs fixed mid-campaign

- **pkill self-kill:** the teardown's remote script contained the string `flash-flusher.sh` in its own command line, so `pkill -f flash-flusher.sh` killed the teardown shell itself — no "done" marker, bootlogs never saved, drop_caches never ran. Fix: `pkill -f "flash-flusher[.]sh"`.
- **Dead-cell polling burn:** RUN1 burned the full 75-min health-poll window on each of 4 dead cells (~3 h on corpses). Fix: fail-fast poll — head-container-gone check every 60 s + fatal-marker grep every 120 s; dead cells now cost ~2–9 min.

## 6. Runner processes must survive gateway restarts

Two sweep runners died silently when their supervising gateway restarted (05:15, 11:02). Mitigations now standard: tracked background launch with completion notify **plus** a zero-token script-mode watchdog cron that (a) reports each READY/result/failure line and (b) yells when the runner process is gone but the log lacks its "done" marker — so a live engine gets salvaged instead of discovered hours later.

#!/bin/bash
# L5 bonus rung: 40 GiB slab @ 1M context (residual-headroom edge probe).
set -uo pipefail
NODES=(edgexpert-bdea edgexpert-9105 edgexpert-3b24 aitopatom-cb98)
HEAD=aitopatom-cb98
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/kv_ladder_results.jsonl"
for n in "${NODES[@]}"; do timeout 60 ssh "$n" 'docker rm -f vllm_glm53 2>/dev/null || true'; done
for n in "${NODES[@]}"; do
  timeout 30 ssh "$n" 'sync; cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; pkill -f cache_flusher 2>/dev/null; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
done
ranks=(3 2 1 0)
for i in 0 1 2 3; do
  r=${ranks[$i]} node=${NODES[$i]}
  echo "[$(date +%H:%M)] launch rank $r on $node"
  timeout 120 ssh "$node" "GLM_KV_DTYPE=fp8_e4m3 GLM_KV_MEM=42949672960 GLM_SPEC=3 GLM_MAXLEN=1048576 bash ~/launch_tp4_param.sh $r" || { echo "L5: rank $r launch fail"; exit 1; }
  [ $i -lt 3 ] && sleep 22
done
echo "[$(date +%H:%M)] health wait"
timeout 2400 ssh "$HEAD" 'for i in $(seq 1 240); do
  curl -s -m 3 http://127.0.0.1:8000/v1/models 2>/dev/null | grep -q glm-5.3-flash && { echo HEALTHY; exit 0; }
  docker ps --format "{{.Names}}" | grep -q vllm_glm53 || { echo "CONTAINER GONE"; exit 4; }
  sleep 10
done; echo TIMEOUT; exit 3'
[ $? -eq 0 ] || { echo "L5 NOT HEALTHY"; for n in "${NODES[@]}"; do timeout 60 ssh "$n" 'docker rm -f vllm_glm53 2>/dev/null || true'; done; exit 1; }
kvline=$(timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -m1 -E "GPU KV cache size"' 2>/dev/null)
resid=""
for n in "${NODES[@]}"; do v=$(timeout 15 ssh "$n" 'awk "/MemAvailable/{printf \"%.1f\", \$2/1048576}" /proc/meminfo' 2>/dev/null); resid="${resid:+$resid,}$v"; done
echo "kv: $kvline"; echo "residual: $resid"
probe=$(timeout 300 ssh "$HEAD" 'bash ~/probe_onbox.sh' 2>/dev/null)
echo "probe: $probe"
echo "[$(date +%H:%M)] long-prefill gate"
gate=$(timeout 1800 ssh "$HEAD" 'python3 ~/longprefill_gate.py' 2>/dev/null)
echo "gate: $gate"
python3 - "$OUT" "L5_40gib_1M" "42949672960" "1048576" "$kvline" "$resid" "$probe" "$gate" <<'PYEOF'
import json, sys
out, name, kvmem, maxlen, kvline, resid, probe, gate = sys.argv[1:9]
rec = {"rung": name, "kv_mem_bytes": int(kvmem), "max_model_len": int(maxlen),
       "kv_raw": kvline.strip(), "residual_memavail_gib": resid,
       "ts": __import__("datetime").datetime.now().astimezone().isoformat(timespec="seconds")}
for key, raw in (("probe", probe), ("gate", gate)):
    try: rec[key] = json.loads(raw)
    except Exception: rec[key] = raw.strip()[:500] or None
g = rec.get("gate") or {}
rec["verdict"] = "PASS" if (isinstance(g, dict) and g.get("gate_ok") and g.get("postgate_ok")) else "FAIL"
with open(out, "a") as f: f.write(json.dumps(rec) + "\n")
print(f"rung {name}: {rec['verdict']}")
PYEOF
for n in "${NODES[@]}"; do timeout 60 ssh "$n" 'docker rm -f vllm_glm53 2>/dev/null || true'; done
echo "L5 DONE"

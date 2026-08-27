#!/bin/bash
# TP4 KV ladder with long-prefill stress gate (tonyd2wild residual-headroom rule).
# Rungs: L1 16 GiB / L2 24 GiB / L3 32 GiB (262K ctx), L4 32 GiB @ 1M ctx (their ship config).
# MTP3 (our fleet winner) throughout. Halts on first failed rung.
set -uo pipefail
NODES=(edgexpert-bdea edgexpert-9105 edgexpert-3b24 aitopatom-cb98)  # ranks 3,2,1,0
HEAD=aitopatom-cb98
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/kv_ladder_results.jsonl"

health_wait() {
  timeout 2400 ssh "$HEAD" 'for i in $(seq 1 240); do
    curl -s -m 3 http://127.0.0.1:8000/v1/models 2>/dev/null | grep -q glm-5.3-flash && { echo HEALTHY; exit 0; }
    docker ps --format "{{.Names}}" | grep -q vllm_glm53 || { echo "CONTAINER GONE"; exit 4; }
    sleep 10
  done; echo TIMEOUT; exit 3'
}

teardown() {
  for n in "${NODES[@]}"; do
    timeout 60 ssh "$n" 'docker rm -f vllm_glm53 2>/dev/null || true' || true
  done
}

residual_mem() { # MemAvailable on all 4 nodes, GiB, comma list
  local acc=""
  for n in "${NODES[@]}"; do
    local v; v=$(timeout 15 ssh "$n" 'awk "/MemAvailable/{printf \"%.1f\", \$2/1048576}" /proc/meminfo' 2>/dev/null)
    acc="${acc:+$acc,}$v"
  done
  echo "$acc"
}

run_rung() { # name kvmem maxlen
  local name="$1" kvmem="$2" maxlen="$3"
  echo "[$(date +%H:%M)] === rung $name (kv=$kvmem maxlen=$maxlen)"
  teardown
  for n in "${NODES[@]}"; do
    timeout 30 ssh "$n" 'sync; cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; pkill -f cache_flusher 2>/dev/null; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
  done
  local ranks=(3 2 1 0)
  for i in 0 1 2 3; do
    local r=${ranks[$i]} node=${NODES[$i]}
    echo "[$(date +%H:%M)] launch rank $r on $node"
    timeout 120 ssh "$node" "GLM_KV_DTYPE=fp8_e4m3 GLM_KV_MEM=$kvmem GLM_SPEC=3 GLM_MAXLEN=$maxlen bash ~/launch_tp4_param.sh $r" || { echo "rung $name: rank $r launch fail"; return 1; }
    [ $i -lt 3 ] && sleep 22
  done
  echo "[$(date +%H:%M)] health wait"
  local hs; hs=$(health_wait)
  echo "health: $hs"
  if [ "$hs" != "HEALTHY" ]; then
    echo "rung $name: NOT HEALTHY ($hs)"; teardown; return 1
  fi
  local kvline; kvline=$(timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -m1 -E "GPU KV cache size"' 2>/dev/null)
  local resid; resid=$(residual_mem)
  echo "kv: $kvline"
  echo "residual MemAvailable (bdea,9105,3b24,cb98 GiB): $resid"
  local probe; probe=$(timeout 300 ssh "$HEAD" 'bash ~/probe_onbox.sh' 2>/dev/null)
  echo "probe: $probe"
  echo "[$(date +%H:%M)] long-prefill gate (~24K tokens)"
  local gate; gate=$(timeout 1800 ssh "$HEAD" 'python3 ~/longprefill_gate.py' 2>/dev/null)
  echo "gate: $gate"
  python3 - "$OUT" "$name" "$kvmem" "$maxlen" "$kvline" "$resid" "$probe" "$gate" <<'EOF'
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
with open(out, "a") as f:
    f.write(json.dumps(rec) + "\n")
print(f"rung {name}: {rec['verdict']}")
EOF
  local verdict; verdict=$(tail -1 "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['verdict'])")
  teardown
  [ "$verdict" = "PASS" ] || { echo "rung $name FAILED — halting ladder"; return 1; }
  return 0
}

run_rung L1_16gib_262k 17179869184 262144 || exit 1
run_rung L2_24gib_262k 25769803776 262144 || exit 1
run_rung L3_32gib_262k 34359738368 262144 || exit 1
run_rung L4_32gib_1M   34359738368 1048576 || exit 1
echo "LADDER COMPLETE — all rungs passed"

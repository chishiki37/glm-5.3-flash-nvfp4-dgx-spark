#!/usr/bin/env bash
# GLM-5.3-Flash TP4 DFlash2 sweep v2 — recipe-compliant.
# Adds: (1) memory ritual (swappiness=0 + swap reset + pre-drop) on every node before every boot,
#       (2) 75-min boot patience (cold NFS boots can exceed 1h — recipe),
#       (3) docker-log capture before teardown (recipe rule 7).
set -u
NODES=(10.10.10.14 10.10.10.12 10.10.10.1 10.10.10.2)
OUT="$HOME/flash-results"
LOG="$OUT/sweep.log"
mkdir -p "$OUT"
exec > >(tee -a "$LOG") 2>&1
ts() { date '+%H:%M:%S'; }
rsh() { timeout "$2" ssh -o ConnectTimeout=10 vikassridhar@"$1" "$3" < /dev/null; }

memory_ritual() {
  # Repo Quickstart step 3: swap must exist but never be used; drop caches once.
  local ip
  for ip in "${NODES[@]}"; do
    rsh "$ip" 40 'cat /tmp/.sudopw | sudo -S -p "" sh -c "sysctl -w vm.swappiness=0 >/dev/null; swapoff -a >/dev/null 2>&1; swapon -a >/dev/null 2>&1; sync; echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; echo "swappiness=$(cat /proc/sys/vm/swappiness)"' | sed "s/^/  $ip ritual: /"
  done
}

teardown() {
  echo "[$(ts)] teardown"
  local ip
  for ip in "${NODES[@]}"; do
    rsh "$ip" 40 'pkill -f flash-flusher.sh 2>/dev/null
      if docker ps -a --format "{{.Names}}" | grep -q vllm_glm53_dflash2; then
        mkdir -p "$HOME/flash-results/bootlogs"
        docker logs vllm_glm53_dflash2 > "$HOME/flash-results/bootlogs/$(hostname)-$(date +%H%M%S).log" 2>&1
        docker rm -f vllm_glm53_dflash2 >/dev/null 2>&1
      fi
      sync; echo done' | sed "s/^/  $ip: /"
  done
  sleep 10
}

arm_flushers() {
  local ip
  for ip in "${NODES[@]}"; do
    rsh "$ip" 20 'setsid nohup bash "$HOME/flash-flusher.sh" 7200 >/dev/null 2>&1 < /dev/null & echo armed' | sed "s/^/  $ip flusher: /"
  done
}

stop_flushers() {
  local ip
  for ip in "${NODES[@]}"; do
    rsh "$ip" 20 'pkill -f flash-flusher.sh 2>/dev/null; echo stopped' | sed "s/^/  $ip flusher: /"
  done
}

launch_cell() {
  local envstr="$1" r
  for r in 3 2 1; do
    rsh "${NODES[$r]}" 90 "[ -n '$envstr' ] && export $envstr; bash \$HOME/flash-launch.sh $r" 2>&1 | tail -1 | sed "s/^/  rank$r: /"
    sleep 3
  done
  rsh 10.10.10.14 90 "[ -n '$envstr' ] && export $envstr; bash \$HOME/flash-launch.sh 0" 2>&1 | tail -1 | sed "s/^/  rank0: /"
}

wait_ready() {
  # 75 min patience — recipe: cold NFS worker boots can exceed 1h.
  local t
  for t in $(seq 1 300); do
    if curl -s --max-time 5 http://10.10.10.14:8000/health >/dev/null 2>&1; then
      echo "[$(ts)] READY after ~$((t*15))s"
      return 0
    fi
    sleep 15
  done
  echo "[$(ts)] NOT READY after 75 min"
  return 1
}

run_cell() {
  local name="$1" envstr="$2" probe="$3"
  echo ""
  echo "############ CELL $name (${envstr:-repo defaults}) ############"
  teardown
  memory_ritual
  arm_flushers
  local t_start
  t_start=$(date +%s)
  launch_cell "$envstr"
  if wait_ready; then
    stop_flushers
    local boot=$(( $(date +%s) - t_start ))
    echo "[$(ts)] boot ${boot}s; warm 60s"
    sleep 60
    if [ "$probe" = "yes" ]; then
      echo "[$(ts)] corruption probe:"
      python3 "$OUT/korean_probe.py" --passes 3 2>&1 | tail -4
    fi
    python3 "$OUT/sweep_bench_flash.py" > "$OUT/cell-$name.json" 2>"$OUT/cell-$name.err"
    python3 -c "
import json
d=json.load(open('$OUT/cell-$name.json'))
c1=[r['tps'] for r in d['c1']]
print(f\"CELL $name: boot=${boot}s C1={c1} C4={d['c4']['aggregate_tps']} C8={d['c8']['aggregate_tps']} | ${envstr:-defaults}\")"
  else
    stop_flushers
    echo "CELL $name: BOOT FAILED"
    echo "[$(ts)] capturing boot logs before teardown:"
    for ip in "${NODES[@]}"; do
      rsh "$ip" 40 'mkdir -p "$HOME/flash-results/bootlogs"; docker logs vllm_glm53_dflash2 2>&1 | grep -iE "ERROR|Traceback|RuntimeError|died|exit" | tail -4' | cut -c1-220 | sed "s/^/  $ip: /"
    done
  fi
}

echo "===== GLM-5.3-Flash TP4 sweep v2 start $(date) ====="
run_cell B0-repo-default "" yes
run_cell B1-mns4 "FLASH_MNS=4" no
run_cell B2-mns8 "FLASH_MNS=8" no
run_cell B3-mns12 "FLASH_MNS=12" no
run_cell B4-mnbt16k "FLASH_MNBT=16384" no
run_cell B5-kv28g "FLASH_KV=30064771072" no
run_cell B6-noeager "FLASH_EAGER=0" no

echo ""
echo "===== SWEEP SUMMARY ====="
for f in "$OUT"/cell-B*.json; do
  n=$(basename "$f" .json | sed 's/cell-//')
  python3 -c "
import json
d=json.load(open('$f'))
c1=[r['tps'] for r in d['c1']]
print(f\"$n: C1={c1} C4={d['c4']['aggregate_tps']} C8={d['c8']['aggregate_tps']}\")" 2>/dev/null || echo "$n: no result"
done
echo "===== sweep done $(date) ====="

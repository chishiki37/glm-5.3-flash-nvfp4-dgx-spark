#!/usr/bin/env bash
# GLM-5.3-Flash TP2 DFlash2 sweep — 4 cells on 9105(.1 head) + bdea(.2). 262K ctx.
# T0 = repo TP2 defaults: profiler-sized KV (NO pin), mns 6, mnbt 8192, eager, k=7.
# Run 2 fixes: gmu 0.89 (0.85 starves the 262K KV gate), flushers armed, fail-fast poll.
set -u
NODES=(10.10.10.12 10.10.10.14)
OUT="$HOME/flash-results"
LOG="$OUT/sweep-tp2.log"
mkdir -p "$OUT"
exec > >(tee -a "$LOG") 2>&1
ts() { date '+%H:%M:%S'; }
rsh() { timeout "$2" ssh -o ConnectTimeout=10 vikassridhar@"$1" "$3" < /dev/null; }

teardown() {
  echo "[$(ts)] teardown"
  local ip
  for ip in "${NODES[@]}"; do
    rsh "$ip" 90 'pkill -f "flash-flusher[.]sh" 2>/dev/null
      if docker ps -a --format "{{.Names}}" | grep -q vllm_glm53_dflash2; then
        mkdir -p "$HOME/flash-results/bootlogs"
        docker logs --tail 4000 vllm_glm53_dflash2 > "$HOME/flash-results/bootlogs/tp2-$(hostname)-$(date +%H%M%S).log" 2>&1
        docker rm -f vllm_glm53_dflash2 >/dev/null 2>&1
      fi
      cat /tmp/.sudopw | sudo -S -p "" sh -c "sysctl -w vm.swappiness=0 >/dev/null; swapoff -a; swapon -a; sync; echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; echo done' | sed "s/^/  $ip: /"
  done
  sleep 10
}

arm_flushers() {
  local ip
  for ip in "${NODES[@]}"; do
    rsh "$ip" 20 'test -f /tmp/.sudopw || echo "WARN: /tmp/.sudopw missing"; setsid nohup bash "$HOME/flash-flusher.sh" 7200 >/dev/null 2>&1 < /dev/null & echo armed' | sed "s/^/  $ip flusher: /"
  done
}

stop_flushers() {
  local ip
  for ip in "${NODES[@]}"; do
    rsh "$ip" 20 'pkill -f "flash-flusher[.]sh" 2>/dev/null; echo stopped' | sed "s/^/  $ip flusher: /"
  done
}

head_alive() {
  rsh 10.10.10.12 15 'docker ps --format "{{.Names}}" | grep -q vllm_glm53_dflash2 && echo up' 2>/dev/null | grep -q up
}

head_fatal() {
  rsh 10.10.10.12 20 'docker logs --tail 300 vllm_glm53_dflash2 2>&1 | grep -cE "Engine core initialization failed|No available memory for the cache blocks|KV cache is needed, which is larger"' 2>/dev/null | grep -qvE '^0$|^$'
}

run_cell() {
  local name="$1" envstr="$2" probe="$3"
  echo ""
  echo "############ TP2 CELL $name (${envstr:-repo defaults}) ############"
  teardown
  arm_flushers
  t_start=$(date +%s)
  local r
  for r in 1 0; do
    rsh "${NODES[$r]}" 90 "[ -n '$envstr' ] && export $envstr; bash \$HOME/flash-launch-tp2.sh $r" 2>&1 | tail -1 | sed "s/^/  rank$r: /"
    sleep 3
  done
  local ready=no dead=no
  local t
  for t in $(seq 1 300); do
    if curl -s --max-time 5 http://10.10.10.12:8000/health >/dev/null 2>&1; then
      echo "[$(ts)] READY after ~$((t*15))s"; ready=yes; break
    fi
    if [ $((t % 4)) -eq 0 ]; then
      if ! head_alive; then echo "[$(ts)] head container gone after ~$((t*15))s"; dead=yes; break; fi
    fi
    if [ $((t % 8)) -eq 0 ]; then
      if head_fatal; then echo "[$(ts)] fatal marker in head logs after ~$((t*15))s"; dead=yes; break; fi
    fi
    sleep 15
  done
  if [ "$ready" = yes ]; then
    local boot=$(( $(date +%s) - t_start ))
    echo "[$(ts)] boot ${boot}s; warm 60s"
    rsh 10.10.10.12 20 'docker logs vllm_glm53_dflash2 2>&1 | grep -iE "Available KV cache memory|Maximum concurrency" | tail -2' | sed "s/^/  kv: /"
    sleep 60
    if [ "$probe" = "yes" ]; then
      echo "[$(ts)] corruption probe:"
      python3 "$OUT/korean_probe.py" --url http://10.10.10.12:8000/v1/chat/completions --passes 3 2>&1 | tail -4
    fi
    python3 "$OUT/sweep_bench_flash.py" --url http://10.10.10.12:8000/v1/chat/completions \
      > "$OUT/tp2-cell-$name.json" 2>"$OUT/tp2-cell-$name.err"
    python3 -c "
import json
d=json.load(open('$OUT/tp2-cell-$name.json'))
c1=[r['tps'] for r in d['c1']]
print(f\"TP2 CELL $name: boot=${boot}s C1={c1} C4={d['c4']['aggregate_tps']} C8={d['c8']['aggregate_tps']}\")"
  else
    echo "TP2 CELL $name: BOOT FAILED (dead=$dead)"
    for ip in "${NODES[@]}"; do
      rsh "$ip" 40 'docker logs --tail 300 vllm_glm53_dflash2 2>&1 | grep -iE "ERROR|RuntimeError|ValueError" | tail -3' | cut -c1-220 | sed "s/^/  $ip: /"
    done
  fi
}

echo "===== GLM-5.3-Flash TP2 sweep RUN6 start $(date) (lane .12+.14; gmu 0.88, KV pin 4.96G, cap 112g; T1-T3) ====="
# T0 salvaged manually 10:58 (engine died w/ runner): C1~20.1 C4=31.64 C8=37.59
run_cell T1-mns8 "FLASH_MNS=8 FLASH_KV=5325147587" no
run_cell T2-noeager "FLASH_EAGER=0 FLASH_KV=5325147587" no
run_cell T3-combo-mns8-noeager "FLASH_MNS=8 FLASH_EAGER=0 FLASH_KV=5325147587" no

echo ""
echo "===== TP2 SWEEP SUMMARY ====="
for f in "$OUT"/tp2-cell-*.json; do
  n=$(basename "$f" .json | sed 's/tp2-cell-//')
  python3 -c "
import json
d=json.load(open('$f'))
c1=[r['tps'] for r in d['c1']]
print(f\"$n: C1={c1} C4={d['c4']['aggregate_tps']} C8={d['c8']['aggregate_tps']}\")" 2>/dev/null || echo "$n: no result"
done
stop_flushers
echo "===== tp2 sweep RUN6 done $(date) ====="

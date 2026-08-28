#!/usr/bin/env bash
# TP2 DFlash2 optimization sweep — applies TP2 learnings:
#  d0 baseline (spec7/greedy/mns6) already measured today 12:06-12:26 (not re-run)
#  d1: spec5  — cut 7-token verify cost (TP2 learning: verify eats acceptance gains)
#  d2: spec3  — verify cost floor
#  d3: spec7 probabilistic — acceptance side (greedy is default in this vLLM)
#  d4: spec7 greedy mns8   — C8 TTFT blowout fix candidate
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
HEAD=edgexpert-9105
WORKER=edgexpert-bdea

teardown() {
  for tn in "$HEAD" "$WORKER"; do timeout 60 ssh "$tn" 'docker rm -f vllm_glm53_dflash2 2>/dev/null || true' || true; done
}

health_wait() {
  timeout 2000 ssh "$HEAD" 'for i in $(seq 1 200); do
    curl -s -m 3 http://127.0.0.1:8000/v1/models 2>/dev/null | grep -q glm-5.3-flash && { echo HEALTHY; exit 0; }
    docker ps -a --format "{{.Names}} {{.Status}}" | grep -q "vllm_glm53_dflash2.*Exited" && { echo EXITED; exit 4; }
    sleep 10
  done; echo TIMEOUT; exit 3'
}

run_arm() { # name spec_n sample mns
  local name="$1" n="$2" sample="$3" mns="$4"
  echo "[$(date +%H:%M)] === arm $name (spec_n=$n sample=$sample mns=$mns)"
  teardown
  for nd in "$HEAD" "$WORKER"; do
    timeout 30 ssh "$nd" 'sync; cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; pkill -f cache_flusher 2>/dev/null; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
  done
  sleep 3
  echo "[$(date +%H:%M)] launch worker rank1"
  timeout 120 ssh "$WORKER" "SPEC_N=$n SPEC_SAMPLE=$sample MNS=$mns bash ~/launch_tp2_dflash2_param.sh 1" || { echo "$name: rank1 fail"; teardown; return 1; }
  sleep 25
  echo "[$(date +%H:%M)] launch head rank0"
  timeout 120 ssh "$HEAD" "SPEC_N=$n SPEC_SAMPLE=$sample MNS=$mns bash ~/launch_tp2_dflash2_param.sh 0" || { echo "$name: rank0 fail"; teardown; return 1; }
  local hs; hs=$(health_wait)
  echo "[$(date +%H:%M)] health: $hs"
  if [ "$hs" != "HEALTHY" ]; then
    echo "$name: NOT HEALTHY ($hs)"
    timeout 30 ssh "$HEAD" 'docker logs vllm_glm53_dflash2 2>&1 | tail -25'
    teardown; return 1
  fi
  timeout 30 ssh "$HEAD" 'docker logs vllm_glm53_dflash2 2>&1 | grep -E "auxiliary layers|GPU KV cache size|rejection sampler" | head -3'
  echo "[$(date +%H:%M)] C1 structured probe"
  timeout 900 ssh "$HEAD" "python3 ~/c1_structured.py http://127.0.0.1:8000 /home/vikassridhar/c1_${name}.jsonl" || { echo "$name: probe fail"; }
  timeout 60 scp -q "$HEAD:/home/vikassridhar/c1_${name}.jsonl" "$DIR/" 2>/dev/null || echo "$name: scp fail"
  echo "[$(date +%H:%M)] arm $name done"
  teardown
}

run_arm d1_spec5 5 greedy 6
run_arm d2_spec3 3 greedy 6
run_arm d3_prob 7 probabilistic 6
run_arm d4_mns8 7 greedy 8
echo "SWEEP COMPLETE"

#!/bin/bash
# ABLIT TP4 DFlash2: teardown TP4 MTP3 ablit -> ritual -> 4-rank dflash2 boot -> battery on-box.
set -uo pipefail
NODES=(edgexpert-bdea edgexpert-9105 edgexpert-3b24 aitopatom-cb98)  # ranks 3,2,1,0
HEAD=aitopatom-cb98
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[$(date +%H:%M:%S)] teardown: TP4 MTP3 ablit (all 4)"
for n in "${NODES[@]}"; do timeout 60 ssh "$n" 'docker rm -f vllm_glm53 2>/dev/null || true' || true; done

echo "[$(date +%H:%M:%S)] waiting for GPUs clear"
for i in $(seq 1 30); do
  busy=0
  for n in "${NODES[@]}"; do
    c=$(timeout 10 ssh "$n" 'nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l' 2>/dev/null)
    [[ "${c:-1}" != "0" ]] && busy=1
  done
  [[ $busy == 0 ]] && { echo "[$(date +%H:%M:%S)] GPUs clear"; break; }
  sleep 5
done

echo "[$(date +%H:%M:%S)] pre-launch ritual on all 4 nodes"
for n in "${NODES[@]}"; do
  timeout 30 ssh "$n" 'sync; cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; pkill -f cache_flusher 2>/dev/null; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
done
sleep 3

ranks=(3 2 1 0)
for i in 0 1 2 3; do
  r=${ranks[$i]}; node=${NODES[$i]}
  echo "[$(date +%H:%M:%S)] launch rank $r on $node (ablit dflash2)"
  timeout 120 ssh "$node" "bash ~/launch_tp4_ablit_dflash2.sh $r" || { echo "rank $r launch fail"; exit 1; }
  sleep 8
done

echo "[$(date +%H:%M:%S)] waiting for API healthy on cb98 (up to 40 min)"
READY=0
for i in $(seq 1 240); do
  ok=$(timeout 10 ssh "$HEAD" 'curl -s -m 5 http://127.0.0.1:8000/v1/models 2>/dev/null | grep -c glm-5.3-flash-ablit' 2>/dev/null)
  if [[ "$ok" == "1" ]]; then echo "[$(date +%H:%M:%S)] API healthy after ~$((i*10))s"; READY=1; break; fi
  dead=0
  for n in "${NODES[@]}"; do
    d=$(timeout 10 ssh "$n" 'docker ps -a --format "{{.Names}} {{.Status}}" | grep -c "vllm_glm53_dflash2.*Exited"' 2>/dev/null)
    [[ "${d:-0}" == "1" ]] && dead=1
  done
  if [[ $dead == 1 ]]; then
    echo "[$(date +%H:%M:%S)] a rank EXITED — dumping head logs"
    timeout 30 ssh "$HEAD" 'docker logs vllm_glm53_dflash2 2>&1 | tail -40' > "$DIR/ablit_dflash2_bootfail.log"
    exit 2
  fi
  sleep 10
done
[ $READY -eq 1 ] || exit 2
echo "[$(date +%H:%M:%S)] startup signature check"
timeout 30 ssh "$HEAD" 'docker logs vllm_glm53_dflash2 2>&1 | grep -E "auxiliary layers|GPU KV cache size|rejection sampler" | head -5'

echo "[$(date +%H:%M:%S)] running full battery on-box"
timeout 3600 ssh "$HEAD" 'BENCH_MODEL=glm-5.3-flash-ablit bash ~/battery_onbox.sh full /home/vikassridhar/battery_tp4_ablit_dflash2.json'
RC=$?
echo "[$(date +%H:%M:%S)] battery rc=$RC"
timeout 60 scp "$HEAD:/home/vikassridhar/battery_tp4_ablit_dflash2.json" "$DIR/battery_tp4_ablit_dflash2.json" && echo "banked battery_tp4_ablit_dflash2.json"
timeout 30 ssh "$HEAD" 'docker logs vllm_glm53_dflash2 2>&1 | grep -E "GPU KV cache size|Mean acceptance|acceptance rate" | tail -8' > "$DIR/battery_tp4_ablit_dflash2_meta.txt" 2>/dev/null
echo DONE rc=$RC

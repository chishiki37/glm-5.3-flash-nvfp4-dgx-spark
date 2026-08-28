#!/bin/bash
# Launch ABLIT TP4 t1-equivalent (fp8 KV + MTP3, 9GiB pin) and run full battery on-box.
# Mirrors battery_tp4_t1.sh exactly so ablit vs stock numbers are comparable.
set -uo pipefail
NODES=(edgexpert-bdea edgexpert-9105 edgexpert-3b24 aitopatom-cb98)  # ranks 3,2,1,0
HEAD=aitopatom-cb98
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[$(date +%H:%M)] pre-launch drop_caches + flushers (all 4)"
for n in "${NODES[@]}"; do
  timeout 30 ssh "$n" 'sync; cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; pkill -f cache_flusher 2>/dev/null; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
done

ranks=(3 2 1 0)
for i in 0 1 2 3; do
  r=${ranks[$i]}; node=${NODES[$i]}
  echo "[$(date +%H:%M)] launch rank $r on $node (ablit t1)"
  timeout 120 ssh "$node" 'GLM_KV_DTYPE=fp8_e4m3 GLM_KV_MEM=9663676416 GLM_SPEC=3 bash ~/launch_tp4_ablit.sh '"$r" || exit 1
  [ $i -lt 3 ] && sleep 22
done

echo "[$(date +%H:%M)] waiting for server ready (up to 25 min)"
READY=0
for i in $(seq 1 75); do
  if timeout 10 ssh "$HEAD" 'curl -s -m 5 http://127.0.0.1:8000/v1/models' 2>/dev/null | grep -q "glm-5.3-flash-ablit"; then READY=1; break; fi
  sleep 20
done
[ $READY -eq 1 ] || { echo "SERVER NOT READY"; timeout 60 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | tail -30' > "$DIR/ablit_tp4_bootfail.log"; exit 2; }
echo "[$(date +%H:%M)] server ready"

echo "[$(date +%H:%M)] running full battery on-box"
timeout 3600 ssh "$HEAD" 'BENCH_MODEL=glm-5.3-flash-ablit bash ~/battery_onbox.sh full /home/vikassridhar/battery_tp4_ablit.json'
RC=$?
echo "[$(date +%H:%M)] battery rc=$RC"
timeout 60 scp "$HEAD:/home/vikassridhar/battery_tp4_ablit.json" "$DIR/battery_tp4_ablit.json" && echo "banked battery_tp4_ablit.json"
timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -E "GPU KV cache size|Mean acceptance" | tail -8' > "$DIR/battery_tp4_ablit_meta.txt" 2>/dev/null
echo DONE rc=$RC

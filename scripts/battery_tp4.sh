#!/bin/bash
# Launch TP4 winner t1 (fp8 KV + MTP3, 9GiB pin) and run the full battery on-box.
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
  echo "[$(date +%H:%M)] launch rank $r on $node (t1)"
  timeout 120 ssh "$node" 'GLM_KV_DTYPE=fp8_e4m3 GLM_KV_MEM=9663676416 GLM_SPEC=3 bash ~/launch_tp4_param.sh '"$r" || exit 1
  [ $i -lt 3 ] && sleep 22
done

echo "[$(date +%H:%M)] running full battery on-box"
timeout 3600 ssh "$HEAD" 'bash ~/battery_onbox.sh full /home/vikassridhar/battery_tp4_t1.json'
RC=$?
echo "[$(date +%H:%M)] battery rc=$RC"
timeout 60 scp "$HEAD:/home/vikassridhar/battery_tp4_t1.json" "$DIR/battery_tp4_t1.json" && echo "banked battery_tp4_t1.json"
timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -E "GPU KV cache size|Mean acceptance" | tail -5' > "$DIR/battery_tp4_t1_meta.txt" 2>/dev/null
echo DONE

#!/bin/bash
# Launch TP2 winner s3 (fp8 KV + MTP3) and run the full battery on-box.
set -uo pipefail
HEAD=aitopatom-cb98
WORK=edgexpert-3b24
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[$(date +%H:%M)] pre-launch drop_caches + flushers"
for n in "$WORK" "$HEAD"; do
  timeout 30 ssh "$n" 'sync; cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
done

echo "[$(date +%H:%M)] launch worker rank1 (s3)"
timeout 120 ssh "$WORK" 'GLM_KV_DTYPE=fp8_e4m3 GLM_KV_MEM=4445787956 GLM_SPEC=3 bash ~/launch_tp2_param.sh 1' || exit 1
sleep 25
echo "[$(date +%H:%M)] launch head rank0 (s3)"
timeout 120 ssh "$HEAD" 'GLM_KV_DTYPE=fp8_e4m3 GLM_KV_MEM=4445787956 GLM_SPEC=3 bash ~/launch_tp2_param.sh 0' || exit 1

echo "[$(date +%H:%M)] running full battery on-box (health wait, warmup, measure)"
timeout 3600 ssh "$HEAD" 'bash ~/battery_onbox.sh full /home/vikassridhar/battery_tp2_s3.json'
RC=$?
echo "[$(date +%H:%M)] battery rc=$RC"
timeout 60 scp "$HEAD:/home/vikassridhar/battery_tp2_s3.json" "$DIR/battery_tp2_s3.json" && echo "banked battery_tp2_s3.json"
# capture acceptance + kvpool
timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -E "GPU KV cache size|Mean acceptance" | tail -5' > "$DIR/battery_tp2_s3_meta.txt" 2>/dev/null
echo DONE

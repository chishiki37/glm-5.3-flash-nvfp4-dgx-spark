#!/bin/bash
# Launch ABLIT TP2 winner-equivalent s3 (fp8 KV + MTP3, 4.1GiB pin) and run full battery on-box.
# Mirrors battery_tp2_s3.sh so ablit vs stock TP2 numbers are comparable.
set -uo pipefail
HEAD=aitopatom-cb98
WORK=edgexpert-3b24
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[$(date +%H:%M)] cleanup any stale TP4 ranks on 9105/bdea"
for n in edgexpert-9105 edgexpert-bdea; do
  timeout 30 ssh "$n" 'docker rm -f vllm_glm53 2>/dev/null || true' || true
done

echo "[$(date +%H:%M)] pre-launch drop_caches + flushers"
for n in "$WORK" "$HEAD"; do
  timeout 30 ssh "$n" 'sync; cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
done

echo "[$(date +%H:%M)] launch worker rank1 (ablit s3)"
timeout 120 ssh "$WORK" 'GLM_KV_DTYPE=fp8_e4m3 GLM_KV_MEM=4445787956 GLM_SPEC=3 bash ~/launch_tp2_ablit.sh 1' || exit 1
sleep 25
echo "[$(date +%H:%M)] launch head rank0 (ablit s3)"
timeout 120 ssh "$HEAD" 'GLM_KV_DTYPE=fp8_e4m3 GLM_KV_MEM=4445787956 GLM_SPEC=3 bash ~/launch_tp2_ablit.sh 0' || exit 1

echo "[$(date +%H:%M)] waiting for server ready (up to 20 min)"
READY=0
for i in $(seq 1 60); do
  if timeout 10 ssh "$HEAD" 'curl -s -m 5 http://127.0.0.1:8000/v1/models' 2>/dev/null | grep -q "glm-5.3-flash-ablit"; then READY=1; break; fi
  sleep 20
done
[ $READY -eq 1 ] || { echo "SERVER NOT READY"; timeout 60 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | tail -30' > "$DIR/ablit_tp2_bootfail.log"; exit 2; }
echo "[$(date +%H:%M)] server ready"

echo "[$(date +%H:%M)] running full battery on-box"
timeout 3600 ssh "$HEAD" 'BENCH_MODEL=glm-5.3-flash-ablit bash ~/battery_onbox.sh full /home/vikassridhar/battery_tp2_ablit.json'
RC=$?
echo "[$(date +%H:%M)] battery rc=$RC"
timeout 60 scp "$HEAD:/home/vikassridhar/battery_tp2_ablit.json" "$DIR/battery_tp2_ablit.json" && echo "banked battery_tp2_ablit.json"
timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -E "GPU KV cache size|Mean acceptance" | tail -8' > "$DIR/battery_tp2_ablit_meta.txt" 2>/dev/null
echo DONE rc=$RC

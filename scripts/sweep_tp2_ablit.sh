#!/bin/bash
# GLM-5.3 TP2 autoresearch sweep — run on the GATEWAY box. Orchestrates cb98+3b24 via ssh.
# Full teardown per config (freshness protocol), worker-first launch, health wait, 3-run probe.
set -uo pipefail

HEAD=aitopatom-cb98
WORK=edgexpert-3b24
HEAD_IP=100.102.97.64
BENCH_URL="http://$HEAD_IP:8000/v1/chat/completions"
export BENCH_URL BENCH_MODEL=glm-5.3-flash-ablit
DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS="$DIR/sweep_tp2_ablit_results.jsonl"
MARKER_DIR="$DIR/sweep_markers_ablit"
mkdir -p "$MARKER_DIR"

# name|kv_dtype|kv_mem|spec_tokens
CONFIGS=(
  "s0_v7_bf16_nomtp|auto||0"
  "s1_fp8_nomtp|fp8_e4m3||0"
  "s2_fp8_mtp4|fp8_e4m3|4445787956|4"
  "s3_fp8_mtp3|fp8_e4m3|4445787956|3"
)

teardown() {
  echo "[$(date +%H:%M)] teardown both ranks"
  for n in "$WORK" "$HEAD"; do
    timeout 60 ssh -o ConnectTimeout=10 "$n" '
      docker logs vllm_glm53 > /var/tmp/glm53-vllm-cache/logs_$(hostname)_$(date +%s).txt 2>&1 || true
      docker rm -f vllm_glm53 2>/dev/null || true
      pkill -f cache_flusher 2>/dev/null || true
      sync
      cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null || true
    ' || echo "  teardown hiccup on $n"
  done
  sleep 5
}

launch_config() { # $1 kv_dtype  $2 kv_mem  $3 spec
  local kv="$1" kvm="$2" spec="$3"
  echo "[$(date +%H:%M)] launch worker (rank1) kv=$kv kvm=$kvm spec=$spec"
  timeout 120 ssh -o ConnectTimeout=10 "$WORK" \
    "GLM_KV_DTYPE=$kv GLM_KV_MEM=$kvm GLM_SPEC=$spec bash ~/launch_tp2_ablit.sh 1" || return 1
  sleep 25
  echo "[$(date +%H:%M)] launch head (rank0)"
  timeout 120 ssh -o ConnectTimeout=10 "$HEAD" \
    "GLM_KV_DTYPE=$kv GLM_KV_MEM=$kvm GLM_SPEC=$spec bash ~/launch_tp2_ablit.sh 0" || return 1
  # flushers on both nodes during boot
  for n in "$HEAD" "$WORK"; do
    scp -q "$DIR/cache_flusher_spw.sh" "$n:/tmp/cache_flusher_spw.sh" 2>/dev/null
    timeout 30 ssh "$n" 'chmod +x /tmp/cache_flusher_spw.sh; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
  done
  return 0
}

probe_and_bank() { # $1 name  $2 kv  $3 kvm  $4 spec
  local name="$1"
  echo "[$(date +%H:%M)] probing $name (on-box health wait up to 40 min)"
  local probe
  probe=$(timeout 2700 ssh -o ConnectTimeout=10 "$HEAD" 'bash ~/probe_onbox_ablit.sh')
  local rc=$?
  local accept=""
  if [ $rc -eq 0 ]; then
    accept=$(timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -E "SpecDecoding|Mean acceptance" | tail -3' 2>/dev/null | tr '\n' ' ')
    local kvpool
    kvpool=$(timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -E "GPU KV cache size|Available KV cache memory" | tail -2' 2>/dev/null | tr '\n' ' ')
    echo "{\"config\":\"$name\",\"kv_dtype\":\"$2\",\"kv_mem\":\"$3\",\"spec\":\"$4\",\"probe\":$probe,\"acceptance\":\"$accept\",\"kvpool\":\"$kvpool\",\"ts\":\"$(date -Is)\"}" >> "$RESULTS"
    echo "  $name -> $probe"
    echo "  kvpool: $kvpool"
    touch "$MARKER_DIR/$name.done"
  else
    echo "{\"config\":\"$name\",\"error\":\"probe failed rc=$rc\",\"ts\":\"$(date -Is)\"}" >> "$RESULTS"
    echo "  $name -> PROBE FAILED (rc=$rc); capturing head log tail:"
    timeout 30 ssh "$HEAD" 'docker logs --tail 30 vllm_glm53 2>&1' || true
    touch "$MARKER_DIR/$name.failed"
  fi
}

echo "=== GLM TP2 sweep start $(date -Is) ==="
for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r name kv kvm spec <<< "$cfg"
  if [ -f "$MARKER_DIR/$name.done" ] || [ -f "$MARKER_DIR/$name.failed" ]; then
    echo "skip $name (already run)"
    continue
  fi
  teardown
  if launch_config "$kv" "$kvm" "$spec"; then
    probe_and_bank "$name" "$kv" "$kvm" "$spec"
  else
    echo "{\"config\":\"$name\",\"error\":\"launch failed\",\"ts\":\"$(date -Is)\"}" >> "$RESULTS"
    touch "$MARKER_DIR/$name.failed"
  fi
done
teardown
echo "=== sweep done $(date -Is) ==="
cat "$RESULTS"

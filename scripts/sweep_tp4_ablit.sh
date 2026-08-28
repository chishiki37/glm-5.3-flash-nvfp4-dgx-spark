#!/bin/bash
# GLM-5.3 TP4 autoresearch sweep — run on the GATEWAY box. Orchestrates 4 Sparks via ssh.
# Launch order per recipe: rank 3 -> 2 -> 1 -> head 0 last, ~20s apart. Flusher on all nodes.
set -uo pipefail

HEAD=aitopatom-cb98
W1=edgexpert-3b24
W2=edgexpert-9105
W3=edgexpert-bdea
ALL_NODES=("$W3" "$W2" "$W1" "$HEAD")   # launch order: rank3, rank2, rank1, rank0
HEAD_IP=100.102.97.64
BENCH_URL="http://$HEAD_IP:8000/v1/chat/completions"
export BENCH_URL BENCH_MODEL=glm-5.3-flash-ablit
DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS="$DIR/sweep_tp4_ablit_results.jsonl"
MARKER_DIR="$DIR/sweep_markers_ablit"
mkdir -p "$MARKER_DIR"

# name|kv_dtype|kv_mem|spec_tokens
CONFIGS=(
  "t0_tp4_fp8_mtp4|fp8_e4m3|9663676416|4"
  "t1_tp4_fp8_mtp3|fp8_e4m3|9663676416|3"
  "t2_tp4_bf16_nomtp|auto|none|0"
)

teardown() {
  echo "[$(date +%H:%M)] teardown all 4 ranks"
  for n in "${ALL_NODES[@]}"; do
    timeout 60 ssh -o ConnectTimeout=10 "$n" '
      mkdir -p /var/tmp/glm53-vllm-cache
      docker logs vllm_glm53 > /var/tmp/glm53-vllm-cache/logs_$(hostname)_$(date +%s).txt 2>&1 || true
      docker rm -f vllm_glm53 2>/dev/null || true
      pkill -f cache_flusher 2>/dev/null || true
      sync
      cat /tmp/.spw | sudo -S bash -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null || true
    ' || echo "  teardown hiccup on $n"
  done
  sleep 5
}

launch_config() { # $1 kv_dtype $2 kv_mem $3 spec
  local kv="$1" kvm="$2" spec="$3" r
  # flushers first
  for n in "${ALL_NODES[@]}"; do
    scp -q "$DIR/cache_flusher_spw.sh" "$n:/tmp/cache_flusher_spw.sh" 2>/dev/null
    timeout 30 ssh "$n" 'chmod +x /tmp/cache_flusher_spw.sh; nohup /tmp/cache_flusher_spw.sh > /tmp/flusher.log 2>&1 &' || true
  done
  local ranks=(3 2 1 0)
  for i in 0 1 2 3; do
    r=${ranks[$i]}
    local node=${ALL_NODES[$i]}
    echo "[$(date +%H:%M)] launch rank $r on $node (kv=$kv kvm=$kvm spec=$spec)"
    timeout 120 ssh -o ConnectTimeout=10 "$node" \
      "GLM_KV_DTYPE=$kv GLM_KV_MEM=$kvm GLM_SPEC=$spec bash ~/launch_tp4_ablit.sh $r" || return 1
    [ $i -lt 3 ] && sleep 22
  done
  return 0
}

probe_and_bank() {
  local name="$1"
  echo "[$(date +%H:%M)] probing $name (on-box health wait up to 40 min)"
  local probe
  probe=$(timeout 2700 ssh -o ConnectTimeout=10 "$HEAD" 'bash ~/probe_onbox_ablit.sh')
  local rc=$?
  if [ $rc -eq 0 ]; then
    local accept kvpool
    accept=$(timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -E "SpecDecoding|Mean acceptance" | tail -3' 2>/dev/null | tr '\n' ' ')
    kvpool=$(timeout 30 ssh "$HEAD" 'docker logs vllm_glm53 2>&1 | grep -E "GPU KV cache size|Available KV cache memory" | tail -2' 2>/dev/null | tr '\n' ' ')
    echo "{\"config\":\"$name\",\"kv_dtype\":\"$2\",\"kv_mem\":\"$3\",\"spec\":\"$4\",\"probe\":$probe,\"acceptance\":\"$accept\",\"kvpool\":\"$kvpool\",\"ts\":\"$(date -Is)\"}" >> "$RESULTS"
    echo "  $name -> $probe"
    echo "  kvpool: $kvpool"
    touch "$MARKER_DIR/$name.done"
  else
    echo "{\"config\":\"$name\",\"error\":\"probe failed rc=$rc\",\"ts\":\"$(date -Is)\"}" >> "$RESULTS"
    echo "  $name -> PROBE FAILED (rc=$rc); head log tail:"
    timeout 30 ssh "$HEAD" 'docker logs --tail 30 vllm_glm53 2>&1' || true
    touch "$MARKER_DIR/$name.failed"
  fi
}

echo "=== GLM TP4 sweep start $(date -Is) ==="
for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r name kv kvm spec <<< "$cfg"
  if [ -f "$MARKER_DIR/$name.done" ] || [ -f "$MARKER_DIR/$name.failed" ]; then
    echo "skip $name (already run)"; continue
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
echo "=== TP4 sweep done $(date -Is) ==="
cat "$RESULTS"

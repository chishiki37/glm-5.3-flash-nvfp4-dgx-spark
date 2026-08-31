#!/usr/bin/env bash
# GLM-5.3-Flash NVFP4 (RedHatAI) TP2 DFlash2 launcher — 2-node lane (262K ctx), .12+.14 variant (.1 OOMs under TP2 rank load).
# Ranks: 0=3b24(.12, head), 1=cb98(.14). Weights via NFS /var/tmp/models-cb98 from .14.
# Env overrides: FLASH_KV FLASH_MNS FLASH_MNBT FLASH_EAGER FLASH_CTX FLASH_K
set -euo pipefail
NODE_RANK="${1:?usage: flash-launch-tp2.sh <0|1>}"

IMAGE="radixark/vllm-glm53-flash:sm121-v8-dflash2"
NAME="vllm_glm53_dflash2"
MODEL_PATH="/models/glm-5.3-flash-nvfp4"
DRAFT_PATH="/models/dflash2-draft"
CACHE_HOST_PATH="/var/tmp/glm53-vllm-cache"
HEAD_IP="10.10.10.12"
MPORT="29534"
PORT="8000"

FLASH_KV="${FLASH_KV:-none}"   # "none" = profiler-sized pool (the TP2 lesson); else bytes
FLASH_MNS="${FLASH_MNS:-6}"
FLASH_MNBT="${FLASH_MNBT:-8192}"
FLASH_CTX="${FLASH_CTX:-262144}"
FLASH_K="${FLASH_K:-7}"
FLASH_GMU="${FLASH_GMU:-0.88}"   # startup gate: free@boot ~108.16/121.69 GiB → gmu≤0.888; 0.89 hard-rejected
EAGER_FLAG="--enforce-eager"
if [ "${FLASH_EAGER:-1}" = "0" ]; then EAGER_FLAG=""; fi
KV_FLAG=""
if [ "$FLASH_KV" != "none" ]; then KV_FLAG="--kv-cache-memory $FLASH_KV"; fi

case "$NODE_RANK" in
  0) HOST_IP=10.10.10.12; HEADLESS="";  MODEL_HOST_PATH="/var/tmp/models-cb98/glm-5.3-flash-nvfp4-redhat"; DRAFT_HOST_PATH="/var/tmp/models-cb98/GLM-5.3-Flash-DFlash2" ;;
  1) HOST_IP=10.10.10.14; HEADLESS="--headless"; MODEL_HOST_PATH="/var/tmp/models-cb98/glm-5.3-flash-nvfp4-redhat"; DRAFT_HOST_PATH="/var/tmp/models-cb98/GLM-5.3-Flash-DFlash2" ;;
  *) echo "rank must be 0-1" >&2; exit 2 ;;
esac

test -f "$MODEL_HOST_PATH/config.json" || { echo "missing $MODEL_HOST_PATH/config.json" >&2; exit 3; }
test -f "$MODEL_HOST_PATH/chat_template_mm.jinja" || { echo "missing chat_template_mm.jinja" >&2; exit 3; }
test -f "$DRAFT_HOST_PATH/config.json" || { echo "missing drafter" >&2; exit 4; }
test -f "$HOME/patches/sparse_attn_indexer_kpool.py" || { echo "missing kpool patch" >&2; exit 5; }
mkdir -p "$CACHE_HOST_PATH"
docker rm -f "$NAME" 2>/dev/null || true

docker run --gpus all -d \
  --name "$NAME" --restart no \
  --network host --ipc host --shm-size 32g --memory 112g --memory-swap 112g \
  --ulimit memlock=-1:-1 --cap-add IPC_LOCK \
  --device /dev/infiniband:/dev/infiniband \
  -v "$MODEL_HOST_PATH:$MODEL_PATH:ro" \
  -v "$DRAFT_HOST_PATH:$DRAFT_PATH:ro" \
  -v "$CACHE_HOST_PATH:/cache" \
  -v "$HOME/patches/sparse_attn_indexer_kpool.py:/usr/local/lib/python3.12/dist-packages/vllm/model_executor/layers/sparse_attn_indexer_kpool.py:ro" \
  -e VLLM_HOST_IP=$HOST_IP \
  -e HF_HOME=/cache/huggingface \
  -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
  -e VLLM_ENGINE_READY_TIMEOUT_S=3600 \
  -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e TORCH_CUDA_ARCH_LIST=12.1a -e FLASHINFER_CUDA_ARCH_LIST=12.1a \
  -e FLASHINFER_DISABLE_VERSION_CHECK=1 \
  -e NCCL_NET=IB -e NCCL_IB_DISABLE=0 \
  -e NCCL_IB_HCA=rocep1s0f0 \
  -e NCCL_IB_ROCE_VERSION_NUM=2 -e NCCL_IB_ADDR_FAMILY=AF_INET \
  -e NCCL_IB_ADDR_RANGE=10.10.10.0/24 \
  -e NCCL_SOCKET_IFNAME=enp1s0f0np0 -e GLOO_SOCKET_IFNAME=enp1s0f0np0 \
  -e TP_SOCKET_IFNAME=enp1s0f0np0 -e MN_IF_NAME=enp1s0f0np0 \
  -e NCCL_NVLS_ENABLE=0 -e NCCL_CROSS_NIC=0 -e NCCL_IB_MERGE_NICS=0 \
  -e NCCL_CUMEM_ENABLE=0 -e NCCL_IGNORE_CPU_AFFINITY=1 -e NCCL_DEBUG=WARN \
  -e TORCH_NCCL_ASYNC_ERROR_HANDLING=1 \
  "$IMAGE" \
    "$MODEL_PATH" \
    --served-model-name glm-5.3-flash \
    --host 0.0.0.0 --port "$PORT" \
    --trust-remote-code \
    --tensor-parallel-size 2 \
    --gpu-memory-utilization "$FLASH_GMU" \
    --max-model-len "$FLASH_CTX" \
    --max-num-seqs "$FLASH_MNS" --block-size 2304 --moe-backend marlin \
    --max-num-batched-tokens "$FLASH_MNBT" \
    --speculative-config '{"method":"dflash","model":"'"$DRAFT_PATH"'","num_speculative_tokens":'"$FLASH_K"'}' \
    --kv-cache-dtype fp8_e4m3 $KV_FLAG \
    $EAGER_FLAG \
    --tool-call-parser glm47 --enable-auto-tool-choice \
    --reasoning-parser glm45 --chat-template "$MODEL_PATH/chat_template_mm.jinja" \
    --default-chat-template-kwargs '{"enable_thinking": false}' \
    --distributed-executor-backend mp \
    --nnodes 2 --node-rank "$NODE_RANK" \
    --master-addr "$HEAD_IP" --master-port "$MPORT" \
    $HEADLESS

echo "launched $NAME rank=$NODE_RANK tp2 kv=$FLASH_KV mns=$FLASH_MNS mnbt=$FLASH_MNBT ctx=$FLASH_CTX k=$FLASH_K"
sleep 2
docker ps --format '{{.Names}} {{.Status}}' | grep "$NAME" || { echo "$NAME exited; docker logs $NAME" >&2; exit 1; }

#!/usr/bin/env bash
# Parameterized TP2 DFlash2 launcher for optimization sweep (9105 rank0 + bdea rank1).
# Usage: launch_tp2_dflash2_param.sh <0|1>
# Env levers (must match across ranks):
#   SPEC_N       num_speculative_tokens (default 7 = block_size-1)
#   SPEC_SAMPLE  draft_sample_method greedy|probabilistic (default greedy)
#   MNS          --max-num-seqs (default 6)
set -euo pipefail
NODE_RANK="${1:?usage: launch_tp2_dflash2_param.sh <0|1>}"
SPEC_N="${SPEC_N:-7}"
SPEC_SAMPLE="${SPEC_SAMPLE:-greedy}"
MNS="${MNS:-6}"

IMAGE="radixark/vllm-glm53-flash:sm121-v8-dflash2"
NAME="vllm_glm53_dflash2"
MODEL_PATH="/models/glm-5.3-flash-nvfp4"
DRAFT_HOST_PATH="/var/tmp/models-cb98/GLM-5.3-Flash-DFlash2"
DRAFT_PATH="/models/dflash2-draft"
CACHE_HOST_PATH="/var/tmp/glm53-vllm-cache"
HEAD_IP="10.10.10.1"
MPORT="29522"
PORT="8000"

case "$NODE_RANK" in
  0) HOST_IP=10.10.10.1; HEADLESS="" ;;
  1) HOST_IP=10.10.10.2; HEADLESS="--headless" ;;
  *) echo "rank must be 0 or 1" >&2; exit 2 ;;
esac
MODEL_HOST_PATH="/var/tmp/models-cb98/glm-5.3-flash-nvfp4"

test -f "$MODEL_HOST_PATH/config.json" || { echo "missing $MODEL_HOST_PATH/config.json" >&2; exit 3; }
test -f "$DRAFT_HOST_PATH/config.json" || { echo "missing $DRAFT_HOST_PATH/config.json" >&2; exit 4; }
mkdir -p "$CACHE_HOST_PATH"
docker rm -f "$NAME" 2>/dev/null || true

docker run --gpus all -d \
  --name "$NAME" --restart no \
  --network host --ipc host --shm-size 32g \
  --ulimit memlock=-1:-1 --cap-add IPC_LOCK \
  --device /dev/infiniband:/dev/infiniband \
  -v "$MODEL_HOST_PATH:$MODEL_PATH:ro" \
  -v "$DRAFT_HOST_PATH:$DRAFT_PATH:ro" \
  -v "$CACHE_HOST_PATH:/cache" \
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
    --gpu-memory-utilization 0.85 \
    --max-model-len 262144 \
    --max-num-seqs "$MNS" --block-size 2304 --moe-backend marlin \
    --speculative-config '{"method":"dflash","model":"'"$DRAFT_PATH"'","num_speculative_tokens":'"$SPEC_N"',"draft_sample_method":"'"$SPEC_SAMPLE"'"}' \
    --kv-cache-dtype fp8_e4m3 --kv-cache-memory 4445787956 \
    --enforce-eager \
    --tool-call-parser glm47 --enable-auto-tool-choice \
    --reasoning-parser glm45 --default-chat-template-kwargs '{"enable_thinking": false}' \
    --distributed-executor-backend mp \
    --nnodes 2 --node-rank "$NODE_RANK" \
    --master-addr "$HEAD_IP" --master-port "$MPORT" \
    $HEADLESS

echo "launched $NAME rank=$NODE_RANK spec_n=$SPEC_N sample=$SPEC_SAMPLE mns=$MNS"
sleep 2
docker ps --format '{{.Names}} {{.Status}}' | grep "$NAME" || { echo "$NAME exited; docker logs $NAME" >&2; exit 1; }

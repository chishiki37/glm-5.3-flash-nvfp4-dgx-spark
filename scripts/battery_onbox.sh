#!/bin/bash
# On-box battery runner (cb98 localhost) — full warmup+measure, C1/C4/C8
# Usage: bash battery_onbox.sh [warmup|measure|full] [out.json]
export BENCH_URL="http://127.0.0.1:8000/v1/chat/completions"
export BENCH_MODEL="${BENCH_MODEL:-glm-5.3-flash}"
MODE="${1:-full}"
export OUT_JSON="${2:-/home/vikassridhar/battery_result.json}"
python3 /home/vikassridhar/battery.py "$MODE"

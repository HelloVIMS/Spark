#!/usr/bin/env bash
# Generic guarded vLLM launcher. Sources site config, applies CPU
# isolation, enforces the shared GPU-memory budget, then execs vllm.
#
# Required env (set in the systemd unit or caller):
#   VLLM_MODEL          model path, or a name resolved under MODELS_DIR
#   VLLM_PORT           port to serve on
#
# Optional env:
#   VLLM_NAME           label for log/budget messages (default: model name)
#   VLLM_GPU_MEM_UTIL   fraction for --gpu-memory-utilization (default: 0.70)
#   VLLM_BIN            vllm executable (default: vllm on PATH)
#
# Any additional arguments are passed straight through to `vllm serve`.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Site config installed by install.sh.
_conf="${XDG_CONFIG_HOME:-$HOME/.config}/spark/spark.conf"
# shellcheck disable=SC1090
[ -f "$_conf" ] && . "$_conf"

: "${VLLM_MODEL:?set VLLM_MODEL in the unit or caller environment}"
: "${VLLM_PORT:?set VLLM_PORT in the unit or caller environment}"
VLLM_NAME="${VLLM_NAME:-$(basename "$VLLM_MODEL")}"
VLLM_GPU_MEM_UTIL="${VLLM_GPU_MEM_UTIL:-0.70}"
VLLM_BIN="${VLLM_BIN:-vllm}"

# Relative model paths resolve under MODELS_DIR.
case "$VLLM_MODEL" in
    /*) ;;
    *)  VLLM_MODEL="${MODELS_DIR:-$HOME/models}/$VLLM_MODEL" ;;
esac

# Conservative defaults that kept a GB10 stable under parallel desktop load.
export MAX_JOBS="${MAX_JOBS:-1}"
export NVCC_THREADS="${NVCC_THREADS:-1}"
export VLLM_USE_V1="${VLLM_USE_V1:-0}"
export CUDA_LAUNCH_BLOCKING="${CUDA_LAUNCH_BLOCKING:-1}"
export FLASHINFER_DISABLE_AUTOTUNE="${FLASHINFER_DISABLE_AUTOTUNE:-1}"
export VLLM_ENABLE_V1_MULTIPROCESSING="${VLLM_ENABLE_V1_MULTIPROCESSING:-0}"

# shellcheck disable=SC1091
. "$here/vllm_env.sh"
# shellcheck disable=SC1091
. "$here/vllm_mem_budget.sh"

assert_mem_budget "$VLLM_GPU_MEM_UTIL" "$VLLM_NAME"

exec taskset -c "$VLLM_CPU_CORES" "$VLLM_BIN" serve "$VLLM_MODEL" \
    --port "$VLLM_PORT" \
    --gpu-memory-utilization "$VLLM_GPU_MEM_UTIL" \
    "$@"

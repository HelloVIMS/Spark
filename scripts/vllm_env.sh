#!/usr/bin/env bash
# Shared CPU isolation for all vLLM processes.
#
# Reserves a fraction of cores for interactive processes (desktop, IDE,
# daemons, test harnesses) and pins vLLM to the rest via taskset.
# Source this from any vLLM launch script.
#
# Tunables (set before sourcing, or in spark.conf):
#   VLLM_CPU_SHARE   fraction of cores for vLLM (default: 0.80)

_total=$(nproc)
_share="${VLLM_CPU_SHARE:-0.80}"
_vllm_cores=$(awk -v t="$_total" -v s="$_share" 'BEGIN{print int(t*s)}')

# Clamp: at least 2 cores for vLLM, at least 2 for everything else
[ "$_vllm_cores" -lt 2 ] && _vllm_cores=2
[ "$_vllm_cores" -gt $(( _total - 2 )) ] && _vllm_cores=$(( _total - 2 ))

export VLLM_CPU_CORES="0-$(( _vllm_cores - 1 ))"
export OMP_NUM_THREADS="$_vllm_cores"
export RESERVED_CPU_CORES="${_vllm_cores}-$(( _total - 1 ))"

unset _total _vllm_cores _share

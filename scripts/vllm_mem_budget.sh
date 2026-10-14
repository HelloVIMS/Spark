#!/usr/bin/env bash
# Shared GPU-memory budget for vLLM services.
#
# WHY THIS EXISTS
#
# On unified-memory machines (NVIDIA GB10 / DGX Spark, AMD Strix Halo,
# Apple Silicon) there is NO discrete VRAM -- the CPU and GPU share one
# pool. `nvidia-smi --query-gpu=memory.total` returns [N/A] on a GB10.
# So vLLM's --gpu-memory-utilization is not "a share of spare VRAM the
# host will never miss"; it is a share of TOTAL SYSTEM RAM, taken from
# the same pool the desktop, Electron apps, browsers and test harnesses
# draw from -- and vLLM reserves it up front rather than growing on demand.
#
# Each service passes its fraction independently and nothing ever adds
# them up. Real numbers that shipped to a GB10:
#
#   embeddings   0.10   (always on)
#   gemma4       0.65   -> with embeddings, 0.75 = 91GB of 122GB
#   vision-agent 0.75   -> with embeddings, 0.85 = 104GB
#   longcontext  0.95   -> with embeddings, 1.05 = MORE THAN THE MACHINE HAS
#
# At 1.05 the box cannot start both without the OOM killer picking a
# victim -- which is as likely to be the desktop or a daemon as vLLM.
#
# THE BUDGET
#
#   0.55 total  headroom for browser/Electron test runs
#   0.65 total  normal desktop development
#   0.80 total  inference-heavy, expect swap under desktop load
#
# On discrete-VRAM GPUs the same guard applies, but the fractions sum
# against VRAM instead of system RAM -- still worth enforcing so two
# servers cannot claim the same device.
#
# Every service reads its fraction from VLLM_GPU_MEM_UTIL so it can be
# retuned with a systemd drop-in instead of editing a wrapper script.
#
# Tunables (set before sourcing, or in spark.conf):
#   VLLM_MEM_BUDGET      ceiling on summed fractions (default: 0.80)
#   VLLM_UNIFIED_MEMORY  auto|1|0 -- unified-memory semantics (default: auto)

VLLM_MEM_BUDGET="${VLLM_MEM_BUDGET:-0.80}"

# Detect unified memory: a discrete GPU reports a real memory.total; a
# GB10/Grace-Blackwell reports [N/A]. Only changes the wording of the
# fatal message -- the sum must hold either way.
_vllm_pool_desc() {
    local mode="${VLLM_UNIFIED_MEMORY:-auto}"
    if [ "$mode" = "auto" ]; then
        local total
        total="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)"
        case "$total" in
            ''|*N/A*|*'[N'*) mode=1 ;;
            *) mode=0 ;;
        esac
    fi
    if [ "$mode" = "1" ]; then
        echo "a share of TOTAL SYSTEM RAM (unified memory),"
    else
        echo "a share of GPU VRAM,"
    fi
}

# Sum --gpu-memory-utilization across vLLM servers ALREADY running, then
# refuse to start if adding ours would breach the budget.
#
# Loud failure is the point. The alternative is a reservation the pool
# cannot satisfy, resolved by the OOM killer picking a victim.
assert_mem_budget() {
    local want="$1" name="$2"
    local running="0" found=""

    for cmdline in /proc/[0-9]*/cmdline; do
        local pid="${cmdline#/proc/}"; pid="${pid%/cmdline}"
        [ "$pid" = "$$" ] && continue
        local args
        # Redirected inside a group so a process exiting mid-scan is silent.
        # 2>/dev/null on tr alone does not cover it: the failure is bash
        # unable to OPEN the file for redirection, which it reports itself.
        args="$( { tr '\0' ' ' < "$cmdline"; } 2>/dev/null )" || continue
        [ -n "$args" ] || continue
        case "$args" in
            *"vllm serve"*) ;;
            *) continue ;;
        esac
        local frac
        frac="$(printf '%s\n' "$args" | grep -oE 'gpu-memory-utilization[= ]+[0-9.]+' | grep -oE '[0-9.]+$')"
        [ -n "$frac" ] || continue
        # A port is the only stable label available here; the model path is
        # long and the unit name is not visible from the process.
        local port
        port="$(printf '%s\n' "$args" | grep -oE '\-\-port[= ]+[0-9]+' | grep -oE '[0-9]+$')"
        running="$(awk -v a="$running" -v b="$frac" 'BEGIN{print a+b}')"
        found="${found}  pid ${pid} port ${port:-?} at ${frac}"$'\n'
    done

    local total
    total="$(awk -v a="$running" -v b="$want" 'BEGIN{print a+b}')"
    if awk -v t="$total" -v c="$VLLM_MEM_BUDGET" 'BEGIN{exit !(t > c + 1e-9)}'; then
        {
            echo "FATAL: ${name} wants --gpu-memory-utilization ${want}, which would"
            echo "       take the GPU-memory total to ${total}, over the ${VLLM_MEM_BUDGET} budget."
            echo
            echo "       Each fraction is $(_vllm_pool_desc) not free headroom."
            echo "       Already reserved (${running}):"
            printf '%s' "${found:-  (nothing)}"
            echo
            echo "       Either stop a running vLLM service, lower VLLM_GPU_MEM_UTIL for"
            echo "       this one, or raise VLLM_MEM_BUDGET if you accept the consequences."
        } >&2
        exit 1
    fi

    echo "[vllm] ${name} at ${want}; GPU-memory total ${total} of ${VLLM_MEM_BUDGET} budget"
}

#!/usr/bin/env bash
# =============================================================================
# gpu-monitor.sh - GPU temperature and usage monitoring
# Alerts if temperature exceeds threshold, pauses Ollama workloads if needed
# Usage: gpu-monitor.sh [--daemon]
# =============================================================================
set -euo pipefail

TEMP_THRESHOLD=80       # Celsius
TEMP_CRITICAL=90        # Celsius - emergency shutdown
CHECK_INTERVAL=60       # Seconds
LOGS_DIR="${HARNESS_DIR:-/harness}/logs"
SCRIPTS_DIR="${HARNESS_DIR:-/harness}/scripts"

check_gpu() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo "nvidia-smi not found"
        return 1
    fi

    local temp util mem_used mem_total
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
    util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
    mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
    mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    echo "[$timestamp] GPU: ${temp}°C | Util: ${util}% | VRAM: ${mem_used}/${mem_total} MiB"

    # Critical temperature - emergency action
    if [[ $temp -ge $TEMP_CRITICAL ]]; then
        echo "CRITICAL: GPU temperature ${temp}°C >= ${TEMP_CRITICAL}°C!"
        "$SCRIPTS_DIR/notify.sh" "gpu_critical" "system" "GPU temp: ${temp}°C - EMERGENCY" || true
        # Stop Ollama
        systemctl stop ollama 2>/dev/null || true
        # Could also stop the agent container
        return 2
    fi

    # High temperature - throttle
    if [[ $temp -ge $TEMP_THRESHOLD ]]; then
        echo "WARNING: GPU temperature ${temp}°C >= ${TEMP_THRESHOLD}°C"
        "$SCRIPTS_DIR/notify.sh" "gpu_hot" "system" "GPU temp: ${temp}°C - pausing Ollama" || true
        # Pause Ollama jobs by stopping the service temporarily
        systemctl stop ollama 2>/dev/null || true
        sleep 120  # Cool down for 2 minutes
        systemctl start ollama 2>/dev/null || true
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
MODE="${1:-once}"

case "$MODE" in
    --daemon)
        echo "GPU monitor daemon started (interval: ${CHECK_INTERVAL}s)"
        while true; do
            check_gpu >> "$LOGS_DIR/gpu-monitor.log" 2>&1 || true
            sleep "$CHECK_INTERVAL"
        done
        ;;
    *)
        check_gpu
        ;;
esac

#!/usr/bin/env bash
# =============================================================================
# watchdog.sh - External heartbeat watchdog
# Checks if agent is alive and sends alerts if stale
# Run via cron every 5 minutes
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/home/agent/agent-harness}"
HEARTBEAT_FILE="${HARNESS_DIR}/logs/heartbeat.json"
SCRIPTS_DIR="${HARNESS_DIR}/scripts"
MAX_STALE_SECONDS=600  # 10 minutes

if [[ ! -f "$HEARTBEAT_FILE" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT: Heartbeat file missing!"
    "$SCRIPTS_DIR/notify.sh" "stale_heartbeat" "system" "Heartbeat file not found" || true
    exit 1
fi

FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null || echo 0) ))

if [[ $FILE_AGE -gt $MAX_STALE_SECONDS ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ALERT: Heartbeat stale! Age: ${FILE_AGE}s (max: ${MAX_STALE_SECONDS}s)"
    "$SCRIPTS_DIR/notify.sh" "stale_heartbeat" "system" "Heartbeat stale for ${FILE_AGE}s" || true

    # Attempt to restart the container
    if command -v docker &>/dev/null; then
        echo "Attempting container restart..."
        docker restart coding-agent 2>/dev/null || true
    fi
    exit 1
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] OK: Heartbeat fresh (${FILE_AGE}s old)"

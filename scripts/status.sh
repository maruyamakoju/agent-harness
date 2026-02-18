#!/usr/bin/env bash
# status.sh - Quick container status: heartbeat, jobs, quota
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
HEARTBEAT_FILE="${HARNESS_DIR}/logs/heartbeat.json"
JOBS_DIR="${HARNESS_DIR}/jobs"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Heartbeat Status
echo "=== Agent Status ==="
if [[ -f "$HEARTBEAT_FILE" ]]; then
    status=$(jq -r '.status // "unknown"' "$HEARTBEAT_FILE" 2>/dev/null)
    timestamp=$(jq -r '.timestamp // "unknown"' "$HEARTBEAT_FILE" 2>/dev/null)
    consec_fail=$(jq -r '.consecutive_failures // 0' "$HEARTBEAT_FILE" 2>/dev/null)
    [[ "$status" == "alive" ]] && color="$GREEN" || color="$RED"
    echo -e "Status: ${color}${status}${NC} (last: ${timestamp})"
    echo "Consecutive failures: ${consec_fail}"
else
    echo -e "Status: ${RED}NO HEARTBEAT${NC}"
fi

# Job Queue
echo -e "\n=== Job Queue ==="
pending=$(find "$JOBS_DIR/pending" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
running=$(find "$JOBS_DIR/running" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
done=$(find "$JOBS_DIR/done" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
failed=$(find "$JOBS_DIR/failed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
echo -e "Pending: ${YELLOW}${pending}${NC} | Running: ${YELLOW}${running}${NC} | Done: ${GREEN}${done}${NC} | Failed: ${RED}${failed}${NC}"

# Quota
echo -e "\n=== Quota ==="
if [[ -f "$HEARTBEAT_FILE" ]]; then
    jobs_today=$(jq -r '.quota.jobs_today // 0' "$HEARTBEAT_FILE" 2>/dev/null)
    max_per_day=$(jq -r '.quota.max_per_day // 0' "$HEARTBEAT_FILE" 2>/dev/null)
    remaining=$((max_per_day - jobs_today))
    echo -e "Today: ${jobs_today} / ${max_per_day} | Remaining: ${remaining}"
else
    echo "Quota: N/A"
fi

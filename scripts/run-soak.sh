#!/usr/bin/env bash
# =============================================================================
# run-soak.sh — Sequential overnight soak runner
# Runs two product experiments back-to-back; logs to logs/soak-<ts>.log
# Usage: bash scripts/run-soak.sh [job1.json] [job2.json]
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
WORKSPACES_DIR="${WORKSPACES_DIR:-$HARNESS_DIR/workspaces}"
TS=$(date -u +%Y%m%d-%H%M%S)
SOAK_LOG="$HARNESS_DIR/logs/soak-${TS}.log"

JOB1="${1:-}"
JOB2="${2:-}"

if [[ -z "$JOB1" ]]; then
    echo "Usage: bash scripts/run-soak.sh <job1.json> [job2.json]"
    exit 1
fi

mkdir -p "$HARNESS_DIR/logs"

log() { echo "[soak $(date -u +%H:%M:%SZ)] $*" | tee -a "$SOAK_LOG"; }

run_job() {
    local job_file="$1"
    local job_id
    job_id=$(basename "$job_file" .json)
    local job_log="$HARNESS_DIR/logs/${job_id}.log"

    log "START: $job_id"
    log "  log → $job_log"

    local start
    start=$(date +%s)

    HARNESS_DIR="$HARNESS_DIR" \
    WORKSPACES_DIR="$WORKSPACES_DIR" \
    bash "$HARNESS_DIR/scripts/run-job.sh" "$job_file" > "$job_log" 2>&1
    local exit_code=$?

    local duration=$(( $(date +%s) - start ))

    if [[ $exit_code -eq 0 ]]; then
        local stop_reason
        stop_reason=$(grep -E "Target score reached|plateau_stop|Consecutive discard limit|max_loops" \
            "$job_log" 2>/dev/null | tail -1 | sed 's/.*\[INFO\] \[LOOP_CHECK\] //' || echo "unknown")
        log "DONE: $job_id  exit=0  duration=${duration}s  stop='$stop_reason'"
    else
        log "FAIL: $job_id  exit=$exit_code  duration=${duration}s"
    fi

    return $exit_code
}

log "=== Soak run started ==="
log "  HARNESS_DIR=$HARNESS_DIR"
log "  WORKSPACES_DIR=$WORKSPACES_DIR"
[[ -n "$JOB1" ]] && log "  JOB1=$JOB1"
[[ -n "$JOB2" ]] && log "  JOB2=$JOB2"
log ""

run_job "$JOB1" || log "WARN: JOB1 failed, continuing to JOB2 if set"

if [[ -n "$JOB2" ]]; then
    log ""
    run_job "$JOB2" || log "WARN: JOB2 failed"
fi

log ""
log "=== Soak run complete. Summary log: $SOAK_LOG ==="

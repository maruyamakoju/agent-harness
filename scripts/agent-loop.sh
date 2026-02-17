#!/usr/bin/env bash
# =============================================================================
# agent-loop.sh - 24/7 Main Loop
# Polls jobs/pending/ every 30s, dispatches to run-job.sh
# Implements circuit breaker, heartbeat, and graceful shutdown
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
JOBS_DIR="${HARNESS_DIR}/jobs"
LOGS_DIR="${HARNESS_DIR}/logs"
SCRIPTS_DIR="${HARNESS_DIR}/scripts"
LOOP_LOG="${LOGS_DIR}/agent-loop.jsonl"
HEARTBEAT_FILE="${LOGS_DIR}/heartbeat.json"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

# Circuit breaker state
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=3
CIRCUIT_BREAKER_PAUSE=600  # 10 minutes

# Graceful shutdown
RUNNING=true
CURRENT_JOB_PID=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_event() {
    local level="$1"
    local event="$2"
    shift 2
    local extra="${*:-}"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local entry
    entry=$(jq -cn \
        --arg ts "$timestamp" \
        --arg lvl "$level" \
        --arg evt "$event" \
        --arg ext "$extra" \
        '{timestamp: $ts, level: $lvl, event: $evt, detail: $ext}')
    echo "$entry" >> "$LOOP_LOG"
    echo "[$timestamp] [$level] $event $extra"
}

# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------
update_heartbeat() {
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local pending running done failed
    pending=$(find "$JOBS_DIR/pending" -name "*.json" 2>/dev/null | wc -l)
    running=$(find "$JOBS_DIR/running" -name "*.json" 2>/dev/null | wc -l)
    done=$(find "$JOBS_DIR/done" -name "*.json" 2>/dev/null | wc -l)
    failed=$(find "$JOBS_DIR/failed" -name "*.json" 2>/dev/null | wc -l)
    jq -n \
        --arg ts "$timestamp" \
        --argjson pend "$pending" \
        --argjson run "$running" \
        --argjson dn "$done" \
        --argjson fail "$failed" \
        --argjson consec_fail "$CONSECUTIVE_FAILURES" \
        '{
            timestamp: $ts,
            status: "alive",
            queue: {pending: $pend, running: $run, done: $dn, failed: $fail},
            consecutive_failures: $consec_fail
        }' > "$HEARTBEAT_FILE"
}

# ---------------------------------------------------------------------------
# Signal handlers for graceful shutdown
# ---------------------------------------------------------------------------
shutdown_handler() {
    log_event "WARN" "SHUTDOWN" "Received shutdown signal"
    RUNNING=false
    if [[ -n "$CURRENT_JOB_PID" ]] && kill -0 "$CURRENT_JOB_PID" 2>/dev/null; then
        log_event "WARN" "SHUTDOWN" "Waiting for current job (PID $CURRENT_JOB_PID) to finish..."
        wait "$CURRENT_JOB_PID" 2>/dev/null || true
    fi
    log_event "INFO" "SHUTDOWN" "Agent loop stopped gracefully"
    exit 0
}

trap shutdown_handler SIGTERM SIGINT SIGHUP

# ---------------------------------------------------------------------------
# Pick oldest pending job
# ---------------------------------------------------------------------------
pick_next_job() {
    # Sort by filename (timestamp-based) → oldest first
    local job_file
    job_file=$(find "$JOBS_DIR/pending" -name "*.json" -type f 2>/dev/null \
        | sort \
        | head -n 1)
    echo "$job_file"
}

# ---------------------------------------------------------------------------
# Dispatch a single job
# ---------------------------------------------------------------------------
dispatch_job() {
    local job_file="$1"
    local job_id
    job_id=$(jq -r '.id // "unknown"' "$job_file")
    local job_basename
    job_basename=$(basename "$job_file")

    log_event "INFO" "JOB_START" "id=$job_id file=$job_basename"
    "$SCRIPTS_DIR/notify.sh" "job_start" "$job_id" "repo=$(jq -r '.repo // ""' "$job_file")" &

    # Move to running/
    mv "$job_file" "$JOBS_DIR/running/$job_basename"
    local running_file="$JOBS_DIR/running/$job_basename"

    # Check max_retries from job spec
    local max_retries
    max_retries=$(jq -r '.max_retries // 2' "$running_file")
    local attempt=0
    local exit_code=1

    while [[ $attempt -le $max_retries ]]; do
        if [[ $attempt -gt 0 ]]; then
            log_event "WARN" "JOB_RETRY" "id=$job_id attempt=$((attempt+1))/$((max_retries+1))"
        fi

        # Execute run-job.sh in background so we can handle signals
        "$SCRIPTS_DIR/run-job.sh" "$running_file" &
        CURRENT_JOB_PID=$!

        # Wait for job to complete
        exit_code=0
        wait "$CURRENT_JOB_PID" || exit_code=$?
        CURRENT_JOB_PID=""

        if [[ $exit_code -eq 0 ]]; then
            break
        fi

        attempt=$((attempt + 1))

        # Don't retry if we've exhausted attempts
        if [[ $attempt -gt $max_retries ]]; then
            break
        fi

        # Brief pause between retries
        log_event "INFO" "JOB_RETRY_WAIT" "id=$job_id waiting 30s before retry"
        sleep 30
    done

    if [[ $exit_code -eq 0 ]]; then
        # Success → move to done/
        mv "$running_file" "$JOBS_DIR/done/$job_basename" 2>/dev/null || true
        log_event "INFO" "JOB_DONE" "id=$job_id exit_code=$exit_code attempts=$((attempt+1))"
        "$SCRIPTS_DIR/notify.sh" "job_done" "$job_id" "attempts=$((attempt+1))" &
        CONSECUTIVE_FAILURES=0
    else
        # Failure → move to failed/
        mv "$running_file" "$JOBS_DIR/failed/$job_basename" 2>/dev/null || true
        log_event "ERROR" "JOB_FAILED" "id=$job_id exit_code=$exit_code attempts=$((attempt))"
        "$SCRIPTS_DIR/notify.sh" "job_failed" "$job_id" "exit_code=$exit_code attempts=$((attempt))" &
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    fi

    return $exit_code
}

# ---------------------------------------------------------------------------
# Circuit breaker check
# ---------------------------------------------------------------------------
check_circuit_breaker() {
    if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        log_event "WARN" "CIRCUIT_BREAKER" \
            "Triggered: $CONSECUTIVE_FAILURES consecutive failures. Pausing ${CIRCUIT_BREAKER_PAUSE}s"
        "$SCRIPTS_DIR/notify.sh" "circuit_breaker" "system" \
            "$CONSECUTIVE_FAILURES consecutive failures, pausing ${CIRCUIT_BREAKER_PAUSE}s" &
        local elapsed=0
        while [[ $elapsed -lt $CIRCUIT_BREAKER_PAUSE ]] && [[ "$RUNNING" == "true" ]]; do
            sleep 10
            elapsed=$((elapsed + 10))
            update_heartbeat
        done
        CONSECUTIVE_FAILURES=0
        log_event "INFO" "CIRCUIT_BREAKER" "Resumed after pause"
    fi
}

# =============================================================================
# Main Loop
# =============================================================================
main() {
    log_event "INFO" "STARTUP" "Agent loop started. POLL_INTERVAL=${POLL_INTERVAL}s"
    update_heartbeat

    local heartbeat_counter=0

    while [[ "$RUNNING" == "true" ]]; do
        # Update heartbeat every ~60s (every 2 poll cycles at 30s interval)
        heartbeat_counter=$((heartbeat_counter + 1))
        if [[ $((heartbeat_counter % 2)) -eq 0 ]]; then
            update_heartbeat
        fi

        # Check circuit breaker
        check_circuit_breaker

        # Look for pending jobs
        local next_job
        next_job=$(pick_next_job)

        if [[ -n "$next_job" ]]; then
            dispatch_job "$next_job" || true
        else
            # No jobs available → sleep
            sleep "$POLL_INTERVAL" &
            wait $! 2>/dev/null || true
        fi
    done
}

main "$@"

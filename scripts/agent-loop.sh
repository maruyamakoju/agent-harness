#!/usr/bin/env bash
# =============================================================================
# agent-loop.sh - 24/7 Main Loop
# Polls jobs/pending/ every 30s, dispatches to run-job.sh
# Implements circuit breaker, heartbeat, quota management, graceful shutdown
#
# Auth: Claude Max Plan ($200/mo) - quota-aware scheduling
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

# Quota management (Max plan)
MAX_JOBS_PER_DAY="${MAX_JOBS_PER_DAY:-20}"
JOB_COOLDOWN="${JOB_COOLDOWN:-60}"  # seconds between jobs
DAILY_JOB_COUNT=0
DAILY_RESET_DATE=""
QUOTA_COUNTER_FILE="${LOGS_DIR}/quota-counter.json"

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
        --argjson daily_jobs "$DAILY_JOB_COUNT" \
        --argjson daily_max "$MAX_JOBS_PER_DAY" \
        '{
            timestamp: $ts,
            status: "alive",
            auth: "max-plan",
            queue: {pending: $pend, running: $run, done: $dn, failed: $fail},
            consecutive_failures: $consec_fail,
            quota: {jobs_today: $daily_jobs, max_per_day: $daily_max}
        }' > "$HEARTBEAT_FILE"
}

# ---------------------------------------------------------------------------
# Quota management
# ---------------------------------------------------------------------------
load_quota_counter() {
    if [[ -f "$QUOTA_COUNTER_FILE" ]]; then
        local saved_date
        saved_date=$(jq -r '.date // ""' "$QUOTA_COUNTER_FILE" 2>/dev/null)
        local today
        today=$(date +%Y-%m-%d)
        if [[ "$saved_date" == "$today" ]]; then
            DAILY_JOB_COUNT=$(jq -r '.count // 0' "$QUOTA_COUNTER_FILE" 2>/dev/null)
            DAILY_RESET_DATE="$today"
        else
            # New day, reset counter
            DAILY_JOB_COUNT=0
            DAILY_RESET_DATE="$today"
            save_quota_counter
        fi
    else
        DAILY_JOB_COUNT=0
        DAILY_RESET_DATE=$(date +%Y-%m-%d)
        save_quota_counter
    fi
}

save_quota_counter() {
    jq -n \
        --arg date "$DAILY_RESET_DATE" \
        --argjson count "$DAILY_JOB_COUNT" \
        '{date: $date, count: $count}' > "$QUOTA_COUNTER_FILE"
}

check_daily_quota() {
    # Reset counter if new day
    local today
    today=$(date +%Y-%m-%d)
    if [[ "$today" != "$DAILY_RESET_DATE" ]]; then
        DAILY_JOB_COUNT=0
        DAILY_RESET_DATE="$today"
        save_quota_counter
        log_event "INFO" "QUOTA_RESET" "New day: daily job counter reset"
    fi

    # Check limit (0 = unlimited)
    if [[ $MAX_JOBS_PER_DAY -gt 0 ]] && [[ $DAILY_JOB_COUNT -ge $MAX_JOBS_PER_DAY ]]; then
        return 1  # quota exceeded
    fi
    return 0
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
    save_quota_counter
    log_event "INFO" "SHUTDOWN" "Agent loop stopped gracefully"
    exit 0
}

trap shutdown_handler SIGTERM SIGINT SIGHUP

# ---------------------------------------------------------------------------
# Pick oldest pending job
# ---------------------------------------------------------------------------
pick_next_job() {
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

    log_event "INFO" "JOB_START" "id=$job_id file=$job_basename daily_count=$((DAILY_JOB_COUNT+1))/$MAX_JOBS_PER_DAY"
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

        "$SCRIPTS_DIR/run-job.sh" "$running_file" &
        CURRENT_JOB_PID=$!

        exit_code=0
        wait "$CURRENT_JOB_PID" || exit_code=$?
        CURRENT_JOB_PID=""

        if [[ $exit_code -eq 0 ]]; then
            break
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -gt $max_retries ]]; then
            break
        fi

        log_event "INFO" "JOB_RETRY_WAIT" "id=$job_id waiting 30s before retry"
        sleep 30
    done

    # Update daily counter
    DAILY_JOB_COUNT=$((DAILY_JOB_COUNT + 1))
    save_quota_counter

    if [[ $exit_code -eq 0 ]]; then
        mv "$running_file" "$JOBS_DIR/done/$job_basename" 2>/dev/null || true
        log_event "INFO" "JOB_DONE" "id=$job_id attempts=$((attempt+1)) daily_total=$DAILY_JOB_COUNT"
        "$SCRIPTS_DIR/notify.sh" "job_done" "$job_id" "attempts=$((attempt+1))" &
        CONSECUTIVE_FAILURES=0
    else
        mv "$running_file" "$JOBS_DIR/failed/$job_basename" 2>/dev/null || true
        log_event "ERROR" "JOB_FAILED" "id=$job_id exit_code=$exit_code attempts=$((attempt)) daily_total=$DAILY_JOB_COUNT"
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
verify_claude_auth() {
    log_event "INFO" "AUTH_CHECK" "Verifying Claude Code authentication..."
    if claude --version &>/dev/null; then
        local version
        version=$(claude --version 2>/dev/null || echo "unknown")
        log_event "INFO" "AUTH_CHECK" "Claude Code CLI version: $version"
    else
        log_event "ERROR" "AUTH_CHECK" "Claude Code CLI not found!"
        return 1
    fi

    # Quick auth test with minimal prompt
    if timeout 30 claude -p --output-format json "Say OK" &>/dev/null; then
        log_event "INFO" "AUTH_CHECK" "Authentication verified (Max plan active)"
    else
        log_event "ERROR" "AUTH_CHECK" "Authentication FAILED. Run: claude login"
        "$SCRIPTS_DIR/notify.sh" "auth_failed" "system" \
            "Claude Code auth failed. Run 'docker exec -it coding-agent claude login'" &
        return 1
    fi
    return 0
}

log_system_info() {
    local disk_free
    disk_free=$(df -h /workspaces 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")
    local mem_free
    mem_free=$(free -h 2>/dev/null | awk '/^Mem:/{print $7}' || echo "unknown")
    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader 2>/dev/null || echo "no GPU")
    log_event "INFO" "SYSTEM_INFO" "disk_free=$disk_free mem_avail=$mem_free gpu=$gpu_info"
}

main() {
    log_event "INFO" "STARTUP" "Agent loop started. POLL=${POLL_INTERVAL}s MAX_JOBS/DAY=${MAX_JOBS_PER_DAY} COOLDOWN=${JOB_COOLDOWN}s AUTH=max-plan MODEL=${DEFAULT_MODEL:-claude-sonnet-4-5-20250929}"

    # Verify Claude Code authentication before starting
    local auth_retries=0
    while ! verify_claude_auth; do
        auth_retries=$((auth_retries + 1))
        if [[ $auth_retries -ge 3 ]]; then
            log_event "ERROR" "STARTUP" "Claude auth failed after $auth_retries attempts. Exiting."
            exit 1
        fi
        log_event "WARN" "STARTUP" "Auth failed. Waiting 60s before retry ($auth_retries/3)..."
        sleep 60
    done

    # Log system info at startup
    log_system_info

    # Load quota counter from disk
    load_quota_counter
    log_event "INFO" "QUOTA_LOADED" "Jobs today: $DAILY_JOB_COUNT / $MAX_JOBS_PER_DAY"

    update_heartbeat

    local heartbeat_counter=0

    while [[ "$RUNNING" == "true" ]]; do
        # Update heartbeat every ~60s, system info every ~5min
        heartbeat_counter=$((heartbeat_counter + 1))
        if [[ $((heartbeat_counter % 2)) -eq 0 ]]; then
            update_heartbeat
        fi
        if [[ $((heartbeat_counter % 10)) -eq 0 ]]; then
            log_system_info
        fi

        # Check circuit breaker
        check_circuit_breaker

        # Check daily quota
        if ! check_daily_quota; then
            # Quota exceeded - wait until midnight
            local now_epoch
            now_epoch=$(date +%s)
            local midnight_epoch
            midnight_epoch=$(date -d "tomorrow 00:00:00" +%s 2>/dev/null || date -d "+1 day" +%s 2>/dev/null || echo $((now_epoch + 3600)))
            local wait_secs=$((midnight_epoch - now_epoch))

            if [[ $wait_secs -gt 0 && $wait_secs -lt 86400 ]]; then
                log_event "WARN" "QUOTA_EXCEEDED" "Daily limit $MAX_JOBS_PER_DAY reached. Waiting ${wait_secs}s until midnight reset."
                "$SCRIPTS_DIR/notify.sh" "quota_exceeded" "system" \
                    "Daily limit $MAX_JOBS_PER_DAY reached ($DAILY_JOB_COUNT jobs). Waiting for midnight reset." &

                # Sleep in chunks so we can still respond to signals and update heartbeat
                local slept=0
                while [[ $slept -lt $wait_secs ]] && [[ "$RUNNING" == "true" ]]; do
                    sleep 60 &
                    wait $! 2>/dev/null || true
                    slept=$((slept + 60))
                    update_heartbeat
                done
            fi
            continue
        fi

        # Look for pending jobs
        local next_job
        next_job=$(pick_next_job)

        if [[ -n "$next_job" ]]; then
            dispatch_job "$next_job" || true

            # Cooldown between jobs (saves Max plan quota)
            if [[ $JOB_COOLDOWN -gt 0 ]] && [[ "$RUNNING" == "true" ]]; then
                log_event "INFO" "COOLDOWN" "Waiting ${JOB_COOLDOWN}s before next job (quota preservation)"
                sleep "$JOB_COOLDOWN" &
                wait $! 2>/dev/null || true
            fi
        else
            sleep "$POLL_INTERVAL" &
            wait $! 2>/dev/null || true
        fi
    done
}

main "$@"

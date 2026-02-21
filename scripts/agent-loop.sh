#!/usr/bin/env bash
# =============================================================================
# agent-loop.sh - 24/7 Main Loop
# Polls jobs/pending/ every 30s, dispatches to run-job.sh
# Implements parallel execution, circuit breaker, heartbeat, quota management,
# graceful shutdown, and auto-queue.
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

# Adaptive polling: back off when idle, sprint when active
IDLE_BACKOFF_MAX=300   # cap at 5 minutes when fully idle
_idle_backoff=0         # current idle sleep seconds (0 = use POLL_INTERVAL)

# Circuit breaker state
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=3
CIRCUIT_BREAKER_PAUSE=600  # 10 minutes

# Quota management (Max plan)
MAX_JOBS_PER_DAY="${MAX_JOBS_PER_DAY:-20}"
DAILY_JOB_COUNT=0
DAILY_RESET_DATE=""
QUOTA_COUNTER_FILE="${LOGS_DIR}/quota-counter.json"

# Parallel job tracking
MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-2}"
declare -A RUNNING_PIDS    # pid → job_id
declare -A RUNNING_FILES   # pid → job_basename

# Graceful shutdown
RUNNING=true

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
    local par_running=${#RUNNING_PIDS[@]}
    jq -n \
        --arg ts "$timestamp" \
        --argjson pend "$pending" \
        --argjson run "$running" \
        --argjson dn "$done" \
        --argjson fail "$failed" \
        --argjson consec_fail "$CONSECUTIVE_FAILURES" \
        --argjson daily_jobs "$DAILY_JOB_COUNT" \
        --argjson daily_max "$MAX_JOBS_PER_DAY" \
        --argjson par_running "$par_running" \
        --argjson par_max "$MAX_PARALLEL_JOBS" \
        '{
            timestamp: $ts,
            status: "alive",
            auth: "max-plan",
            queue: {pending: $pend, running: $run, done: $dn, failed: $fail},
            consecutive_failures: $consec_fail,
            quota: {jobs_today: $daily_jobs, max_per_day: $daily_max},
            parallel: {running: $par_running, max: $par_max}
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
        if [[ -x "$SCRIPTS_DIR/cleanup.sh" ]]; then
            "$SCRIPTS_DIR/cleanup.sh" >> "$LOGS_DIR/cleanup.log" 2>&1 &
            log_event "INFO" "CLEANUP" "Daily cleanup started (background)"
        fi
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
    for pid in "${!RUNNING_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            log_event "WARN" "SHUTDOWN" "Waiting for job (PID $pid id=${RUNNING_PIDS[$pid]}) to finish..."
            kill -TERM "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    save_quota_counter
    log_event "INFO" "SHUTDOWN" "Agent loop stopped gracefully"
    exit 0
}

trap shutdown_handler SIGTERM SIGINT SIGHUP

# ---------------------------------------------------------------------------
# Check GPU availability
# ---------------------------------------------------------------------------
check_gpu_available() {
    nvidia-smi &>/dev/null && echo "true" || echo "false"
}

# ---------------------------------------------------------------------------
# Pick oldest eligible pending job and atomically claim it (flock)
# Returns path in running/ or empty string if none available
# Skips GPU-required jobs when GPU unavailable.
# Skips expired jobs (expires_at field) and moves them to failed/.
# ---------------------------------------------------------------------------
pick_and_claim_job() {
    local gpu_ok="${1:-true}"
    (
        flock -x -w 5 200 || { echo ""; return; }
        # Sort pending jobs: priority ASC (1=highest), then filename ASC (FIFO within priority)
        local sorted_jobs
        sorted_jobs=$(
            for f in "$JOBS_DIR/pending/"*.json; do
                [[ -f "$f" ]] || continue
                prio=$(jq -r '.priority // 3' "$f" 2>/dev/null || echo "3")
                printf '%02d\t%s\n' "$prio" "$f"
            done | sort -k1,1n -k2,2 | cut -f2
        )
        local now_epoch
        now_epoch=$(date +%s)
        local job_file
        while IFS= read -r job_file; do
            [[ -z "$job_file" ]] && continue

            # Check job expiry: if expires_at is set and in the past, fail the job
            local expires_at
            expires_at=$(jq -r '.expires_at // empty' "$job_file" 2>/dev/null)
            if [[ -n "$expires_at" ]]; then
                local exp_epoch
                exp_epoch=$(date -d "$expires_at" +%s 2>/dev/null || echo 0)
                if [[ $exp_epoch -gt 0 && $now_epoch -gt $exp_epoch ]]; then
                    local exp_id; exp_id=$(jq -r '.id // "unknown"' "$job_file" 2>/dev/null)
                    local exp_bn; exp_bn=$(basename "$job_file")
                    # Mark expired before moving
                    jq '. + {"failed_reason": "expired", "failed_at": (now | todate)}' \
                        "$job_file" 2>/dev/null > "${job_file}.tmp" && mv "${job_file}.tmp" "$job_file" || true
                    mv "$job_file" "$JOBS_DIR/failed/$exp_bn" 2>/dev/null || true
                    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [WARN] JOB_EXPIRED id=$exp_id" >&2
                    continue
                fi
            fi

            # Skip GPU-required jobs when GPU is unavailable
            if [[ "$gpu_ok" == "false" ]]; then
                local gpu_req
                gpu_req=$(jq -r '.gpu_required // false' "$job_file" 2>/dev/null || echo "false")
                [[ "$gpu_req" == "true" ]] && continue
            fi

            local bn; bn=$(basename "$job_file")
            if mv "$job_file" "$JOBS_DIR/running/$bn" 2>/dev/null; then
                echo "$JOBS_DIR/running/$bn"
                return
            fi
        done <<< "$sorted_jobs"
    ) 200>"$JOBS_DIR/.pick.lock"
}

# ---------------------------------------------------------------------------
# Dispatch a job asynchronously with retry logic
# job_file must already be in running/ (moved by pick_and_claim_job)
# ---------------------------------------------------------------------------
dispatch_job_async() {
    local job_file="$1"  # Already in running/
    local job_id job_basename max_retries
    job_id=$(jq -r '.id // "unknown"' "$job_file")
    job_basename=$(basename "$job_file")
    max_retries=$(jq -r '.max_retries // 2' "$job_file")

    log_event "INFO" "JOB_DISPATCHED" "id=$job_id daily_count=$((DAILY_JOB_COUNT+1))/$MAX_JOBS_PER_DAY parallel=$((${#RUNNING_PIDS[@]}+1))/$MAX_PARALLEL_JOBS"
    "$SCRIPTS_DIR/notify.sh" "job_start" "$job_id" "repo=$(jq -r '.repo // ""' "$job_file")" &

    # job_file is already in running/ (moved atomically by pick_and_claim_job)

    # Increment daily counter
    DAILY_JOB_COUNT=$((DAILY_JOB_COUNT + 1))
    save_quota_counter

    # Retry wrapper with exponential backoff - run asynchronously
    # Backoff schedule: 60s, 120s, 240s, 480s, ... capped at 900s (15 min)
    (
        local attempt=0
        while [[ $attempt -le $max_retries ]]; do
            if [[ $attempt -gt 0 ]]; then
                local sleep_secs=$(( 60 * (1 << (attempt - 1)) ))
                [[ $sleep_secs -gt 900 ]] && sleep_secs=900
                log_event "WARN" "JOB_RETRY" "id=$job_id attempt=$((attempt+1))/$((max_retries+1)) backoff=${sleep_secs}s"
                sleep "$sleep_secs"
            fi
            if "$SCRIPTS_DIR/run-job.sh" "$job_file"; then exit 0; fi
            attempt=$((attempt + 1))
        done
        exit 1
    ) &

    local pid=$!
    RUNNING_PIDS[$pid]="$job_id"
    RUNNING_FILES[$pid]="$job_basename"
    log_event "INFO" "JOB_STARTED" "id=$job_id pid=$pid max_retries=$max_retries parallel=${#RUNNING_PIDS[@]}/$MAX_PARALLEL_JOBS"
}

# ---------------------------------------------------------------------------
# Reap completed jobs (non-blocking check)
# ---------------------------------------------------------------------------
reap_completed_jobs() {
    local pids_to_remove=()
    for pid in "${!RUNNING_PIDS[@]}"; do
        # Still running → skip
        kill -0 "$pid" 2>/dev/null && continue

        local exit_code=0
        wait "$pid" 2>/dev/null || exit_code=$?
        local job_id="${RUNNING_PIDS[$pid]}"
        local job_basename="${RUNNING_FILES[$pid]}"

        if [[ $exit_code -eq 0 ]]; then
            mv "$JOBS_DIR/running/$job_basename" "$JOBS_DIR/done/$job_basename" 2>/dev/null || true
            CONSECUTIVE_FAILURES=0
            log_event "INFO" "JOB_DONE" "id=$job_id"
            "$SCRIPTS_DIR/notify.sh" "job_done" "$job_id" "" &
        else
            mv "$JOBS_DIR/running/$job_basename" "$JOBS_DIR/failed/$job_basename" 2>/dev/null || true
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            log_event "ERROR" "JOB_FAILED" "id=$job_id exit_code=$exit_code"
            "$SCRIPTS_DIR/notify.sh" "job_failed" "$job_id" "exit_code=$exit_code" &
        fi
        pids_to_remove+=("$pid")
    done
    for pid in "${pids_to_remove[@]:-}"; do
        [[ -n "$pid" ]] || continue
        unset "RUNNING_PIDS[$pid]"
        unset "RUNNING_FILES[$pid]"
    done
}

# ---------------------------------------------------------------------------
# Reap zombie jobs: running/*.json not tracked by any known PID that have
# exceeded their time_budget + 1800s grace period.
# This recovers from agent restarts leaving stale running files.
# ---------------------------------------------------------------------------
reap_zombie_jobs() {
    local now
    now=$(date +%s)
    for job_file in "$JOBS_DIR/running/"*.json; do
        [[ -f "$job_file" ]] || continue
        local bn; bn=$(basename "$job_file")

        # Check if this file is tracked by any known PID
        local tracked=false
        local pid
        for pid in "${!RUNNING_FILES[@]}"; do
            if [[ "${RUNNING_FILES[$pid]}" == "$bn" ]]; then
                tracked=true
                break
            fi
        done
        [[ "$tracked" == "true" ]] && continue

        # Untracked: check age against time_budget + grace period
        local time_budget
        time_budget=$(jq -r '.time_budget_sec // 3600' "$job_file" 2>/dev/null || echo 3600)
        local grace=1800  # 30-minute grace after budget expires
        local file_mtime
        file_mtime=$(stat -c %Y "$job_file" 2>/dev/null || stat -f %m "$job_file" 2>/dev/null || echo 0)
        local age=$(( now - file_mtime ))

        if [[ $age -gt $(( time_budget + grace )) ]]; then
            local job_id; job_id=$(jq -r '.id // "unknown"' "$job_file" 2>/dev/null)
            jq '. + {"failed_reason": "zombie_reaped", "failed_at": (now | todate)}' \
                "$job_file" 2>/dev/null > "${job_file}.tmp" && mv "${job_file}.tmp" "$job_file" || true
            mv "$job_file" "$JOBS_DIR/failed/$bn" 2>/dev/null || true
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            log_event "ERROR" "ZOMBIE_DETECTED" "id=$job_id age=${age}s budget=${time_budget}s grace=${grace}s"
            "$SCRIPTS_DIR/notify.sh" "job_failed" "$job_id" "zombie_reaped age=${age}s" &
        fi
    done
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
            reap_completed_jobs
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
    log_event "INFO" "STARTUP" "Agent loop started. POLL=${POLL_INTERVAL}s MAX_JOBS/DAY=${MAX_JOBS_PER_DAY} MAX_PARALLEL=${MAX_PARALLEL_JOBS} AUTH=max-plan MODEL=${DEFAULT_MODEL:-claude-sonnet-4-6}"

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

    # Configure git HTTPS auth with GITHUB_TOKEN
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        git config --global --replace-all url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
        git config --global --add url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
        echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true
        log_event "INFO" "GIT_AUTH" "GitHub HTTPS auth configured"
    fi

    # Log system info at startup
    log_system_info

    # Load quota counter from disk
    load_quota_counter
    log_event "INFO" "QUOTA_LOADED" "Jobs today: $DAILY_JOB_COUNT / $MAX_JOBS_PER_DAY"

    update_heartbeat

    local heartbeat_counter=0

    while [[ "$RUNNING" == "true" ]]; do
        # Reap any completed jobs first
        reap_completed_jobs

        # Reap zombie jobs (untracked running/*.json that have outlived their budget)
        reap_zombie_jobs

        # Update heartbeat every ~60s, system info every ~5min
        heartbeat_counter=$((heartbeat_counter + 1))
        if [[ $((heartbeat_counter % 2)) -eq 0 ]]; then
            update_heartbeat
        fi
        if [[ $((heartbeat_counter % 10)) -eq 0 ]]; then
            log_system_info

            # Poll GitHub Issues for new agent tasks (every ~5min)
            if [[ -n "${AGENT_WATCH_REPOS:-}" ]]; then
                log_event "INFO" "ISSUE_POLL" "Checking GitHub Issues for agent tasks..."
                "$SCRIPTS_DIR/github-issue-handler.sh" $AGENT_WATCH_REPOS 2>&1 | \
                    while IFS= read -r line; do log_event "INFO" "ISSUE_POLL" "$line"; done || true
            fi
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

                local slept=0
                while [[ $slept -lt $wait_secs ]] && [[ "$RUNNING" == "true" ]]; do
                    sleep 60 &
                    wait $! 2>/dev/null || true
                    slept=$((slept + 60))
                    update_heartbeat
                    reap_completed_jobs
                done
            fi
            continue
        fi

        # Dispatch jobs up to parallel slot limit
        local gpu_ok
        gpu_ok=$(check_gpu_available)
        local slots=$(( MAX_PARALLEL_JOBS - ${#RUNNING_PIDS[@]} ))
        local _dispatched_this_iter=0
        while [[ $slots -gt 0 ]]; do
            local next_job
            next_job=$(pick_and_claim_job "$gpu_ok")
            [[ -z "$next_job" ]] && break
            dispatch_job_async "$next_job"
            _dispatched_this_iter=$(( _dispatched_this_iter + 1 ))
            slots=$(( slots - 1 ))
            check_daily_quota || break
        done

        # Auto-queue check: if pending jobs below threshold, create new ones
        local pending_count
        pending_count=$(find "$JOBS_DIR/pending" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        if [[ -f "${HARNESS_DIR}/config/auto-queue-config.json" ]]; then
            local threshold
            threshold=$(jq -r '.trigger_threshold // 2' "${HARNESS_DIR}/config/auto-queue-config.json" 2>/dev/null || echo 2)
            if [[ "$pending_count" -lt "$threshold" ]]; then
                local created
                created=$("$SCRIPTS_DIR/auto-queue.sh" 2>/dev/null || echo 0)
                if [[ "$created" -gt 0 ]]; then
                    log_event "INFO" "AUTO_QUEUE" "created=$created pending_was=$pending_count threshold=$threshold"
                    "$SCRIPTS_DIR/notify.sh" "auto_queue" "$created" "pending_was=$pending_count" &
                fi
            fi
        fi

        # Adaptive polling:
        #   - Sprint (5s) when jobs are running or were just dispatched.
        #   - Exponential backoff (up to IDLE_BACKOFF_MAX) when fully idle.
        if [[ $_dispatched_this_iter -gt 0 ]] || [[ ${#RUNNING_PIDS[@]} -gt 0 ]]; then
            _idle_backoff=0
            sleep 5 & wait $! 2>/dev/null || true
        else
            if [[ $_idle_backoff -eq 0 ]]; then
                _idle_backoff=$POLL_INTERVAL
            else
                _idle_backoff=$(( _idle_backoff * 2 ))
                [[ $_idle_backoff -gt $IDLE_BACKOFF_MAX ]] && _idle_backoff=$IDLE_BACKOFF_MAX
            fi
            log_event "DEBUG" "IDLE_POLL" "next_check_in=${_idle_backoff}s"
            sleep "$_idle_backoff" & wait $! 2>/dev/null || true
        fi
    done
}

main "$@"

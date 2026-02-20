#!/usr/bin/env bash
# =============================================================================
# telegram-bot.sh - Telegram Bot for Job Submission
# Long-polls the Telegram Bot API for messages and creates jobs
#
# Setup:
#   1. Create a bot via @BotFather on Telegram
#   2. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env
#   3. Run: bash scripts/telegram-bot.sh
#
# Message format:
#   /job <repo-url> <task description>
#   /job git@github.com:org/repo.git Add user authentication
#
#   /status - Show current agent status
#   /jobs   - List pending/running jobs
#   /help   - Show help message
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
SCRIPTS_DIR="${HARNESS_DIR}/scripts"
JOBS_DIR="${HARNESS_DIR}/jobs"
LOGS_DIR="${HARNESS_DIR}/logs"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
ALLOWED_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
OFFSET_FILE="${LOGS_DIR}/telegram-offset.txt"
POLL_TIMEOUT=30

# ---------------------------------------------------------------------------
# Validate config
# ---------------------------------------------------------------------------
if [[ -z "$BOT_TOKEN" ]]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN is not set"
    exit 1
fi

if [[ -z "$ALLOWED_CHAT_ID" ]]; then
    echo "WARNING: TELEGRAM_CHAT_ID not set - accepting messages from ANY chat"
fi

# ---------------------------------------------------------------------------
# Telegram API helpers
# ---------------------------------------------------------------------------
api_call() {
    local method="$1"
    shift
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/${method}" "$@"
}

send_message() {
    local chat_id="$1"
    local text="$2"
    api_call "sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "text=${text}" \
        -d "parse_mode=Markdown" \
        > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Command handlers
# ---------------------------------------------------------------------------
handle_job() {
    local chat_id="$1"
    local args="$2"

    # Parse: first word is repo, rest is task
    local repo task
    repo=$(echo "$args" | awk '{print $1}')
    task=$(echo "$args" | cut -d' ' -f2-)

    if [[ -z "$repo" || -z "$task" ]]; then
        send_message "$chat_id" "Usage: /job <repo-url> <task description>
Example: /job git@github.com:org/repo.git Add login page"
        return
    fi

    # Create job
    local output
    output=$("$SCRIPTS_DIR/create-job.sh" --repo "$repo" --task "$task" 2>&1)
    local job_id
    job_id=$(echo "$output" | grep "Job ID:" | cut -d: -f2 | tr -d ' ')

    if [[ -n "$job_id" ]]; then
        send_message "$chat_id" "Job created!
*ID:* \`${job_id}\`
*Repo:* \`${repo}\`
*Task:* ${task}"
    else
        send_message "$chat_id" "Failed to create job.
\`\`\`
${output}
\`\`\`"
    fi
}

handle_job_with_options() {
    local chat_id="$1"
    local args="$2"

    # Parse key=value pairs
    local repo="" task="" setup="" test_cmd="" budget=""
    while IFS= read -r line; do
        case "$line" in
            repo=*)     repo="${line#repo=}" ;;
            task=*)     task="${line#task=}" ;;
            setup=*)    setup="${line#setup=}" ;;
            test=*)     test_cmd="${line#test=}" ;;
            budget=*)   budget="${line#budget=}" ;;
        esac
    done <<< "$(echo "$args" | tr ',' '\n')"

    if [[ -z "$repo" || -z "$task" ]]; then
        send_message "$chat_id" "Usage: /jobx repo=<url>,task=<desc>[,setup=<cmd>][,test=<cmd>][,budget=<sec>]"
        return
    fi

    local job_args=("--repo" "$repo" "--task" "$task")
    [[ -n "$setup" ]] && job_args+=("--setup" "$setup")
    [[ -n "$test_cmd" ]] && job_args+=("--test" "$test_cmd")
    [[ -n "$budget" ]] && job_args+=("--time-budget" "$budget")

    local output
    output=$("$SCRIPTS_DIR/create-job.sh" "${job_args[@]}" 2>&1)
    local job_id
    job_id=$(echo "$output" | grep "Job ID:" | cut -d: -f2 | tr -d ' ')

    if [[ -n "$job_id" ]]; then
        send_message "$chat_id" "Job created!
*ID:* \`${job_id}\`"
    else
        send_message "$chat_id" "Failed: ${output:0:200}"
    fi
}

handle_status() {
    local chat_id="$1"
    local heartbeat_file="${LOGS_DIR}/heartbeat.json"

    if [[ -f "$heartbeat_file" ]]; then
        local ts status pending running done failed consec
        ts=$(jq -r '.timestamp' "$heartbeat_file")
        status=$(jq -r '.status' "$heartbeat_file")
        pending=$(jq -r '.queue.pending' "$heartbeat_file")
        running=$(jq -r '.queue.running' "$heartbeat_file")
        done=$(jq -r '.queue.done' "$heartbeat_file")
        failed=$(jq -r '.queue.failed' "$heartbeat_file")
        consec=$(jq -r '.consecutive_failures' "$heartbeat_file")

        send_message "$chat_id" "Agent Status: *${status}*
Last heartbeat: ${ts}
Queue: ${pending} pending | ${running} running | ${done} done | ${failed} failed
Consecutive failures: ${consec}"
    else
        send_message "$chat_id" "Agent status: *UNKNOWN* (no heartbeat file)"
    fi
}

handle_jobs() {
    local chat_id="$1"
    local msg="*Jobs:*\n"

    # Running
    local running_count
    running_count=$(find "$JOBS_DIR/running" -name "*.json" 2>/dev/null | wc -l)
    if [[ $running_count -gt 0 ]]; then
        msg+="\n_Running:_\n"
        for f in "$JOBS_DIR/running"/*.json; do
            [[ -f "$f" ]] || continue
            local jid jtask
            jid=$(jq -r '.id' "$f" | head -c 30)
            jtask=$(jq -r '.task' "$f" | head -c 50)
            msg+="  ▶ \`${jid}\` ${jtask}\n"
        done
    fi

    # Pending
    local pending_count
    pending_count=$(find "$JOBS_DIR/pending" -name "*.json" 2>/dev/null | wc -l)
    if [[ $pending_count -gt 0 ]]; then
        msg+="\n_Pending:_\n"
        for f in "$JOBS_DIR/pending"/*.json; do
            [[ -f "$f" ]] || continue
            local jid jtask
            jid=$(jq -r '.id' "$f" | head -c 30)
            jtask=$(jq -r '.task' "$f" | head -c 50)
            msg+="  ◦ \`${jid}\` ${jtask}\n"
        done
    fi

    if [[ $running_count -eq 0 && $pending_count -eq 0 ]]; then
        msg+="No pending or running jobs."
    fi

    send_message "$chat_id" "$(echo -e "$msg")"
}

handle_help() {
    local chat_id="$1"
    send_message "$chat_id" "*Agent Bot Commands:*

/job <repo> <task> - Create a new job
/jobx repo=<url>,task=<desc>,setup=<cmd>,test=<cmd> - Create with options
/status - Show agent status
/jobs - List pending/running jobs
/help - Show this message

Example:
\`/job git@github.com:org/repo.git Add user login page\`"
}

# ---------------------------------------------------------------------------
# Main polling loop
# ---------------------------------------------------------------------------
echo "Telegram bot started. Listening for messages..."

# Load offset
OFFSET=0
if [[ -f "$OFFSET_FILE" ]]; then
    OFFSET=$(cat "$OFFSET_FILE")
fi

while true; do
    # Long poll for updates
    UPDATES=$(api_call "getUpdates" \
        -d "offset=${OFFSET}" \
        -d "timeout=${POLL_TIMEOUT}" \
        -d "allowed_updates=[\"message\"]" \
        2>/dev/null)

    if [[ -z "$UPDATES" ]]; then
        continue
    fi

    # Process each update
    # Use process substitution (not pipe) so OFFSET is updated in the current shell
    while IFS= read -r update; do
        update_id=$(echo "$update" | jq -r '.update_id')
        chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
        text=$(echo "$update" | jq -r '.message.text // empty')

        # Update offset (must happen in current shell, not a subshell)
        OFFSET=$((update_id + 1))
        echo "$OFFSET" > "$OFFSET_FILE"

        # Skip if no chat_id or text
        [[ -z "$chat_id" || -z "$text" ]] && continue

        # Authorization check
        if [[ -n "$ALLOWED_CHAT_ID" && "$chat_id" != "$ALLOWED_CHAT_ID" ]]; then
            send_message "$chat_id" "Unauthorized. Your chat ID: $chat_id"
            continue
        fi

        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Message from $chat_id: $text"

        # Route commands
        case "$text" in
            /job\ *)    handle_job "$chat_id" "${text#/job }" ;;
            /jobx\ *)   handle_job_with_options "$chat_id" "${text#/jobx }" ;;
            /status*)   handle_status "$chat_id" ;;
            /jobs*)     handle_jobs "$chat_id" ;;
            /help*)     handle_help "$chat_id" ;;
            /start*)    handle_help "$chat_id" ;;
            *)          send_message "$chat_id" "Unknown command. Try /help" ;;
        esac
    done < <(echo "$UPDATES" | jq -c '.result[]' 2>/dev/null)
done

#!/usr/bin/env bash
# =============================================================================
# auto-queue.sh - Automatic job queue filler
# Reads config/auto-queue-config.json and creates pending jobs when the queue
# falls below trigger_threshold.
# Outputs "1" if a job was created, "0" otherwise.
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
CONFIG_FILE="${HARNESS_DIR}/config/auto-queue-config.json"
PENDING_DIR="${HARNESS_DIR}/jobs/pending"

# No config file → nothing to do
[[ ! -f "$CONFIG_FILE" ]] && echo "0" && exit 0

ENABLED=$(jq -r '.enabled // false' "$CONFIG_FILE")
[[ "$ENABLED" != "true" ]] && echo "0" && exit 0

# Find first task with enabled=true and queued=false
TASK_INDEX=$(jq '[.tasks | to_entries[] | select(.value.enabled==true and .value.queued==false)] | .[0].key // -1' "$CONFIG_FILE")
[[ "$TASK_INDEX" == "-1" || -z "$TASK_INDEX" ]] && echo "0" && exit 0

TASK_JSON=$(jq --argjson i "$TASK_INDEX" '.tasks[$i]' "$CONFIG_FILE")

TASK_ID=$(echo "$TASK_JSON" | jq -r '.id // "auto"')
TASK_REPO=$(echo "$TASK_JSON" | jq -r '.repo // ""')
TASK_TEXT=$(echo "$TASK_JSON" | jq -r '.task // ""')
TASK_BUDGET=$(echo "$TASK_JSON" | jq -r '.time_budget_sec // 3600')

if [[ -z "$TASK_REPO" || -z "$TASK_TEXT" ]]; then
    echo "0"
    exit 0
fi

# Generate timestamped job ID with slug
TS=$(date -u +%Y-%m-%dT%H%M%SZ)
SLUG=$(echo "$TASK_ID" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40)
JOB_ID="${TS}-${SLUG}"

mkdir -p "$PENDING_DIR"
JOB_FILE="${PENDING_DIR}/${JOB_ID}.json"

jq -n \
    --arg id "$JOB_ID" \
    --arg repo "$TASK_REPO" \
    --arg task "$TASK_TEXT" \
    --argjson budget "$TASK_BUDGET" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
        id: $id,
        repo: $repo,
        base_ref: "main",
        work_branch: ("agent/" + $id),
        task: $task,
        commands: {setup: [], test: []},
        time_budget_sec: $budget,
        max_retries: 2,
        gpu_required: false,
        created_at: $created_at,
        auto_queued: true
    }' > "$JOB_FILE"

# Atomically mark the task as queued in config
TMP=$(mktemp)
jq --argjson i "$TASK_INDEX" '.tasks[$i].queued = true' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE"

echo "1"

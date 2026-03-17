#!/usr/bin/env bash
# =============================================================================
# create-continuation-job.sh — Generate a continuation job from an existing workspace
#
# Usage: bash scripts/create-continuation-job.sh <source-job-id> <new-job-id> [new-features-file]
#
# Arguments:
#   source-job-id    — ID of the completed job to continue from (e.g., standup-003)
#   new-job-id       — ID for the new continuation job (e.g., standup-004)
#   new-features-file — Optional file containing new feature rows (Markdown table rows)
#
# Output: Creates examples/<new-job-id>.json
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure jq is available
if ! command -v jq &>/dev/null; then
    if [[ -x "$HOME/bin/jq.exe" ]]; then
        export PATH="$HOME/bin:$PATH"
    else
        echo "FATAL: jq is required but not found." >&2
        exit 1
    fi
fi

SOURCE_ID="${1:?Usage: $0 <source-job-id> <new-job-id> [new-features-file]}"
NEW_ID="${2:?Usage: $0 <source-job-id> <new-job-id> [new-features-file]}"
NEW_FEATURES_FILE="${3:-}"

# Find source job file
SOURCE_JOB=""
for dir in "$PROJECT_DIR/examples" "$PROJECT_DIR/jobs/done" "$PROJECT_DIR/jobs/running"; do
    if [[ -f "$dir/${SOURCE_ID}.json" ]]; then
        SOURCE_JOB="$dir/${SOURCE_ID}.json"
        break
    fi
done

if [[ -z "$SOURCE_JOB" ]]; then
    echo "ERROR: Source job file not found for '$SOURCE_ID'" >&2
    echo "Searched: examples/, jobs/done/, jobs/running/" >&2
    exit 1
fi

echo "Source job: $SOURCE_JOB"

# Extract fields from source job
PRODUCT_NAME=$(jq -r '.product_name // "Unknown Product"' "$SOURCE_JOB")
TASK=$(jq -r '.task // ""' "$SOURCE_JOB")
WORK_BRANCH="forge/${NEW_ID}"

# Read new features if provided
NEW_FEATURES=""
if [[ -n "$NEW_FEATURES_FILE" && -f "$NEW_FEATURES_FILE" ]]; then
    NEW_FEATURES=$(cat "$NEW_FEATURES_FILE")
    echo "New features loaded from: $NEW_FEATURES_FILE"
fi

# Copy test commands from source
TEST_CMDS=$(jq '.commands.test // []' "$SOURCE_JOB")

# Generate continuation job
OUTPUT_FILE="$PROJECT_DIR/examples/${NEW_ID}.json"

jq -cn \
    --arg id "$NEW_ID" \
    --arg continue_from "$SOURCE_ID" \
    --arg work_branch "$WORK_BRANCH" \
    --arg task "Continuation of $PRODUCT_NAME from $SOURCE_ID. Extend with new features." \
    --arg product_name "$PRODUCT_NAME" \
    --arg new_features "$NEW_FEATURES" \
    --argjson test_cmds "$TEST_CMDS" \
    '{
        id: $id,
        repo: "local://continue",
        continue_from: $continue_from,
        base_ref: "main",
        work_branch: $work_branch,
        task: $task,
        time_budget_sec: 14400,
        mode: "product",
        product_name: $product_name,
        max_loops: 12,
        new_features: $new_features,
        commands: {
            continue_setup: [],
            test: $test_cmds
        }
    }' > "$OUTPUT_FILE"

echo "Created: $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "  1. Edit $OUTPUT_FILE to customize task description and new_features"
echo "  2. Add program_md field with continuation-specific PROGRAM.md"
echo "  3. Add continue_setup commands if new dependencies are needed"
echo "  4. Run: bash scripts/launch-job.sh $OUTPUT_FILE"

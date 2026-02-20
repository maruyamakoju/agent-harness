#!/usr/bin/env bash
# =============================================================================
# create-job.sh - Job JSON generator helper
# Usage: create-job.sh --repo <git-url> --task <description> [options]
# =============================================================================
set -euo pipefail

JOBS_DIR="${HARNESS_DIR:-/harness}/jobs/pending"

# Defaults
REPO=""
TASK=""
BASE_REF="main"
TIME_BUDGET=3600
MAX_RETRIES=2
GPU_REQUIRED=false
PRIORITY=3
ISSUE_NUMBER=""
ISSUE_REPO=""
SETUP_CMDS='[]'
TEST_CMDS='[]'

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: create-job.sh [OPTIONS]

Required:
  --repo <url>          Git repository URL (SSH or HTTPS)
  --task <description>  Task description for the agent

Optional:
  --base <ref>          Base branch (default: main)
  --branch <name>       Work branch name (auto-generated if omitted)
  --time-budget <sec>   Time budget in seconds (default: 3600)
  --max-retries <n>     Max retries on failure (default: 2)
  --gpu                 Mark job as GPU-required
  --priority <1-5>      Job priority: 1=緊急, 2=高, 3=普通(default), 4=低, 5=最低
  --issue-number <n>    GitHub Issue number to close on PR merge
  --issue-repo <owner/repo>  GitHub repo containing the issue
  --setup <cmd>         Setup command (can be repeated)
  --test <cmd>          Test command (can be repeated)

Examples:
  create-job.sh --repo git@github.com:org/repo.git \\
    --task "Add user authentication with JWT" \\
    --setup "npm ci" --setup "npx prisma migrate dev" \\
    --test "npm test" --test "npm run e2e"

  create-job.sh --repo git@github.com:org/ml-project.git \\
    --task "Train MNIST classifier" \\
    --gpu --time-budget 7200 \\
    --setup "pip install -r requirements.txt" \\
    --test "pytest tests/"
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SETUP_ARRAY=()
TEST_ARRAY=()
BRANCH_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)     REPO="$2"; shift 2 ;;
        --task)     TASK="$2"; shift 2 ;;
        --base)     BASE_REF="$2"; shift 2 ;;
        --branch)   BRANCH_OVERRIDE="$2"; shift 2 ;;
        --time-budget) TIME_BUDGET="$2"; shift 2 ;;
        --max-retries) MAX_RETRIES="$2"; shift 2 ;;
        --gpu)          GPU_REQUIRED=true; shift ;;
        --priority)     PRIORITY="$2"; shift 2 ;;
        --issue-number) ISSUE_NUMBER="$2"; shift 2 ;;
        --issue-repo)   ISSUE_REPO="$2"; shift 2 ;;
        --setup)        SETUP_ARRAY+=("$2"); shift 2 ;;
        --test)         TEST_ARRAY+=("$2"); shift 2 ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

# Validate required args
if [[ -z "$REPO" ]] || [[ -z "$TASK" ]]; then
    echo "Error: --repo and --task are required"
    usage
fi

# Validate numeric args (prevent jq errors and bad job files)
if ! [[ "$TIME_BUDGET" =~ ^[0-9]+$ ]]; then
    echo "Error: --time-budget must be a non-negative integer (got: '$TIME_BUDGET')"
    usage
fi
if ! [[ "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
    echo "Error: --max-retries must be a non-negative integer (got: '$MAX_RETRIES')"
    usage
fi
if ! [[ "$PRIORITY" =~ ^[1-5]$ ]]; then
    echo "Error: --priority must be 1-5 (got: '$PRIORITY')"
    usage
fi
if [[ -n "$ISSUE_NUMBER" ]] && ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: --issue-number must be a positive integer (got: '$ISSUE_NUMBER')"
    usage
fi

# Ensure destination directory exists
mkdir -p "$JOBS_DIR"

# ---------------------------------------------------------------------------
# Generate job ID and branch name
# ---------------------------------------------------------------------------
TIMESTAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
# Create a slug from the task (first 40 chars, lowercased, spaces→hyphens)
TASK_SLUG=$(echo "$TASK" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 40)
# Fallback to random suffix if slug is empty (e.g. non-ASCII task)
if [[ -z "$TASK_SLUG" ]]; then
    TASK_SLUG=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)
fi
JOB_ID="${TIMESTAMP}-${TASK_SLUG}"

if [[ -n "$BRANCH_OVERRIDE" ]]; then
    WORK_BRANCH="$BRANCH_OVERRIDE"
else
    WORK_BRANCH="agent/${TIMESTAMP}-${TASK_SLUG}"
fi

# ---------------------------------------------------------------------------
# Build JSON arrays for commands
# ---------------------------------------------------------------------------
SETUP_CMDS=$(printf '%s\n' "${SETUP_ARRAY[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')
TEST_CMDS=$(printf '%s\n' "${TEST_ARRAY[@]}" 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')

# ---------------------------------------------------------------------------
# Write job file
# ---------------------------------------------------------------------------
JOB_FILE="${JOBS_DIR}/${JOB_ID}.json"

# Build optional issue fields
ISSUE_FIELDS=""
if [[ -n "$ISSUE_NUMBER" ]]; then
    ISSUE_FIELDS=$(jq -n \
        --argjson num "$ISSUE_NUMBER" \
        --arg repo "$ISSUE_REPO" \
        '{issue_number: $num, issue_repo: $repo}')
fi

jq -n \
    --arg id "$JOB_ID" \
    --arg repo "$REPO" \
    --arg base "$BASE_REF" \
    --arg branch "$WORK_BRANCH" \
    --arg task "$TASK" \
    --argjson setup "$SETUP_CMDS" \
    --argjson test "$TEST_CMDS" \
    --argjson budget "$TIME_BUDGET" \
    --argjson retries "$MAX_RETRIES" \
    --argjson gpu "$GPU_REQUIRED" \
    --argjson priority "$PRIORITY" \
    --argjson issue "${ISSUE_FIELDS:-null}" \
    '{
        id: $id,
        repo: $repo,
        base_ref: $base,
        work_branch: $branch,
        task: $task,
        commands: {
            setup: $setup,
            test: $test
        },
        time_budget_sec: $budget,
        max_retries: $retries,
        gpu_required: $gpu,
        priority: $priority,
        created_at: (now | todate)
    } + (if $issue != null then $issue else {} end)' > "$JOB_FILE"

echo "Job created: $JOB_FILE"
echo "Job ID: $JOB_ID"
jq . "$JOB_FILE"

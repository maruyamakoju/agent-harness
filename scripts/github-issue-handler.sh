#!/usr/bin/env bash
# =============================================================================
# github-issue-handler.sh - Create jobs from GitHub Issues
# Watches for issues with the "agent" label and creates jobs from them.
#
# Run via cron every 5 minutes:
#   */5 * * * * bash /home/agent/agent-harness/scripts/github-issue-handler.sh
#
# Or as a one-shot:
#   bash scripts/github-issue-handler.sh org/repo
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
SCRIPTS_DIR="${HARNESS_DIR}/scripts"
STATE_FILE="${HARNESS_DIR}/logs/github-issues-processed.txt"

# Repos to watch (space-separated, or pass as argument)
REPOS="${1:-${AGENT_WATCH_REPOS:-}}"

if [[ -z "$REPOS" ]]; then
    echo "Usage: github-issue-handler.sh <org/repo> [org/repo2 ...]"
    echo "  Or set AGENT_WATCH_REPOS env var"
    exit 1
fi

# Create state file if missing
touch "$STATE_FILE"

for repo in $REPOS; do
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Checking $repo for agent issues..."

    # Fetch open issues with "agent" label
    issues=$(gh issue list \
        --repo "$repo" \
        --label "agent" \
        --state open \
        --json number,title,body \
        --limit 10 \
        2>/dev/null || echo "[]")

    echo "$issues" | jq -c '.[]' 2>/dev/null | while IFS= read -r issue; do
        local number title body
        number=$(echo "$issue" | jq -r '.number')
        title=$(echo "$issue" | jq -r '.title')
        body=$(echo "$issue" | jq -r '.body')

        # Check if already processed
        local issue_key="${repo}#${number}"
        if grep -qF "$issue_key" "$STATE_FILE"; then
            continue
        fi

        echo "  New agent issue: $issue_key - $title"

        # Extract repo URL (use the same repo by default)
        local target_repo="git@github.com:${repo}.git"

        # Extract task from title + body
        local task="$title"
        if [[ -n "$body" ]]; then
            # Use first non-empty line of body as extended task
            local body_first
            body_first=$(echo "$body" | head -5 | tr '\n' ' ' | head -c 200)
            task="${title}. ${body_first}"
        fi

        # Extract setup/test commands from body if present
        local setup_args=()
        local test_args=()

        # Look for ```setup and ```test blocks in issue body
        if echo "$body" | grep -q "setup:"; then
            local setup_cmd
            setup_cmd=$(echo "$body" | sed -n 's/.*setup:\s*`\([^`]*\)`.*/\1/p' | head -1)
            [[ -n "$setup_cmd" ]] && setup_args+=("--setup" "$setup_cmd")
        fi

        if echo "$body" | grep -q "test:"; then
            local test_cmd
            test_cmd=$(echo "$body" | sed -n 's/.*test:\s*`\([^`]*\)`.*/\1/p' | head -1)
            [[ -n "$test_cmd" ]] && test_args+=("--test" "$test_cmd")
        fi

        # Create job
        "$SCRIPTS_DIR/create-job.sh" \
            --repo "$target_repo" \
            --task "$task" \
            "${setup_args[@]}" \
            "${test_args[@]}" \
            2>&1 || echo "  WARNING: Failed to create job for $issue_key"

        # Mark as processed
        echo "$issue_key" >> "$STATE_FILE"

        # Add comment to issue
        gh issue comment "$number" \
            --repo "$repo" \
            --body "Agent job created for this issue. The autonomous coding agent will work on it shortly. A PR will be created when the work is complete." \
            2>/dev/null || true

        echo "  Job created for $issue_key"
    done
done

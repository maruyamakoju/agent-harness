#!/usr/bin/env bash
# =============================================================================
# github-issue-handler.sh - Create jobs from GitHub Issues
# Watches for issues with the "agent" label and creates jobs from them.
#
# Usage:
#   github-issue-handler.sh <org/repo> [org/repo2 ...]
#   Or set AGENT_WATCH_REPOS env var (space-separated)
#
# Issue body format (all optional):
#   repo: https://github.com/org/other-repo.git
#   setup: `pip install -e '.[dev]'`
#   test: `python -m pytest`
#   time-budget: 1200
#   base: develop
#
#   (Remaining text is appended to the task description)
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
SCRIPTS_DIR="${HARNESS_DIR}/scripts"
LOGS_DIR="${HARNESS_DIR}/logs"
STATE_FILE="${LOGS_DIR}/github-issues-processed.txt"
ISSUE_MAP_FILE="${LOGS_DIR}/issue-job-map.jsonl"

# Repos to watch (space-separated, or pass as argument)
REPOS="${*:-${AGENT_WATCH_REPOS:-}}"

if [[ -z "$REPOS" ]]; then
    echo "Usage: github-issue-handler.sh <org/repo> [org/repo2 ...]"
    echo "  Or set AGENT_WATCH_REPOS env var"
    exit 1
fi

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ISSUE] $*"
}

# Create state files if missing
touch "$STATE_FILE" "$ISSUE_MAP_FILE"

# ---------------------------------------------------------------------------
# Process new issues
# ---------------------------------------------------------------------------
process_new_issues() {
    for repo in $REPOS; do
        log "Checking $repo for agent issues..."

        # Fetch open issues with "agent" label
        local issues
        issues=$(gh issue list \
            --repo "$repo" \
            --label "agent" \
            --state open \
            --json number,title,body \
            --limit 10 \
            2>/dev/null || echo "[]")

        while IFS= read -r issue; do
            local number title body
            number=$(echo "$issue" | jq -r '.number')
            title=$(echo "$issue" | jq -r '.title')
            body=$(echo "$issue" | jq -r '.body // ""')

            # Check if already processed
            local issue_key="${repo}#${number}"
            if grep -qF "$issue_key" "$STATE_FILE"; then
                continue
            fi

            log "New agent issue: $issue_key - $title"

            # Parse structured fields from body using awk for robust handling of
            # values containing ':' (e.g. URLs, docker image:tag, timestamps)
            local target_repo="https://github.com/${repo}.git"
            local setup_cmd="" test_cmd="" time_budget="1200" base_ref="main"

            # _extract_field KEY BODY: returns the value after "KEY: " on the first
            # matching line (case-insensitive), stripping backticks and leading/
            # trailing whitespace. Uses awk so that colons in values are preserved.
            _extract_field() {
                local key="$1"
                local text="$2"
                echo "$text" | awk -v key="$key" '
                    /^[[:space:]]*/ {
                        line = $0
                        # strip leading whitespace
                        sub(/^[[:space:]]+/, "", line)
                        # check if line starts with key:
                        k = tolower(key) ":"
                        lline = tolower(line)
                        if (index(lline, k) == 1) {
                            # extract everything after "key:"
                            val = substr(line, length(key)+2)
                            # strip leading whitespace
                            sub(/^[[:space:]]+/, "", val)
                            # strip backticks
                            gsub(/`/, "", val)
                            # strip trailing whitespace
                            sub(/[[:space:]]+$/, "", val)
                            print val
                            exit
                        }
                    }
                ' 2>/dev/null || true
            }

            # Extract repo: field
            local parsed_repo
            parsed_repo=$(_extract_field "repo" "$body")
            [[ -n "$parsed_repo" ]] && target_repo="$parsed_repo"

            # Extract setup: field
            setup_cmd=$(_extract_field "setup" "$body")

            # Extract test: field
            test_cmd=$(_extract_field "test" "$body")

            # Extract time-budget: field (numeric only)
            local raw_budget
            raw_budget=$(_extract_field "time-budget" "$body")
            if echo "$raw_budget" | grep -qE '^[0-9]+$'; then
                time_budget="$raw_budget"
            fi

            # Extract base: field
            local raw_base
            raw_base=$(_extract_field "base" "$body")
            [[ -n "$raw_base" ]] && base_ref="$raw_base"

            # Extract priority: field (1-5, default 3)
            local priority=3
            local raw_prio
            raw_prio=$(_extract_field "priority" "$body")
            if echo "$raw_prio" | grep -qE '^[1-5]$'; then
                priority="$raw_prio"
            fi

            # Build task from title + remaining body text
            local task="$title"
            local extra_text
            extra_text=$(echo "$body" | grep -ivE '^(repo|setup|test|time-budget|base|priority):' | head -10 | tr '\n' ' ' | sed 's/  */ /g' | head -c 500)
            if [[ -n "$extra_text" && "$extra_text" != " " ]]; then
                task="${title}. ${extra_text}"
            fi

            # Build create-job args
            local job_args=(
                --repo "$target_repo"
                --task "$task"
                --base "$base_ref"
                --time-budget "$time_budget"
                --priority "$priority"
                --issue-number "$number"
                --issue-repo "$repo"
            )
            [[ -n "$setup_cmd" ]] && job_args+=(--setup "$setup_cmd")
            [[ -n "$test_cmd" ]] && job_args+=(--test "$test_cmd")

            # Create job
            local job_output
            job_output=$("$SCRIPTS_DIR/create-job.sh" "${job_args[@]}" 2>&1) || {
                log "WARNING: Failed to create job for $issue_key"
                continue
            }

            # Extract job ID from output
            local job_id
            job_id=$(echo "$job_output" | grep "Job ID:" | awk '{print $3}')

            # Save issue→job mapping
            jq -cn \
                --arg issue "$issue_key" \
                --arg job_id "$job_id" \
                --arg repo "$repo" \
                --argjson number "$number" \
                '{issue: $issue, job_id: $job_id, repo: $repo, number: $number, status: "created"}' \
                >> "$ISSUE_MAP_FILE"

            # Mark as processed
            echo "$issue_key" >> "$STATE_FILE"

            # Comment on issue
            gh issue comment "$number" \
                --repo "$repo" \
                --body "$(cat <<COMMENT
🤖 **Agent job created**

| Field | Value |
|-------|-------|
| Job ID | \`${job_id}\` |
| Target Repo | \`${target_repo}\` |
| Time Budget | ${time_budget}s |
| Setup | \`${setup_cmd:-none}\` |
| Test | \`${test_cmd:-none}\` |

The autonomous coding agent will start working on this shortly. A PR will be created when complete.
COMMENT
            )" 2>/dev/null || true

            log "Job created for $issue_key -> $job_id"
        done < <(echo "$issues" | jq -c '.[]' 2>/dev/null)
    done
}

# ---------------------------------------------------------------------------
# Check completed jobs and update issues
# ---------------------------------------------------------------------------
update_completed_issues() {
    [[ ! -f "$ISSUE_MAP_FILE" ]] && return

    local temp_file
    temp_file=$(mktemp)
    local updated=false

    while IFS= read -r mapping; do
        local status job_id repo number
        status=$(echo "$mapping" | jq -r '.status')
        job_id=$(echo "$mapping" | jq -r '.job_id')
        repo=$(echo "$mapping" | jq -r '.repo')
        number=$(echo "$mapping" | jq -r '.number')

        if [[ "$status" != "created" ]]; then
            echo "$mapping" >> "$temp_file"
            continue
        fi

        # Check if job completed
        if [[ -f "${HARNESS_DIR}/jobs/done/${job_id}.json" ]]; then
            log "Job $job_id completed, updating issue ${repo}#${number}"

            # Find PR URL from job log
            local pr_url=""
            if [[ -f "${LOGS_DIR}/${job_id}.log" ]]; then
                pr_url=$(grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' "${LOGS_DIR}/${job_id}.log" | tail -1 || true)
            fi

            # Comment on issue with result
            local comment="✅ **Job completed successfully!**"
            if [[ -n "$pr_url" ]]; then
                comment="${comment}\n\nPR: ${pr_url}\n\nPlease review and merge."
            fi
            gh issue comment "$number" --repo "$repo" --body "$(echo -e "$comment")" 2>/dev/null || true

            # Close issue
            gh issue close "$number" --repo "$repo" --reason completed 2>/dev/null || true

            echo "$mapping" | jq -c '.status = "done"' >> "$temp_file"
            updated=true

        elif [[ -f "${HARNESS_DIR}/jobs/failed/${job_id}.json" ]]; then
            log "Job $job_id failed, updating issue ${repo}#${number}"

            gh issue comment "$number" --repo "$repo" \
                --body "❌ **Job failed.** Check logs for details. You can re-open this issue and add the \`agent\` label to retry." \
                2>/dev/null || true

            # Remove agent label so it doesn't retry automatically
            gh issue edit "$number" --repo "$repo" --remove-label "agent" 2>/dev/null || true

            echo "$mapping" | jq -c '.status = "failed"' >> "$temp_file"
            updated=true
        else
            # Still pending/running
            echo "$mapping" >> "$temp_file"
        fi
    done < "$ISSUE_MAP_FILE"

    if [[ "$updated" == "true" ]]; then
        mv "$temp_file" "$ISSUE_MAP_FILE"
    else
        rm -f "$temp_file"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
process_new_issues
update_completed_issues

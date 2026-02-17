#!/usr/bin/env bash
# =============================================================================
# run-job.sh - Per-Job State Machine
# States: CLONE → SETUP → INIT → CODE → TEST → PUSH → DONE
# Handles: stall detection, time budget, conversation resume, partial push
# =============================================================================
set -uo pipefail

JOB_FILE="$1"
HARNESS_DIR="${HARNESS_DIR:-/harness}"
LOGS_DIR="${HARNESS_DIR}/logs"
SCRIPTS_DIR="${HARNESS_DIR}/scripts"
WORKSPACES_DIR="${WORKSPACES_DIR:-/workspaces}"

# ---------------------------------------------------------------------------
# Parse job JSON
# ---------------------------------------------------------------------------
JOB_ID=$(jq -r '.id' "$JOB_FILE")
REPO=$(jq -r '.repo' "$JOB_FILE")
BASE_REF=$(jq -r '.base_ref // "main"' "$JOB_FILE")
WORK_BRANCH=$(jq -r '.work_branch' "$JOB_FILE")
TASK=$(jq -r '.task' "$JOB_FILE")
TIME_BUDGET=$(jq -r '.time_budget_sec // 3600' "$JOB_FILE")
GPU_REQUIRED=$(jq -r '.gpu_required // false' "$JOB_FILE")

# Commands
SETUP_CMDS=$(jq -r '.commands.setup // [] | .[]' "$JOB_FILE")
TEST_CMDS=$(jq -r '.commands.test // [] | .[]' "$JOB_FILE")

# Runtime state
JOB_LOG="${LOGS_DIR}/${JOB_ID}.log"
WORKSPACE="${WORKSPACES_DIR}/${JOB_ID}"
STATE="CLONE"
ITERATION=0
MAX_ITERATIONS=10
NO_PROGRESS_COUNT=0
MAX_NO_PROGRESS=3
ERROR_COUNTS_FILE=$(mktemp)
echo "{}" > "$ERROR_COUNTS_FILE"
JOB_START_TIME=$(date +%s)
LAST_COMMIT_HASH=""
CONVERSATION_ID=""          # Claude Code session ID for resume
TOTAL_COST_USD=0            # Track API cost

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[$timestamp] [$level] [${STATE}] $*" | tee -a "$JOB_LOG"
}

log_json() {
    local event="$1"
    shift
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local elapsed=$(( $(date +%s) - JOB_START_TIME ))
    jq -cn \
        --arg ts "$timestamp" \
        --arg evt "$event" \
        --arg jid "$JOB_ID" \
        --arg st "$STATE" \
        --argjson iter "$ITERATION" \
        --argjson elapsed "$elapsed" \
        --arg detail "$*" \
        '{timestamp:$ts, job_id:$jid, event:$evt, state:$st, iteration:$iter, elapsed_sec:$elapsed, detail:$detail}' \
        >> "${LOGS_DIR}/${JOB_ID}.jsonl"
}

log_state_transition() {
    local from="$1"
    local to="$2"
    local reason="${3:-}"
    log "INFO" "State transition: $from -> $to ${reason:+(reason: $reason)}"
    log_json "state_transition" "from=$from to=$to reason=${reason:-none}"
}

# ---------------------------------------------------------------------------
# Time budget check
# ---------------------------------------------------------------------------
check_time_budget() {
    local now
    now=$(date +%s)
    local elapsed=$((now - JOB_START_TIME))
    if [[ $elapsed -ge $TIME_BUDGET ]]; then
        log "WARN" "Time budget exceeded: ${elapsed}s / ${TIME_BUDGET}s"
        log_json "time_budget_exceeded" "elapsed=${elapsed}s budget=${TIME_BUDGET}s"
        return 1
    fi
    local remaining=$((TIME_BUDGET - elapsed))
    if [[ $remaining -lt 300 ]]; then
        log "WARN" "Time budget low: ${remaining}s remaining"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Stall detection: check if new commits were made
# ---------------------------------------------------------------------------
check_progress() {
    local current_hash
    current_hash=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo "none")
    if [[ "$current_hash" == "$LAST_COMMIT_HASH" ]]; then
        NO_PROGRESS_COUNT=$((NO_PROGRESS_COUNT + 1))
        log "WARN" "No progress detected (${NO_PROGRESS_COUNT}/${MAX_NO_PROGRESS})"
        log_json "stall_warning" "count=${NO_PROGRESS_COUNT} max=${MAX_NO_PROGRESS}"
        if [[ $NO_PROGRESS_COUNT -ge $MAX_NO_PROGRESS ]]; then
            log "ERROR" "Stall detected: $MAX_NO_PROGRESS iterations without commit"
            log_json "stall_detected" "giving up after $MAX_NO_PROGRESS stalls"
            return 1
        fi
    else
        NO_PROGRESS_COUNT=0
        LAST_COMMIT_HASH="$current_hash"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Error repetition detection
# ---------------------------------------------------------------------------
track_error() {
    local error_sig
    error_sig=$(echo "$1" | md5sum | cut -d' ' -f1)
    local count
    count=$(jq -r --arg k "$error_sig" '.[$k] // 0' "$ERROR_COUNTS_FILE")
    count=$((count + 1))
    local tmp
    tmp=$(jq --arg k "$error_sig" --argjson v "$count" '.[$k] = $v' "$ERROR_COUNTS_FILE")
    echo "$tmp" > "$ERROR_COUNTS_FILE"
    if [[ $count -ge 5 ]]; then
        log "ERROR" "Same error repeated $count times. Aborting."
        log_json "error_repetition_limit" "count=$count signature=$error_sig"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Gather repo context for prompts
# ---------------------------------------------------------------------------
gather_repo_context() {
    local context=""

    # File tree (max 100 lines)
    context+="## Repository Structure\n"
    context+='```\n'
    context+=$(find "$WORKSPACE" -maxdepth 3 \
        -not -path '*/.git/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/__pycache__/*' \
        -not -path '*/.venv/*' \
        -type f 2>/dev/null | head -100 | sed "s|$WORKSPACE/||g" | sort)
    context+='\n```\n\n'

    # README (first 80 lines)
    if [[ -f "$WORKSPACE/README.md" ]]; then
        context+="## README.md (first 80 lines)\n"
        context+='```\n'
        context+=$(head -80 "$WORKSPACE/README.md")
        context+='\n```\n\n'
    fi

    # package.json summary
    if [[ -f "$WORKSPACE/package.json" ]]; then
        context+="## package.json (dependencies)\n"
        context+='```json\n'
        context+=$(jq '{name,version,scripts,dependencies,devDependencies}' "$WORKSPACE/package.json" 2>/dev/null || cat "$WORKSPACE/package.json")
        context+='\n```\n\n'
    fi

    # requirements.txt
    if [[ -f "$WORKSPACE/requirements.txt" ]]; then
        context+="## requirements.txt\n"
        context+='```\n'
        context+=$(cat "$WORKSPACE/requirements.txt")
        context+='\n```\n\n'
    fi

    # pyproject.toml summary
    if [[ -f "$WORKSPACE/pyproject.toml" ]]; then
        context+="## pyproject.toml (first 50 lines)\n"
        context+='```\n'
        context+=$(head -50 "$WORKSPACE/pyproject.toml")
        context+='\n```\n\n'
    fi

    echo -e "$context"
}

# ---------------------------------------------------------------------------
# Build initializer prompt (richer context)
# ---------------------------------------------------------------------------
build_init_prompt() {
    local repo_context
    repo_context=$(gather_repo_context)

    cat <<PROMPT
You are an autonomous coding agent. Your job is to analyze this repository and plan the implementation.

## Task
${TASK}

## Repository Context
${repo_context}

## Test Commands Available
$(echo "$TEST_CMDS" | sed 's/^/- /' || echo "- (none specified)")

## Instructions
1. Thoroughly explore the repository: read key source files, understand the architecture, check existing tests.
2. Create \`requirements.json\` in the project root with a structured breakdown:
   {
     "task": "<original task description>",
     "subtasks": [
       {
         "id": 1,
         "description": "<what to implement>",
         "files_to_modify": ["<path>"],
         "files_to_create": ["<path>"],
         "test_strategy": "<how to verify>",
         "complexity": "low|medium|high"
       }
     ],
     "estimated_iterations": <number>,
     "risks": ["<potential issues>"],
     "approach": "<high-level implementation strategy>"
   }
3. Create \`claude-progress.txt\` in the project root:
   # Progress Log
   ## Task: <task>
   ## Status: INITIALIZED
   ## Approach: <your implementation strategy>
   ## Subtasks
   - [ ] 1. <description>
   - [ ] 2. <description>
   ...

4. Do NOT start coding yet. Only analyze and plan.
5. Be thorough - the quality of your plan determines the success of implementation.
PROMPT
}

# ---------------------------------------------------------------------------
# Build coding prompt (with carry-over context)
# ---------------------------------------------------------------------------
build_coding_prompt() {
    local progress_content=""
    if [[ -f "$WORKSPACE/claude-progress.txt" ]]; then
        progress_content=$(cat "$WORKSPACE/claude-progress.txt")
    fi

    local requirements_content=""
    if [[ -f "$WORKSPACE/requirements.json" ]]; then
        requirements_content=$(cat "$WORKSPACE/requirements.json")
    fi

    local git_log=""
    git_log=$(git -C "$WORKSPACE" log --oneline -20 2>/dev/null || echo "(no commits yet)")

    local elapsed=$(( $(date +%s) - JOB_START_TIME ))
    local remaining=$(( TIME_BUDGET - elapsed ))

    cat <<PROMPT
You are an autonomous coding agent. Continue working on the task below.

## Task
${TASK}

## Current Iteration
${ITERATION} / ${MAX_ITERATIONS}

## Time Remaining
${remaining} seconds (budget: ${TIME_BUDGET}s)

## Current Progress
${progress_content}

## Requirements Plan
\`\`\`json
${requirements_content}
\`\`\`

## Recent Git History
\`\`\`
${git_log}
\`\`\`

## Test Commands
$(echo "$TEST_CMDS" | sed 's/^/- /' || echo "- (none specified)")

## Rules
1. Pick the NEXT incomplete subtask from the progress file.
2. Implement it fully - write the code, handle edge cases.
3. Run the test commands to verify your changes work.
4. If tests pass: commit with message format \`<type>(<scope>): <description>\`
   Types: feat, fix, test, refactor, docs, chore
5. If tests fail: debug and fix. Max 3 fix attempts per subtask.
6. Update \`claude-progress.txt\`:
   - Mark completed subtasks with [x]
   - Note what was done and the commit hash
   - Note any issues encountered
7. Do NOT push to remote. Do NOT modify .git/config.
8. Stay focused on ONE subtask at a time.

Begin working on the next incomplete subtask now.
PROMPT
}

# ---------------------------------------------------------------------------
# Build fix prompt (when tests fail after CODE)
# ---------------------------------------------------------------------------
build_fix_prompt() {
    local test_output="$1"
    local progress_content=""
    if [[ -f "$WORKSPACE/claude-progress.txt" ]]; then
        progress_content=$(cat "$WORKSPACE/claude-progress.txt")
    fi

    cat <<PROMPT
You are an autonomous coding agent. The tests have FAILED after your last coding iteration.

## Task
${TASK}

## Test Output (last failure)
\`\`\`
${test_output}
\`\`\`

## Current Progress
${progress_content}

## Instructions
1. Analyze the test failure output carefully.
2. Identify the root cause - is it a bug in your code, a missing dependency, a configuration issue?
3. Fix the issue. Make minimal, targeted changes.
4. Run the test commands again to verify the fix.
5. If tests pass, commit with: \`fix(<scope>): <what you fixed>\`
6. Update claude-progress.txt with what you fixed.

Test Commands:
$(echo "$TEST_CMDS" | sed 's/^/- /')

Fix the failing tests now.
PROMPT
}

# ---------------------------------------------------------------------------
# Invoke Claude Code in headless mode
# ---------------------------------------------------------------------------
invoke_claude() {
    local prompt="$1"
    local output_file
    output_file=$(mktemp)

    local claude_args=(
        -p
        --output-format json
        --allowedTools "Write" "Read" "Edit"
            "Bash(git *)" "Bash(npm *)" "Bash(npx *)" "Bash(node *)"
            "Bash(python *)" "Bash(python3 *)" "Bash(pytest *)"
            "Bash(pip *)" "Bash(pip3 *)"
            "Bash(find *)" "Bash(cat *)" "Bash(ls *)" "Bash(grep *)"
            "Bash(mkdir *)" "Bash(cp *)" "Bash(mv *)"
            "Bash(cd *)" "Bash(pwd)" "Bash(echo *)"
            "Bash(chmod *)" "Bash(head *)" "Bash(tail *)"
            "Bash(wc *)" "Bash(sort *)" "Bash(diff *)"
            "Bash(touch *)" "Bash(rm *)" "Bash(sed *)"
            "Bash(tee *)" "Bash(xargs *)"
        --model claude-sonnet-4-5-20250929
    )

    # Resume conversation if we have a session ID
    if [[ -n "$CONVERSATION_ID" ]]; then
        claude_args+=(--resume "$CONVERSATION_ID")
    fi

    log "INFO" "Invoking Claude Code (session: ${CONVERSATION_ID:-new})"

    # Run Claude with timeout (use remaining time budget, max 30 min per invocation)
    local elapsed=$(( $(date +%s) - JOB_START_TIME ))
    local remaining=$(( TIME_BUDGET - elapsed ))
    local invoke_timeout=$remaining
    if [[ $invoke_timeout -gt 1800 ]]; then
        invoke_timeout=1800
    fi
    if [[ $invoke_timeout -lt 60 ]]; then
        invoke_timeout=60
    fi

    cd "$WORKSPACE"

    timeout "${invoke_timeout}s" claude "${claude_args[@]}" "$prompt" \
        > "$output_file" 2>&1
    local exit_code=$?

    # Append raw output to job log
    cat "$output_file" >> "$JOB_LOG"

    # Try to extract session ID and cost from JSON output
    if [[ -f "$output_file" ]]; then
        local new_session_id
        new_session_id=$(jq -r '.session_id // .conversation_id // empty' "$output_file" 2>/dev/null || true)
        if [[ -n "$new_session_id" ]]; then
            CONVERSATION_ID="$new_session_id"
            log "INFO" "Session ID: $CONVERSATION_ID"
        fi

        # Extract cost if available
        local cost
        cost=$(jq -r '.cost_usd // .usage.cost // empty' "$output_file" 2>/dev/null || true)
        if [[ -n "$cost" ]]; then
            TOTAL_COST_USD=$(echo "$TOTAL_COST_USD + $cost" | bc 2>/dev/null || echo "$TOTAL_COST_USD")
            log "INFO" "Invocation cost: \$${cost} (total: \$${TOTAL_COST_USD})"
        fi
    fi

    rm -f "$output_file"
    return $exit_code
}

# ---------------------------------------------------------------------------
# State: CLONE
# ---------------------------------------------------------------------------
state_clone() {
    log "INFO" "Cloning $REPO (branch: $BASE_REF, depth: 50)"
    log_json "clone_start" "repo=$REPO base_ref=$BASE_REF"

    if git clone --depth 50 --branch "$BASE_REF" "$REPO" "$WORKSPACE" 2>&1 | tee -a "$JOB_LOG"; then
        cd "$WORKSPACE"

        # Configure git user for commits
        git config user.name "Autonomous Agent" 2>/dev/null
        git config user.email "agent@autonomous-coding-agent.local" 2>/dev/null

        git checkout -b "$WORK_BRANCH" 2>&1 | tee -a "$JOB_LOG"

        # Copy CLAUDE.md into workspace (if not already present)
        if [[ ! -f "$WORKSPACE/CLAUDE.md" ]]; then
            cp "${HARNESS_DIR}/CLAUDE.md" "$WORKSPACE/CLAUDE.md" 2>/dev/null || true
        fi

        LAST_COMMIT_HASH=$(git rev-parse HEAD)
        log_json "clone_success" "branch=$WORK_BRANCH commit=$LAST_COMMIT_HASH"
        log_state_transition "CLONE" "SETUP"
        STATE="SETUP"
    else
        log "ERROR" "Clone failed for $REPO"
        log_json "clone_failed" "repo=$REPO"
        STATE="FAILED"
    fi
}

# ---------------------------------------------------------------------------
# State: SETUP
# ---------------------------------------------------------------------------
state_setup() {
    cd "$WORKSPACE"
    if [[ -z "$SETUP_CMDS" ]]; then
        log "INFO" "No setup commands defined, skipping"
        log_state_transition "SETUP" "INIT"
        STATE="INIT"
        return
    fi

    log_json "setup_start" "commands=$(echo "$SETUP_CMDS" | wc -l)"

    local cmd
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        log "INFO" "Running setup: $cmd"
        if eval "$cmd" 2>&1 | tee -a "$JOB_LOG"; then
            log "INFO" "Setup command succeeded: $cmd"
        else
            log "ERROR" "Setup command failed: $cmd"
            log_json "setup_failed" "command=$cmd"
            STATE="FAILED"
            return
        fi
    done <<< "$SETUP_CMDS"

    log_json "setup_success" ""
    log_state_transition "SETUP" "INIT"
    STATE="INIT"
}

# ---------------------------------------------------------------------------
# State: INIT (Initializer Agent)
# ---------------------------------------------------------------------------
state_init() {
    cd "$WORKSPACE"
    log "INFO" "Running initializer agent to analyze repository and plan"
    log_json "init_start" ""

    local prompt
    prompt=$(build_init_prompt)

    if invoke_claude "$prompt"; then
        if [[ -f "$WORKSPACE/claude-progress.txt" ]]; then
            log "INFO" "Initializer completed successfully"
            log_json "init_success" "has_progress=true has_requirements=$(test -f "$WORKSPACE/requirements.json" && echo true || echo false)"
            log_state_transition "INIT" "CODE"
            STATE="CODE"
        else
            log "WARN" "Initializer did not create progress file. Creating fallback."
            cat > "$WORKSPACE/claude-progress.txt" <<EOF
# Progress Log
## Task: ${TASK}
## Status: INITIALIZED (auto-generated fallback)
## Approach: Direct implementation

## Subtasks
- [ ] 1. Implement the requested changes
- [ ] 2. Write/update tests
- [ ] 3. Verify all tests pass
EOF
            log_state_transition "INIT" "CODE" "fallback-progress"
            STATE="CODE"
        fi
    else
        log "ERROR" "Initializer agent failed"
        cat > "$WORKSPACE/claude-progress.txt" <<EOF
# Progress Log
## Task: ${TASK}
## Status: INITIALIZED (fallback after init failure)
## Approach: Direct implementation

## Subtasks
- [ ] 1. Implement the requested changes
- [ ] 2. Write/update tests
- [ ] 3. Verify all tests pass
EOF
        log_json "init_failed_fallback" ""
        log_state_transition "INIT" "CODE" "init-failed-fallback"
        STATE="CODE"
    fi
}

# ---------------------------------------------------------------------------
# State: CODE (Coding Loop)
# ---------------------------------------------------------------------------
state_code() {
    cd "$WORKSPACE"
    ITERATION=$((ITERATION + 1))
    log "INFO" "Coding iteration $ITERATION / $MAX_ITERATIONS"
    log_json "code_iteration" "iteration=$ITERATION"

    # Time budget check
    if ! check_time_budget; then
        log "WARN" "Time budget exceeded during CODE phase"
        STATE="PUSH"
        return
    fi

    # Stall detection
    if ! check_progress; then
        STATE="FAILED"
        return
    fi

    # Max iterations check
    if [[ $ITERATION -gt $MAX_ITERATIONS ]]; then
        log "WARN" "Max iterations ($MAX_ITERATIONS) reached"
        STATE="TEST"
        return
    fi

    local prompt
    prompt=$(build_coding_prompt)

    if invoke_claude "$prompt"; then
        log "INFO" "Coding iteration $ITERATION completed"
        log_json "code_iteration_done" "iteration=$ITERATION"
        STATE="TEST"
    else
        local exit_code=$?
        local error_msg="Claude Code exited with code $exit_code in iteration $ITERATION"
        log "ERROR" "$error_msg"
        log_json "code_error" "exit_code=$exit_code iteration=$ITERATION"

        if ! track_error "$error_msg"; then
            STATE="FAILED"
            return
        fi
        # Retry coding
        STATE="CODE"
    fi
}

# ---------------------------------------------------------------------------
# State: TEST
# ---------------------------------------------------------------------------
state_test() {
    cd "$WORKSPACE"
    log "INFO" "Running tests"
    log_json "test_start" ""

    if [[ -z "$TEST_CMDS" ]]; then
        log "INFO" "No test commands defined, skipping to PUSH"
        log_state_transition "TEST" "PUSH"
        STATE="PUSH"
        return
    fi

    local all_passed=true
    local test_output=""
    local test_output_file
    test_output_file=$(mktemp)

    local cmd
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        log "INFO" "Running test: $cmd"
        if eval "$cmd" 2>&1 | tee -a "$JOB_LOG" "$test_output_file"; then
            log "INFO" "Test passed: $cmd"
        else
            log "WARN" "Test failed: $cmd"
            all_passed=false
        fi
    done <<< "$TEST_CMDS"

    test_output=$(tail -200 "$test_output_file")
    rm -f "$test_output_file"

    if [[ "$all_passed" == "true" ]]; then
        log "INFO" "All tests passed"
        log_json "test_all_passed" ""
        log_state_transition "TEST" "PUSH"
        STATE="PUSH"
    else
        log_json "test_failed" "iteration=$ITERATION"

        # Time budget check before retrying
        if ! check_time_budget; then
            log "WARN" "Time budget exceeded. Pushing partial results."
            STATE="PUSH"
            return
        fi

        if [[ $ITERATION -lt $MAX_ITERATIONS ]]; then
            log "WARN" "Tests failed, invoking fix agent (iteration $ITERATION)"

            # Use a targeted fix prompt with test output
            local fix_prompt
            fix_prompt=$(build_fix_prompt "$test_output")

            if invoke_claude "$fix_prompt"; then
                log "INFO" "Fix attempt completed, re-running tests"
                log_state_transition "TEST" "TEST" "fix-applied-retest"
                # Don't increment iteration for fix, just retest
                STATE="TEST"
            else
                log "WARN" "Fix agent failed, returning to CODE"
                log_state_transition "TEST" "CODE" "fix-failed"
                STATE="CODE"
            fi
        else
            log "ERROR" "Tests failed and max iterations reached. Pushing partial results."
            log_state_transition "TEST" "PUSH" "max-iterations-partial"
            STATE="PUSH"
        fi
    fi
}

# ---------------------------------------------------------------------------
# State: PUSH
# ---------------------------------------------------------------------------
state_push() {
    cd "$WORKSPACE"
    log "INFO" "Pushing results to remote"
    log_json "push_start" ""

    # Ensure everything is committed
    if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
        git add -A 2>&1 | tee -a "$JOB_LOG"
        git commit -m "$(cat <<EOF
chore: auto-commit uncommitted changes before push

Job-ID: ${JOB_ID}
Agent: autonomous-coding-agent
Iterations: ${ITERATION}
EOF
        )" 2>&1 | tee -a "$JOB_LOG" || true
    fi

    # Count total commits on this branch
    local commit_count
    commit_count=$(git rev-list --count "origin/${BASE_REF}..HEAD" 2>/dev/null || echo "?")

    # Push
    if git push -u origin "$WORK_BRANCH" 2>&1 | tee -a "$JOB_LOG"; then
        log "INFO" "Push succeeded ($commit_count commits)"
        log_json "push_success" "commits=$commit_count"

        # Create PR
        local pr_title="[Agent] ${TASK:0:60}"
        local elapsed=$(( $(date +%s) - JOB_START_TIME ))
        local pr_body
        pr_body=$(cat <<EOF
## Automated PR by Autonomous Coding Agent

| Field | Value |
|-------|-------|
| **Job ID** | \`${JOB_ID}\` |
| **Iterations** | ${ITERATION} |
| **Commits** | ${commit_count} |
| **Duration** | $((elapsed / 60))m $((elapsed % 60))s |
| **Branch** | \`${WORK_BRANCH}\` |

### Task
${TASK}

### Progress
$(cat "$WORKSPACE/claude-progress.txt" 2>/dev/null || echo "_No progress file found._")

### Implementation Notes
$(cat "$WORKSPACE/requirements.json" 2>/dev/null | jq -r '.approach // empty' 2>/dev/null || echo "_No approach notes._")

---
_This PR was created automatically by the 24/7 Autonomous Coding Agent._
_Review carefully before merging._
EOF
        )

        if gh pr create \
            --title "$pr_title" \
            --body "$pr_body" \
            --base "$BASE_REF" \
            --head "$WORK_BRANCH" \
            2>&1 | tee -a "$JOB_LOG"; then
            log "INFO" "PR created successfully"
            log_json "pr_created" ""
        else
            log "WARN" "PR creation failed (may already exist)"
            log_json "pr_create_failed" "may already exist"
        fi

        log_state_transition "PUSH" "DONE"
        STATE="DONE"
    else
        log "ERROR" "Push failed"
        log_json "push_failed" ""
        STATE="FAILED"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup workspace
# ---------------------------------------------------------------------------
cleanup() {
    local elapsed=$(( $(date +%s) - JOB_START_TIME ))
    log "INFO" "Job cleanup: duration=${elapsed}s iterations=${ITERATION} cost=\$${TOTAL_COST_USD}"
    log_json "cleanup" "duration=${elapsed}s iterations=${ITERATION} cost=${TOTAL_COST_USD}"

    if [[ -d "$WORKSPACE" ]]; then
        log "INFO" "Removing workspace: $WORKSPACE"
        rm -rf "$WORKSPACE"
    fi
    rm -f "$ERROR_COUNTS_FILE"
}

# =============================================================================
# Main State Machine
# =============================================================================
main() {
    log "INFO" "=========================================="
    log "INFO" "Job started: $JOB_ID"
    log "INFO" "Repo: $REPO"
    log "INFO" "Branch: $BASE_REF -> $WORK_BRANCH"
    log "INFO" "Task: $TASK"
    log "INFO" "Time budget: ${TIME_BUDGET}s"
    log "INFO" "GPU required: $GPU_REQUIRED"
    log "INFO" "=========================================="
    log_json "job_start" "repo=$REPO task=$TASK budget=${TIME_BUDGET}s"

    trap cleanup EXIT

    while true; do
        case "$STATE" in
            CLONE)  state_clone ;;
            SETUP)  state_setup ;;
            INIT)   state_init  ;;
            CODE)   state_code  ;;
            TEST)   state_test  ;;
            PUSH)   state_push  ;;
            DONE)
                log "INFO" "Job completed successfully: $JOB_ID"
                log_json "job_done" "success=true"
                exit 0
                ;;
            FAILED)
                log "ERROR" "Job failed: $JOB_ID"
                log_json "job_failed" ""

                # Attempt partial push if we have any work
                if [[ -d "$WORKSPACE/.git" ]]; then
                    local current_hash
                    current_hash=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo "")
                    local has_changes
                    has_changes=$(git -C "$WORKSPACE" status --porcelain 2>/dev/null || echo "")

                    if [[ -n "$current_hash" && "$current_hash" != "$LAST_COMMIT_HASH" ]] || \
                       [[ -n "$has_changes" ]]; then
                        log "INFO" "Attempting partial push of incomplete work..."
                        cd "$WORKSPACE" 2>/dev/null || true
                        STATE="PUSH"
                        state_push || true
                    fi
                fi
                exit 1
                ;;
            *)
                log "ERROR" "Unknown state: $STATE"
                exit 2
                ;;
        esac
    done
}

main "$@"

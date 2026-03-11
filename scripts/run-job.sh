#!/usr/bin/env bash
# =============================================================================
# run-job.sh - Per-Job State Machine
# States: CLONE → SETUP → INIT → CODE → TEST → PUSH → DONE
# Handles: stall detection, time budget, conversation resume, partial push
# =============================================================================
set -euo pipefail

JOB_FILE="$1"
HARNESS_DIR="${HARNESS_DIR:-/harness}"
LOGS_DIR="${HARNESS_DIR}/logs"
SCRIPTS_DIR="${HARNESS_DIR}/scripts"
WORKSPACES_DIR="${WORKSPACES_DIR:-/workspaces}"

# ---------------------------------------------------------------------------
# Validate job JSON before parsing (fail fast on corrupt files)
# ---------------------------------------------------------------------------
if ! jq empty "$JOB_FILE" 2>/dev/null; then
    echo "[ERROR] Malformed job JSON: $JOB_FILE — skipping" >&2
    exit 1
fi

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

# Product mode fields
MODE=$(jq -r '.mode // "job"' "$JOB_FILE")
PRODUCT_NAME=$(jq -r '.product_name // ""' "$JOB_FILE")
MAX_LOOPS=$(jq -r '.max_loops // 10' "$JOB_FILE")
CREATE_REPO=$(jq -r '.create_repo // false' "$JOB_FILE")
DAY_PLAN_JSON=$(jq -r '.day_plan // null' "$JOB_FILE")
CURRENT_DAY=0
LOOP_COUNT=0
TEMPLATES_DIR="${HARNESS_DIR}/templates/product-state"

# Runtime state
JOB_LOG="${LOGS_DIR}/${JOB_ID}.log"
WORKSPACE="${WORKSPACES_DIR}/${JOB_ID}"
STATE="CLONE"
ITERATION=0
MAX_ITERATIONS=$(jq -r '.max_loops // 10' "$JOB_FILE")
NO_PROGRESS_COUNT=0
MAX_NO_PROGRESS=3
ERROR_COUNTS_FILE=$(mktemp)
echo "{}" > "$ERROR_COUNTS_FILE"
JOB_START_TIME=$(date +%s)
LAST_COMMIT_HASH=""
CONVERSATION_ID=""          # Claude Code session ID for resume
TOTAL_COST_USD=0            # Track API cost
ISSUE_NUMBER=$(jq -r '.issue_number // empty' "$JOB_FILE")
ISSUE_REPO=$(jq -r '.issue_repo // empty' "$JOB_FILE")

# Autoresearch state
SCORE_BEFORE=""
SCORE_AFTER=""
PRE_CODE_COMMIT=""
CONSECUTIVE_DISCARDS=0
JUDGE_VERDICT=""
LOOP_START_TIME=""
MAX_CONSECUTIVE_DISCARDS=5
PLATEAU_COUNT=0
TARGET_SCORE="1.00"
MIN_IMPROVEMENT_DELTA="0.01"
MAX_PLATEAU_LOOPS=2

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
# Persist loop state to job file (enables resume after crash)
# ---------------------------------------------------------------------------
persist_loop_state() {
    if [[ "$MODE" != "product" ]]; then
        return
    fi
    if [[ ! -f "$JOB_FILE" ]]; then
        return
    fi
    local tmp_file="${JOB_FILE}.state.tmp"
    jq --argjson day "$CURRENT_DAY" \
       --argjson loop "$LOOP_COUNT" \
       --arg state "$STATE" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --argjson consecutive_discards "$CONSECUTIVE_DISCARDS" \
       '. + {current_day: $day, loop_count: $loop, last_state: $state, last_state_ts: $ts, consecutive_discards: $consecutive_discards}' \
       "$JOB_FILE" > "$tmp_file" 2>/dev/null \
       && mv "$tmp_file" "$JOB_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Mock Claude response: state-dependent behavior for E2E testing
# CLAUDE_MOCK=true enables this. Each state gets realistic file manipulation.
# MOCK_SCAFFOLD_FAIL=true  — makes SCAFFOLD return non-zero
# MOCK_TEST_FAIL_COUNT=N   — first N test-fix invocations fail (default 0)
# MOCK_PLAN_ALL_DONE=true  — PLAN writes "ALL FEATURES COMPLETE"
# ---------------------------------------------------------------------------
_mock_claude_response() {
    cd "$WORKSPACE" 2>/dev/null || return 1

    case "$STATE" in
        SCAFFOLD)
            if [[ "${MOCK_SCAFFOLD_FAIL:-false}" == "true" ]]; then
                return 1
            fi
            # Simulate Claude customizing the scaffold files
            cat > "$WORKSPACE/FEATURES.md" <<'FEOF'
# Features — Mock Product

| ID    | Feature             | Priority | Status       |
|-------|---------------------|----------|--------------|
| F-001 | Core setup          | P0       | not-started  |
| F-002 | Basic API           | P0       | not-started  |
| F-003 | Authentication      | P1       | not-started  |
| F-004 | Documentation       | P2       | not-started  |
FEOF
            cat > "$WORKSPACE/PROGRESS.md" <<'PEOF'
# Progress — Mock Product

## Day: 0
## Status: IN_PROGRESS

### Current Focus
_(none yet — first planning loop)_

### Completed
_(none)_
PEOF
            cat > "$WORKSPACE/init.sh" <<'IEOF'
#!/usr/bin/env bash
# Mock init.sh — no-op for testing
echo "[init.sh] Mock initialization complete"
exit 0
IEOF
            chmod +x "$WORKSPACE/init.sh"

            cat > "$WORKSPACE/DECISIONS.md" <<'DEOF'
# Decisions Log

## D-001: Technology Choice
- **Date**: $(date -u +%Y-%m-%d)
- **Decision**: Use mock stack for testing
- **Reason**: E2E test validation
DEOF

            git add -A 2>/dev/null
            git commit -m "chore(scaffold): initialize product state for ${PRODUCT_NAME}" 2>/dev/null || true
            return 0
            ;;

        PLAN)
            # Check if we should signal all features done
            if [[ "${MOCK_PLAN_ALL_DONE:-false}" == "true" ]]; then
                cat > "$WORKSPACE/PROGRESS.md" <<'PEOF'
# Progress — Mock Product

## Day: 0
## Status: COMPLETED

ALL FEATURES COMPLETE

### Completed
- [x] F-001: Core setup
- [x] F-002: Basic API
- [x] F-003: Authentication
- [x] F-004: Documentation
PEOF
                git add PROGRESS.md 2>/dev/null
                git commit -m "docs: mark all features complete" 2>/dev/null || true
                return 0
            fi

            # Find next not-started feature and set it as current focus
            local next_feature_id next_feature_name
            next_feature_id=$(grep 'not-started' "$WORKSPACE/FEATURES.md" 2>/dev/null \
                | head -1 | sed 's/.*|\s*\(F-[0-9]*\).*/\1/' | tr -d ' ')
            next_feature_name=$(grep 'not-started' "$WORKSPACE/FEATURES.md" 2>/dev/null \
                | head -1 | sed 's/.*|\s*F-[0-9]*\s*|\s*\([^|]*\).*/\1/' | sed 's/^ *//;s/ *$//')

            if [[ -z "$next_feature_id" ]]; then
                # All features done
                cat > "$WORKSPACE/PROGRESS.md" <<'PEOF'
# Progress — Mock Product

## Day: 0
## Status: COMPLETED

ALL FEATURES COMPLETE
PEOF
                git add PROGRESS.md 2>/dev/null
                git commit -m "docs: mark all features complete" 2>/dev/null || true
                return 0
            fi

            # Update PROGRESS.md with hypothesis format
            cat > "$WORKSPACE/PROGRESS.md" <<PEOF
# Progress — Mock Product

## Day: ${CURRENT_DAY}
## Status: IN_PROGRESS

### Hypothesis
- Feature: ${next_feature_id} — ${next_feature_name}
- If we implement ${next_feature_id}, then tests and lint score will improve
- Expected score delta: +0.10
- Affected files: src/${next_feature_id}.py, tests/test_${next_feature_id}.py
- Rollback rule: revert if composite score does not improve

### Loop ${LOOP_COUNT}
- Selected ${next_feature_id} for hypothesis testing
PEOF

            # Mark feature as in-progress in FEATURES.md
            sed -i "s/| ${next_feature_id} .*|.*| not-started/| ${next_feature_id} | ${next_feature_name} | P0       | in-progress/" \
                "$WORKSPACE/FEATURES.md" 2>/dev/null || true

            git add PROGRESS.md FEATURES.md 2>/dev/null
            git commit -m "plan: select ${next_feature_id} for loop ${LOOP_COUNT}" 2>/dev/null || true
            return 0
            ;;

        CODE)
            # Create a dummy implementation file based on current focus
            local focus_id
            focus_id=$(grep -oE 'F-[0-9]+' "$WORKSPACE/PROGRESS.md" 2>/dev/null | head -1)
            focus_id="${focus_id:-F-000}"

            # Optionally plant a test failure flag on the first CODE invocation
            if [[ "${MOCK_FIRST_CODE_PLANTS_FAIL:-false}" == "true" && $LOOP_COUNT -le 1 ]]; then
                touch "$WORKSPACE/.mock_test_should_fail"
                MOCK_FIRST_CODE_PLANTS_FAIL=false  # only once
            fi

            mkdir -p "$WORKSPACE/src" "$WORKSPACE/tests"

            # MOCK_CODE_AUDIT_FAIL: create too many files to trigger audit violation
            if [[ "${MOCK_CODE_AUDIT_FAIL:-false}" == "true" ]]; then
                for i in 1 2 3 4 5 6; do
                    cat > "$WORKSPACE/src/extra_${i}.py" <<XEOF
# extra file ${i} (audit violation mock)
def extra_${i}(): return ${i}
XEOF
                done
                git add -A 2>/dev/null
                git commit -m "feat: create too many files (audit test)" 2>/dev/null || true
                return 0
            fi

            # Write implementation
            cat > "$WORKSPACE/src/${focus_id}.py" <<CEOF
# ${focus_id} implementation (mock)
def ${focus_id//-/_}_main():
    """Main function for ${focus_id}."""
    return {"status": "ok", "feature": "${focus_id}"}
CEOF

            # Write test
            cat > "$WORKSPACE/tests/test_${focus_id}.py" <<TEOF
from src.${focus_id} import ${focus_id//-/_}_main

def test_${focus_id//-/_}():
    result = ${focus_id//-/_}_main()
    assert result["status"] == "ok"
    assert result["feature"] == "${focus_id}"
TEOF

            # Mark feature as done in FEATURES.md
            local focus_name
            focus_name=$(grep "in-progress" "$WORKSPACE/FEATURES.md" 2>/dev/null \
                | head -1 | sed 's/.*|\s*F-[0-9]*\s*|\s*\([^|]*\).*/\1/' | sed 's/^ *//;s/ *$//')
            sed -i "s/| ${focus_id} .*| in-progress/| ${focus_id} | ${focus_name} | P0       | done/" \
                "$WORKSPACE/FEATURES.md" 2>/dev/null || true

            # Update PROGRESS.md
            sed -i "s/## Status: IN_PROGRESS/## Status: IN_PROGRESS/" "$WORKSPACE/PROGRESS.md"

            git add -A 2>/dev/null
            git commit -m "feat(${focus_id}): implement ${focus_id} (mock)" 2>/dev/null || true
            return 0
            ;;

        TEST)
            # Mock is called during TEST only for fix attempts (test failure recovery)
            local fail_file="$WORKSPACE/.mock_test_fail_count"
            local current_fails=0
            [[ -f "$fail_file" ]] && current_fails=$(cat "$fail_file")
            local max_fails="${MOCK_TEST_FAIL_COUNT:-0}"

            if [[ $current_fails -lt $max_fails ]]; then
                # Simulate a failed fix attempt
                echo $((current_fails + 1)) > "$fail_file"
                log "INFO" "[MOCK] Fix attempt $((current_fails + 1))/$max_fails — still failing"
                return 0  # invoke_claude succeeds but test will still fail
            else
                # Simulate a successful fix
                rm -f "$fail_file"
                # Create a passing test script if one was broken
                if [[ -f "$WORKSPACE/.mock_test_should_fail" ]]; then
                    rm -f "$WORKSPACE/.mock_test_should_fail"
                fi
                log "INFO" "[MOCK] Fix applied — tests should pass now"
                return 0
            fi
            ;;

        INIT)
            # Job mode: create progress file
            cat > "$WORKSPACE/claude-progress.txt" <<IEOF
# Progress Log
## Task: ${TASK}
## Status: IN_PROGRESS

### Completed
_(none)_

### In Progress
- [ ] Initial implementation
IEOF
            return 0
            ;;

        *)
            # Unknown state — return success as no-op
            log "INFO" "[MOCK] No specific mock for state=$STATE, returning success"
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Cancellation check: read cancelled flag from job file
# ---------------------------------------------------------------------------
check_cancelled() {
    if [[ -f "$JOB_FILE" ]]; then
        local is_cancelled
        is_cancelled=$(jq -r '.cancelled // false' "$JOB_FILE" 2>/dev/null || echo "false")
        if [[ "$is_cancelled" == "true" ]]; then
            log "WARN" "Cancellation flag detected – stopping job"
            log_json "job_cancelled" "cancelled=true"
            return 1
        fi
    fi
    return 0
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
8. Do NOT commit \`claude-progress.txt\` or \`requirements.json\` - they are internal tracking files.
9. Stay focused on ONE subtask at a time.

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
    local role="${2:-}"   # SCAFFOLDED: prompt prefix only, no per-role tool allowlist or cost tracking yet

    # -----------------------------------------------------------------------
    # CLAUDE_MOCK mode: state-dependent mock that manipulates workspace files
    # like the real Claude would, enabling E2E testing without API calls.
    # -----------------------------------------------------------------------
    if [[ "${CLAUDE_MOCK:-false}" == "true" ]]; then
        log "INFO" "invoke_claude [MOCK] state=$STATE loop=$LOOP_COUNT"
        _mock_claude_response
        return $?
    fi

    local output_file
    output_file=$(mktemp)

    # Prepend role-specific prompt if provided
    # SCAFFOLDED: prompt prefix only — no per-role tool allowlist or cost tracking yet
    if [[ -n "$role" && -f "${HARNESS_DIR}/prompts/${role}.md" ]]; then
        local role_prefix
        role_prefix=$(cat "${HARNESS_DIR}/prompts/${role}.md")
        prompt="${role_prefix}

---

${prompt}"
        log "INFO" "Using role: $role"
        log_json "role_applied" "role=$role"
    fi

    # Build tool list
    local allowed_tools=(
        "Write" "Read" "Edit"
        # JavaScript / Node
        "Bash(git *)" "Bash(npm *)" "Bash(npm run *)" "Bash(npx *)" "Bash(node *)"
        "Bash(yarn *)" "Bash(pnpm *)"
        # Python
        "Bash(python *)" "Bash(python3 *)" "Bash(pytest *)"
        "Bash(pip *)" "Bash(pip3 *)" "Bash(uv *)"
        # Rust
        "Bash(cargo *)" "Bash(rustc *)"
        # Go
        "Bash(go *)"
        # Ruby
        "Bash(ruby *)" "Bash(bundle *)" "Bash(rake *)"
        # Java / Kotlin / Scala
        "Bash(mvn *)" "Bash(gradle *)" "Bash(java *)" "Bash(javac *)"
        # .NET / C#
        "Bash(dotnet *)"
        # Build systems
        "Bash(make *)" "Bash(cmake *)"
        # GitHub CLI
        "Bash(gh pr *)" "Bash(gh issue *)"
        # File / shell utilities
        "Bash(find *)" "Bash(cat *)" "Bash(ls *)" "Bash(grep *)"
        "Bash(mkdir *)" "Bash(cp *)" "Bash(mv *)"
        "Bash(cd *)" "Bash(pwd)" "Bash(echo *)"
        "Bash(chmod +x *)" "Bash(head *)" "Bash(tail *)"
        "Bash(wc *)" "Bash(sort *)" "Bash(diff *)"
        "Bash(touch *)" "Bash(rm *.tmp)" "Bash(rm *.log)"
        "Bash(sed *)" "Bash(tee *)" "Bash(xargs *)"
        "Bash(unzip *)" "Bash(tar *)" "Bash(curl *)" "Bash(wget *)"
    )

    # Build comma-separated tool list for --allowedTools
    local tools_csv
    tools_csv=$(IFS=','; echo "${allowed_tools[*]}")

    local claude_args=(
        -p
        --output-format json
        --model "${DEFAULT_MODEL:-claude-sonnet-4-6}"
        --allowedTools "$tools_csv"
    )

    # Resume conversation if we have a session ID
    if [[ -n "$CONVERSATION_ID" ]]; then
        claude_args+=(--resume "$CONVERSATION_ID")
    fi

    log "INFO" "Invoking Claude Code (model: ${DEFAULT_MODEL:-claude-sonnet-4-6}, session: ${CONVERSATION_ID:-new})"

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

    # Unset CLAUDECODE to allow nested invocation (e.g., when run-job.sh is
    # launched from within a Claude Code session for testing/development)
    unset CLAUDECODE 2>/dev/null || true

    # Pass prompt via stdin to avoid shell escaping issues with large/multiline prompts
    echo "$prompt" | timeout "${invoke_timeout}s" claude "${claude_args[@]}" \
        > "$output_file" 2>&1
    local exit_code=$?

    # On timeout (exit 124), reset conversation so the next attempt starts fresh.
    # Continuing a timed-out session can confuse Claude with incomplete context.
    if [[ $exit_code -eq 124 ]]; then
        log "WARN" "Claude timed out after ${invoke_timeout}s – resetting conversation ID"
        CONVERSATION_ID=""
    fi

    # Append raw output to job log
    cat "$output_file" >> "$JOB_LOG"

    # Try to extract session ID and cost from JSONL output (last line first)
    if [[ -f "$output_file" ]]; then
        local last_line
        last_line=$(tail -1 "$output_file" 2>/dev/null || true)

        local new_session_id
        new_session_id=$(echo "$last_line" | jq -r '.session_id // .conversation_id // empty' 2>/dev/null || true)
        if [[ -z "$new_session_id" ]]; then
            # Fallback: scan all lines for session_id
            new_session_id=$(jq -r '.session_id // .conversation_id // empty' "$output_file" 2>/dev/null \
                | grep -v '^$' | head -1 || true)
        fi
        if [[ -n "$new_session_id" ]]; then
            CONVERSATION_ID="$new_session_id"
            log "INFO" "Session ID: $CONVERSATION_ID"
        fi

        # Extract cost from last line first (most accurate for JSONL)
        local cost
        cost=$(echo "$last_line" | jq -r '.cost_usd // .usage.cost // empty' 2>/dev/null || true)
        if [[ -z "$cost" ]]; then
            # Fallback: scan all lines for cost
            cost=$(jq -r '.cost_usd // .usage.cost // empty' "$output_file" 2>/dev/null \
                | grep -v '^$' | tail -1 || true)
        fi
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

        # Protect agent-internal files from being accidentally committed
        {
            echo ""
            echo "# Agent-internal files (auto-added by agent harness)"
            echo "claude-progress.txt"
            echo "requirements.json"
        } >> "$WORKSPACE/.gitignore" 2>/dev/null || true

        LAST_COMMIT_HASH=$(git rev-parse HEAD)
        log_json "clone_success" "branch=$WORK_BRANCH commit=$LAST_COMMIT_HASH"
        if [[ "$MODE" == "product" ]]; then
            log_state_transition "CLONE" "SETUP"
            STATE="SETUP"
        else
            log_state_transition "CLONE" "SETUP"
            STATE="SETUP"
        fi
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
    local next_state="INIT"
    if [[ "$MODE" == "product" ]]; then
        next_state="SCAFFOLD"
    fi

    if [[ -z "$SETUP_CMDS" ]]; then
        log "INFO" "No setup commands defined, skipping"
        log_state_transition "SETUP" "$next_state"
        STATE="$next_state"
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
    log_state_transition "SETUP" "$next_state"
    STATE="$next_state"
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
        # Even without test commands, continue coding if subtasks remain
        if [[ $ITERATION -lt $MAX_ITERATIONS ]] && \
           [[ -f "$WORKSPACE/claude-progress.txt" ]] && \
           grep -q '^\- \[ \]' "$WORKSPACE/claude-progress.txt" 2>/dev/null && \
           check_time_budget; then
            log "INFO" "No test commands, but incomplete subtasks detected, returning to CODE"
            log_state_transition "TEST" "CODE" "no-tests-more-subtasks"
            STATE="CODE"
        else
            log "INFO" "No test commands defined, proceeding to PUSH"
            log_state_transition "TEST" "PUSH"
            STATE="PUSH"
        fi
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
        if bash -c "$cmd" 2>&1 | tee -a "$JOB_LOG" "$test_output_file"; then
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

        # If incomplete subtasks remain and budget allows, continue coding
        if [[ $ITERATION -lt $MAX_ITERATIONS ]] && \
           [[ -f "$WORKSPACE/claude-progress.txt" ]] && \
           grep -q '^\- \[ \]' "$WORKSPACE/claude-progress.txt" 2>/dev/null && \
           check_time_budget; then
            log "INFO" "Incomplete subtasks detected, returning to CODE phase"
            log_state_transition "TEST" "CODE" "more-subtasks"
            STATE="CODE"
        else
            log_state_transition "TEST" "PUSH"
            STATE="PUSH"
        fi
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

    # In mock mode, skip actual push/PR and go straight to DONE
    if [[ "${CLAUDE_MOCK:-false}" == "true" ]]; then
        log "INFO" "[MOCK] Skipping git push and PR creation"
        log_json "push_mock_skip" ""
        log_state_transition "PUSH" "DONE"
        STATE="DONE"
        return
    fi

    # If no remote exists (e.g. create_repo without GH_TOKEN), skip push gracefully
    if ! git -C "$WORKSPACE" remote get-url origin &>/dev/null; then
        log "INFO" "No remote 'origin' configured — skipping push (local-only repo)"
        log_json "push_skipped" "no_remote=true"
        log_state_transition "PUSH" "DONE"
        STATE="DONE"
        return
    fi

    # Ensure gh CLI is authenticated (GH_TOKEN env var is set in docker-compose)
    if ! gh auth status &>/dev/null; then
        log "WARN" "gh CLI not authenticated, attempting token login..."
        if [[ -n "${GH_TOKEN:-}" ]]; then
            echo "$GH_TOKEN" | gh auth login --with-token 2>/dev/null || true
        elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
            echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true
        fi
    fi
    # Configure git to use GitHub token for HTTPS push operations
    gh auth setup-git 2>/dev/null || true

    # Save agent artifact content for PR body before removing from repo
    local progress_for_pr=""
    if [[ "$MODE" == "product" ]]; then
        # In product mode, use PROGRESS.md and FEATURES.md (keep them in repo)
        if [[ -f "$WORKSPACE/PROGRESS.md" ]]; then
            progress_for_pr=$(cat "$WORKSPACE/PROGRESS.md")
        fi
    else
        if [[ -f "$WORKSPACE/claude-progress.txt" ]]; then
            progress_for_pr=$(cat "$WORKSPACE/claude-progress.txt")
        fi
    fi
    local approach_for_pr=""
    if [[ -f "$WORKSPACE/requirements.json" ]]; then
        approach_for_pr=$(jq -r '.approach // empty' "$WORKSPACE/requirements.json" 2>/dev/null || true)
    fi

    # Remove agent artifact files (not needed in repo) — job mode only
    if [[ "$MODE" != "product" ]]; then
        rm -f "$WORKSPACE/claude-progress.txt" "$WORKSPACE/requirements.json" 2>/dev/null
    fi

    # Ensure everything is committed
    if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
        git add -A 2>&1 | tee -a "$JOB_LOG"
        git commit -m "$(cat <<EOF
chore: auto-commit uncommitted changes before push

Job-ID: ${JOB_ID}
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
        # Truncate task for title (byte-safe for multibyte chars)
        local task_short
        task_short=$(echo "$TASK" | cut -c1-50)
        local pr_title="[Agent] ${task_short}"
        local elapsed=$(( $(date +%s) - JOB_START_TIME ))
        # Add "Closes #N" footer when job has an associated GitHub Issue
        local closes_line=""
        if [[ -n "$ISSUE_NUMBER" && -n "$ISSUE_REPO" ]]; then
            closes_line=$'\n\nCloses '"${ISSUE_REPO}#${ISSUE_NUMBER}"
        fi

        local mode_label="Autonomous Coding Agent"
        local iterations_label="$ITERATION"
        if [[ "$MODE" == "product" ]]; then
            mode_label="Product Forge (${PRODUCT_NAME})"
            iterations_label="$LOOP_COUNT loops"
        fi

        local pr_body
        pr_body=$(cat <<EOF
## Automated PR by ${mode_label}

| Field | Value |
|-------|-------|
| **Job ID** | \`${JOB_ID}\` |
| **Mode** | ${MODE} |
| **Iterations** | ${iterations_label} |
| **Commits** | ${commit_count} |
| **Duration** | $((elapsed / 60))m $((elapsed % 60))s |
| **Branch** | \`${WORK_BRANCH}\` |

### Task
${TASK}

### Progress
${progress_for_pr:-_No progress file found._}

### Implementation Notes
${approach_for_pr:-_No approach notes._}

---
_This PR was created automatically by the 24/7 ${mode_label}._
_Review carefully before merging._${closes_line}
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

            # Post comment on the linked GitHub Issue
            if [[ -n "$ISSUE_NUMBER" && -n "$ISSUE_REPO" ]]; then
                gh issue comment "$ISSUE_NUMBER" \
                    --repo "$ISSUE_REPO" \
                    --body "🤖 自律エージェントがこのIssueに対するPRを作成しました。

Job ID: \`${JOB_ID}\`" \
                    2>/dev/null || true
                log "INFO" "Posted comment on issue ${ISSUE_REPO}#${ISSUE_NUMBER}"
            fi
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
# Webhook delivery
# Reads HARNESS_DIR/config/webhooks.json and POSTs to matching registrations.
# Runs best-effort (failures are logged but don't affect job outcome).
# ---------------------------------------------------------------------------
fire_webhooks() {
    local event="$1"   # job_done | job_failed | job_start
    local webhooks_file="${HARNESS_DIR}/config/webhooks.json"

    [[ -f "$webhooks_file" ]] || return 0

    local hooks
    hooks=$(jq -c '.[]' "$webhooks_file" 2>/dev/null) || return 0

    local elapsed=$(( $(date +%s) - JOB_START_TIME ))
    local payload
    payload=$(jq -cn \
        --arg event "$event" \
        --arg job_id "$JOB_ID" \
        --arg repo "$REPO" \
        --arg task "$TASK" \
        --arg work_branch "$WORK_BRANCH" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson elapsed "$elapsed" \
        --argjson cost "${TOTAL_COST_USD:-0}" \
        '{
            event: $event,
            job_id: $job_id,
            repo: $repo,
            task: $task,
            work_branch: $work_branch,
            timestamp: $timestamp,
            elapsed_sec: $elapsed,
            cost_usd: $cost
        }' 2>/dev/null) || return 0

    while IFS= read -r hook; do
        [[ -z "$hook" ]] && continue
        local url events_json
        url=$(echo "$hook" | jq -r '.url // ""' 2>/dev/null)
        events_json=$(echo "$hook" | jq -r '.events // ["job_done","job_failed"] | .[]' 2>/dev/null)

        # Skip if URL is empty or event not in this hook's list
        [[ -z "$url" ]] && continue
        echo "$events_json" | grep -qxF "$event" || continue

        # Fire webhook (best-effort, no retry)
        if curl -sf --max-time 10 -X POST \
            "$url" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            > /dev/null 2>&1; then
            log "INFO" "Webhook delivered: event=$event url=$url"
        else
            log "WARN" "Webhook delivery failed: event=$event url=$url"
        fi
    done <<< "$hooks"
}

# ===========================================================================
# Product Mode States
# ===========================================================================

# ---------------------------------------------------------------------------
# State: SCAFFOLD — set up product state files in workspace
# ---------------------------------------------------------------------------
state_scaffold() {
    cd "$WORKSPACE"
    log "INFO" "Scaffolding product state files for: $PRODUCT_NAME"
    log_json "scaffold_start" "product=$PRODUCT_NAME"

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Copy template files
    if [[ -d "$TEMPLATES_DIR" ]]; then
        cp -r "$TEMPLATES_DIR/TASKS" "$WORKSPACE/" 2>/dev/null || true
        cp -r "$TEMPLATES_DIR/SPECS" "$WORKSPACE/" 2>/dev/null || true
        cp -r "$TEMPLATES_DIR/EVALS" "$WORKSPACE/" 2>/dev/null || true

        for f in AGENT.md PROGRESS.md FEATURES.md DECISIONS.md RUNBOOK.md PROGRAM.md init.sh; do
            if [[ -f "$TEMPLATES_DIR/$f" ]]; then
                sed -e "s|{{PRODUCT_NAME}}|$PRODUCT_NAME|g" \
                    -e "s|{{TIMESTAMP}}|$ts|g" \
                    -e "s|{{MAX_LOOPS}}|$MAX_LOOPS|g" \
                    -e "s|{{TIME_BUDGET}}|$TIME_BUDGET|g" \
                    "$TEMPLATES_DIR/$f" > "$WORKSPACE/$f"
            fi
        done
        chmod +x "$WORKSPACE/init.sh" 2>/dev/null || true
    fi

    # Protect product state files from .gitignore (they SHOULD be committed)
    # Remove agent-internal lines if present, then add product state tracking
    {
        echo ""
        echo "# Agent-internal files (auto-added by agent harness)"
        echo "requirements.json"
        echo "claude-progress.txt"
    } >> "$WORKSPACE/.gitignore" 2>/dev/null || true

    # Ask Claude to customize the scaffold for this specific product
    local scaffold_prompt
    scaffold_prompt=$(cat <<PROMPT
You are an autonomous coding agent in Product Mode. You are building: ${PRODUCT_NAME}

## Task
${TASK}

## Your Job Right Now
Customize the product scaffold files for this specific product:

1. Update FEATURES.md with a comprehensive feature list derived from the task description.
   - Use priorities: P0 (must-have), P1 (important), P2 (nice-to-have)
   - Start all features as "not-started"
   - Include at least 8-15 features

2. Update PROGRESS.md with the initial plan and first steps.

3. Update init.sh with the actual setup commands for this project type.
   - Detect the language/framework from the task description
   - Add appropriate dependency installation commands
   - Add health check commands if applicable

4. Update RUNBOOK.md with project-specific commands.

5. Create an initial DECISIONS.md entry (D-001) about the technology choices.

6. Do NOT start implementing features yet. Only set up the scaffold.

7. Commit all changes with: chore(scaffold): initialize product state for ${PRODUCT_NAME}
PROMPT
    )

    if invoke_claude "$scaffold_prompt"; then
        log "INFO" "Scaffold completed"
        log_json "scaffold_success" "product=$PRODUCT_NAME"
    else
        log "WARN" "Scaffold Claude invocation failed, using template defaults"
        log_json "scaffold_fallback" "using template defaults"
    fi

    # Ensure scaffold files are committed (Claude's commit may have been permission-denied)
    cd "$WORKSPACE"
    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "chore(scaffold): initialize product state for ${PRODUCT_NAME}" 2>/dev/null || true
        log "INFO" "Scaffold files committed by harness"
    fi

    LAST_COMMIT_HASH=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo "")
    log_state_transition "SCAFFOLD" "SYNC"
    STATE="SYNC"
}

# ---------------------------------------------------------------------------
# State: SYNC — pull latest changes (incorporates manual edits)
# ---------------------------------------------------------------------------
state_sync() {
    cd "$WORKSPACE"
    log "INFO" "Syncing with remote (loop $LOOP_COUNT)"
    log_json "sync_start" "loop=$LOOP_COUNT"

    # Pull with rebase to incorporate any manual changes
    if git pull --rebase origin "$WORK_BRANCH" 2>&1 | tee -a "$JOB_LOG"; then
        log "INFO" "Sync succeeded"
        log_json "sync_success" ""
    else
        # If pull fails (e.g., no remote tracking yet), that's OK
        log "INFO" "Sync skipped (no remote tracking or first push pending)"
        log_json "sync_skipped" "no remote tracking"
        git rebase --abort 2>/dev/null || true
    fi

    log_state_transition "SYNC" "INIT_SH"
    STATE="INIT_SH"
}

# ---------------------------------------------------------------------------
# State: INIT_SH — run init.sh to bootstrap the dev environment
# ---------------------------------------------------------------------------
state_init_sh() {
    cd "$WORKSPACE"
    log "INFO" "Running init.sh (loop $LOOP_COUNT)"
    log_json "init_sh_start" "loop=$LOOP_COUNT"

    if [[ -f "$WORKSPACE/init.sh" && -x "$WORKSPACE/init.sh" ]]; then
        if bash "$WORKSPACE/init.sh" 2>&1 | tee -a "$JOB_LOG"; then
            log "INFO" "init.sh completed successfully"
            log_json "init_sh_success" ""
        else
            log "WARN" "init.sh failed (non-fatal, continuing)"
            log_json "init_sh_failed" "non-fatal"
        fi
    else
        log "INFO" "No executable init.sh found, skipping"
        log_json "init_sh_skipped" ""
    fi

    log_state_transition "INIT_SH" "EVAL_BASELINE"
    STATE="EVAL_BASELINE"
}

# ---------------------------------------------------------------------------
# Shared: build product context block (used by PLAN and CODE)
# ---------------------------------------------------------------------------
build_product_context() {
    local progress_content="" features_content="" decisions_content="" program_content=""
    [[ -f "$WORKSPACE/PROGRESS.md" ]] && progress_content=$(cat "$WORKSPACE/PROGRESS.md")
    [[ -f "$WORKSPACE/FEATURES.md" ]] && features_content=$(cat "$WORKSPACE/FEATURES.md")
    [[ -f "$WORKSPACE/DECISIONS.md" ]] && decisions_content=$(tail -50 "$WORKSPACE/DECISIONS.md")
    [[ -f "$WORKSPACE/PROGRAM.md" ]] && program_content=$(cat "$WORKSPACE/PROGRAM.md")

    local evals_summary=""
    if [[ -d "$WORKSPACE/EVALS" ]]; then
        evals_summary=$(find "$WORKSPACE/EVALS" -name "*.json" -type f 2>/dev/null \
            | sort -r | head -5 \
            | xargs -I{} cat {} 2>/dev/null | head -100)
    fi

    local ledger_tail=""
    if [[ -f "$WORKSPACE/EVALS/ledger.jsonl" ]]; then
        ledger_tail=$(tail -10 "$WORKSPACE/EVALS/ledger.jsonl" 2>/dev/null || true)
    fi

    local git_log
    git_log=$(git -C "$WORKSPACE" log --oneline -10 2>/dev/null || echo "(no commits yet)")

    local elapsed=$(( $(date +%s) - JOB_START_TIME ))
    local remaining=$(( TIME_BUDGET - elapsed ))

    local day_context=""
    if [[ "$DAY_PLAN_JSON" != "null" && -n "$DAY_PLAN_JSON" ]]; then
        local day_info
        day_info=$(echo "$DAY_PLAN_JSON" | jq -r ".days[$CURRENT_DAY] // empty" 2>/dev/null)
        if [[ -n "$day_info" ]]; then
            day_context="## Current Day Plan (Day $CURRENT_DAY)
$(echo "$day_info" | jq -r '"Name: \(.name)\nGoals:\n" + (.goals // [] | map("- " + .) | join("\n")) + "\nQuality Gates:\n" + (.quality_gates // [] | map("- " + .) | join("\n"))' 2>/dev/null)"
        fi
    fi

    cat <<CTX
## Product: ${PRODUCT_NAME}
## Task: ${TASK}
## Loop: ${LOOP_COUNT} / ${MAX_LOOPS} | Time remaining: ${remaining}s
## Score Before: ${SCORE_BEFORE:-N/A} | Consecutive Discards: ${CONSECUTIVE_DISCARDS:-0}

${day_context}

## Program Definition
${program_content}

## Current Progress
${progress_content}

## Feature Tracker
${features_content}

## Decision Log (recent)
${decisions_content}

## Recent Eval Results
${evals_summary}

## Experiment Ledger (last 10)
${ledger_tail}

## Recent Git History
\`\`\`
${git_log}
\`\`\`

## Test Commands
$(echo "$TEST_CMDS" | sed 's/^/- /' || echo "- (none specified)")
CTX
}

# ---------------------------------------------------------------------------
# State: EVAL_BASELINE — capture pre-code score and commit hash
# ---------------------------------------------------------------------------
state_eval_baseline() {
    cd "$WORKSPACE"
    log "INFO" "EVAL_BASELINE: capturing baseline score (loop $LOOP_COUNT)"
    log_json "eval_baseline_start" "loop=$LOOP_COUNT"

    LOOP_START_TIME=$(date +%s)

    # Read stop condition params from PROGRAM.md if available
    if [[ -f "$WORKSPACE/PROGRAM.md" ]]; then
        local md_val
        md_val=$(grep -E 'max_discards_in_a_row:' "$WORKSPACE/PROGRAM.md" 2>/dev/null \
            | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$md_val" && "$md_val" =~ ^[0-9]+$ ]] && MAX_CONSECUTIVE_DISCARDS="$md_val"

        md_val=$(grep -E 'target_score:' "$WORKSPACE/PROGRAM.md" 2>/dev/null \
            | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$md_val" ]] && TARGET_SCORE="$md_val"

        md_val=$(grep -E 'min_improvement_delta:' "$WORKSPACE/PROGRAM.md" 2>/dev/null \
            | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$md_val" ]] && MIN_IMPROVEMENT_DELTA="$md_val"

        md_val=$(grep -E 'max_plateau_loops:' "$WORKSPACE/PROGRAM.md" 2>/dev/null \
            | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$md_val" && "$md_val" =~ ^[0-9]+$ ]] && MAX_PLATEAU_LOOPS="$md_val"

        log "INFO" "EVAL_BASELINE: params from PROGRAM.md: target_score=$TARGET_SCORE min_delta=$MIN_IMPROVEMENT_DELTA max_plateau=$MAX_PLATEAU_LOOPS max_discards=$MAX_CONSECUTIVE_DISCARDS"
    fi

    if [[ "${CLAUDE_MOCK:-false}" == "true" ]]; then
        SCORE_BEFORE="${MOCK_SCORE_BEFORE:-0.5000}"
        log "INFO" "[MOCK] SCORE_BEFORE=$SCORE_BEFORE"
    else
        # Run evals to get baseline results
        bash "${SCRIPTS_DIR}/run-evals.sh" "$WORKSPACE" 2>&1 | tee -a "$JOB_LOG" || true
        SCORE_BEFORE=$(bash "${SCRIPTS_DIR}/run-evals.sh" "$WORKSPACE" --score 2>/dev/null || echo "0.0000")

        # Commit EVALS baseline files so they're excluded from CODE diff
        # (PRE_CODE_COMMIT is captured at the start of CODE state, after this commit)
        git add EVALS/ 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "chore(eval-baseline): capture baseline evals (loop $LOOP_COUNT)" 2>/dev/null || true
            LAST_COMMIT_HASH=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo "")
        fi
    fi

    log "INFO" "EVAL_BASELINE: SCORE_BEFORE=$SCORE_BEFORE"
    log_json "eval_baseline_done" "score_before=$SCORE_BEFORE"

    log_state_transition "EVAL_BASELINE" "PLAN"
    STATE="PLAN"
}

# ---------------------------------------------------------------------------
# State: PLAN — select next task ONLY; do not implement
# ---------------------------------------------------------------------------
state_plan() {
    cd "$WORKSPACE"
    LOOP_COUNT=$((LOOP_COUNT + 1))
    log "INFO" "PLAN: selecting next task (loop $LOOP_COUNT / $MAX_LOOPS)"
    log_json "plan_start" "loop=$LOOP_COUNT"

    if ! check_time_budget; then
        log "WARN" "Time budget exceeded during PLAN"
        STATE="PUSH"
        return
    fi

    local context
    context=$(build_product_context)

    local plan_prompt
    plan_prompt=$(cat <<PROMPT
You are the **Planner** for Product Forge (Autoresearch Mode).

${context}

## Your ONLY job right now

1. Read PROGRAM.md for mutation scope, eval weights, and stop conditions.
2. Read FEATURES.md, recent eval results, and the experiment ledger.
3. Formulate exactly ONE hypothesis to test next:
   - Source from: not-started features (P0 first), regressions, eval failures, coverage gaps
   - Each hypothesis = a single, testable mutation within PROGRAM.md caps
4. Update PROGRESS.md — set "### Hypothesis" to describe:
   - Which feature (by ID, e.g. F-003) or quality improvement
   - The hypothesis: "If we <change>, then <expected improvement>"
   - Expected score delta (e.g. +0.05)
   - Affected files (max per PROGRAM.md caps)
   - Rollback rule: what to revert if score doesn't improve
5. Mark that feature as "in-progress" in FEATURES.md (if feature-based).

## Rules
- Do NOT write code. Do NOT write tests. Do NOT run commands.
- Only update PROGRESS.md and FEATURES.md.
- If all features are done, write "ALL FEATURES COMPLETE" in PROGRESS.md.
PROMPT
    )

    if invoke_claude "$plan_prompt"; then
        log "INFO" "PLAN completed (loop $LOOP_COUNT)"
        log_json "plan_done" "loop=$LOOP_COUNT"

        # Check if all features are done
        if [[ -f "$WORKSPACE/PROGRESS.md" ]] && \
           grep -qi "ALL FEATURES COMPLETE" "$WORKSPACE/PROGRESS.md" 2>/dev/null; then
            log "INFO" "Planner says all features complete"
            STATE="PUSH"
        else
            log_state_transition "PLAN" "CODE"
            STATE="CODE"
        fi
    else
        local exit_code=$?
        log "ERROR" "PLAN: Claude exited with code $exit_code"
        log_json "plan_error" "exit_code=$exit_code loop=$LOOP_COUNT"
        if ! track_error "plan_error_$exit_code"; then
            STATE="FAILED"
            return
        fi
        # Retry plan
        STATE="PLAN"
    fi
}

# ---------------------------------------------------------------------------
# State: CODE (product mode) — implement the selected task ONLY
# ---------------------------------------------------------------------------
state_product_code() {
    cd "$WORKSPACE"
    log "INFO" "CODE: implementing selected task (loop $LOOP_COUNT)"
    log_json "product_code_start" "loop=$LOOP_COUNT"

    # Capture pre-code commit AFTER plan (so audit only checks CODE changes)
    PRE_CODE_COMMIT=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo "")
    log "INFO" "PRE_CODE_COMMIT=$PRE_CODE_COMMIT"

    if ! check_time_budget; then
        STATE="PUSH"
        return
    fi

    local context
    context=$(build_product_context)

    # Read mutation caps from PROGRAM.md for prompt reinforcement
    local cap_files_changed=3 cap_files_created=2 cap_diff_lines=250
    if [[ -f "$WORKSPACE/PROGRAM.md" ]]; then
        local v
        v=$(grep -E 'Max files changed per loop:' "$WORKSPACE/PROGRAM.md" 2>/dev/null | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$v" && "$v" =~ ^[0-9]+$ ]] && cap_files_changed="$v"
        v=$(grep -E 'Max files created per loop:' "$WORKSPACE/PROGRAM.md" 2>/dev/null | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$v" && "$v" =~ ^[0-9]+$ ]] && cap_files_created="$v"
        v=$(grep -E 'Max diff lines per loop:' "$WORKSPACE/PROGRAM.md" 2>/dev/null | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$v" && "$v" =~ ^[0-9]+$ ]] && cap_diff_lines="$v"
    fi

    local code_prompt
    code_prompt=$(cat <<PROMPT
You are the **Implementer** for Product Forge (Autoresearch Mode).

${context}

## Your ONLY job right now

1. Read PROGRESS.md → "### Hypothesis" tells you what to implement.
2. Implement ONLY the hypothesis:
   - Write production code
   - Follow existing patterns and conventions
   - Handle edge cases
3. Also write tests for the new code.
4. Run the test commands to verify your changes work.
5. If tests pass, commit with: \`<type>(<scope>): <description>\`
6. If tests fail, debug and fix (max 3 attempts).
   If still failing after 3 attempts, do NOT commit. Leave the code as-is.

## HARD MUTATION CAPS (enforced by CODE_AUDIT — violations = auto-discard)
- Max files changed: ${cap_files_changed}
- Max files created: ${cap_files_created}
- Max diff lines (insertions + deletions): ${cap_diff_lines}
- Stay WITHIN these limits or your changes WILL be rolled back.

## Rules
- Implement ONLY the hypothesis described in "### Hypothesis"
- Do NOT pick a different task or implement multiple features
- Do NOT push to remote
- Do NOT modify .git/config or PROGRAM.md
- After committing, update FEATURES.md status and PROGRESS.md
- Log any architectural decisions in DECISIONS.md
PROMPT
    )

    if invoke_claude "$code_prompt"; then
        log "INFO" "CODE completed (loop $LOOP_COUNT)"
        log_json "product_code_done" "loop=$LOOP_COUNT"
    else
        local exit_code=$?
        log "ERROR" "CODE: Claude exited with code $exit_code"
        log_json "product_code_error" "exit_code=$exit_code loop=$LOOP_COUNT"
        if ! track_error "code_error_$exit_code"; then
            STATE="FAILED"
            return
        fi
    fi

    # Ensure code changes are committed (Claude's commit may have been permission-denied)
    cd "$WORKSPACE"
    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "feat(loop-$LOOP_COUNT): implement hypothesis" 2>/dev/null || true
        log "INFO" "CODE changes committed by harness"
    fi

    log_state_transition "CODE" "CODE_AUDIT"
    STATE="CODE_AUDIT"
}

# ---------------------------------------------------------------------------
# State: PRODUCT_TEST — run tests in product mode
# ---------------------------------------------------------------------------
state_product_test() {
    cd "$WORKSPACE"
    log "INFO" "Running tests (product mode, loop $LOOP_COUNT)"
    log_json "product_test_start" "loop=$LOOP_COUNT"

    if [[ -z "$TEST_CMDS" ]]; then
        log "INFO" "No test commands defined, computing score and proceeding to JUDGE"
        if [[ "${CLAUDE_MOCK:-false}" == "true" ]]; then
            SCORE_AFTER="${MOCK_SCORE_AFTER:-0.6000}"
        else
            SCORE_AFTER=$(bash "${SCRIPTS_DIR}/run-evals.sh" "$WORKSPACE" --score 2>/dev/null || echo "0.0000")
        fi
        log_state_transition "TEST" "JUDGE"
        STATE="JUDGE"
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
        if bash -c "$cmd" 2>&1 | tee -a "$JOB_LOG" "$test_output_file"; then
            log "INFO" "Test passed: $cmd"
        else
            log "WARN" "Test failed: $cmd"
            all_passed=false
        fi
    done <<< "$TEST_CMDS"

    test_output=$(tail -200 "$test_output_file")
    rm -f "$test_output_file"

    if [[ "$all_passed" == "true" ]]; then
        log "INFO" "All tests passed (loop $LOOP_COUNT)"
        log_json "product_test_passed" "loop=$LOOP_COUNT"

        # Compute post-code score
        if [[ "${CLAUDE_MOCK:-false}" == "true" ]]; then
            if [[ "${MOCK_SCORE_REGRESS:-false}" == "true" ]]; then
                SCORE_AFTER="${MOCK_SCORE_AFTER:-0.3000}"
            else
                SCORE_AFTER="${MOCK_SCORE_AFTER:-0.6000}"
            fi
        else
            bash "${SCRIPTS_DIR}/run-evals.sh" "$WORKSPACE" 2>&1 | tee -a "$JOB_LOG" || true
            SCORE_AFTER=$(bash "${SCRIPTS_DIR}/run-evals.sh" "$WORKSPACE" --score 2>/dev/null || echo "0.0000")
        fi
        log "INFO" "SCORE_AFTER=$SCORE_AFTER"
        log_json "score_after" "score=$SCORE_AFTER"

        log_state_transition "TEST" "JUDGE"
        STATE="JUDGE"
    else
        log_json "product_test_failed" "loop=$LOOP_COUNT"

        if ! check_time_budget; then
            STATE="PUSH"
            return
        fi

        # Invoke fix agent
        local fix_prompt
        fix_prompt=$(build_fix_prompt "$test_output")

        if invoke_claude "$fix_prompt"; then
            log "INFO" "Fix attempt completed, re-running tests"
            STATE="TEST"
        else
            log "WARN" "Fix agent failed, proceeding to JUDGE with discard"
            JUDGE_VERDICT="discard_test_fail"
            STATE="LEDGER"
        fi
    fi
}

# ---------------------------------------------------------------------------
# State: CODE_AUDIT — verify code changes stay within mutation caps (no Claude)
# ---------------------------------------------------------------------------
state_code_audit() {
    cd "$WORKSPACE"
    log "INFO" "CODE_AUDIT: checking mutation caps (loop $LOOP_COUNT)"
    log_json "code_audit_start" "loop=$LOOP_COUNT"

    # Read caps from PROGRAM.md (defaults if not found)
    local max_files_changed=3 max_files_created=2 max_diff_lines=250 max_endpoint_changes=1
    if [[ -f "$WORKSPACE/PROGRAM.md" ]]; then
        local val
        val=$(grep -E 'Max files changed per loop:' "$WORKSPACE/PROGRAM.md" 2>/dev/null | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$val" && "$val" =~ ^[0-9]+$ ]] && max_files_changed="$val"
        val=$(grep -E 'Max files created per loop:' "$WORKSPACE/PROGRAM.md" 2>/dev/null | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$val" && "$val" =~ ^[0-9]+$ ]] && max_files_created="$val"
        val=$(grep -E 'Max diff lines per loop:' "$WORKSPACE/PROGRAM.md" 2>/dev/null | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$val" && "$val" =~ ^[0-9]+$ ]] && max_diff_lines="$val"
        val=$(grep -E 'Max endpoint/route changes per loop:' "$WORKSPACE/PROGRAM.md" 2>/dev/null | awk -F: '{gsub(/[ \t]/,"",$2); print $2}' | head -1)
        [[ -n "$val" && "$val" =~ ^[0-9]+$ ]] && max_endpoint_changes="$val"
    fi

    local violation=""

    local changed_files=0 new_files=0 diff_lines=0

    if [[ -n "$PRE_CODE_COMMIT" ]]; then
        # Count changed code files (exclude state/harness files and EVALS/ from cap check)
        changed_files=$(git -C "$WORKSPACE" diff --name-only "$PRE_CODE_COMMIT"..HEAD 2>/dev/null \
            | { grep -v -E '^(PROGRESS\.md|FEATURES\.md|DECISIONS\.md|AGENT\.md|PROGRAM\.md|RUNBOOK\.md|EVALS/.*)$' || true; } \
            | wc -l | tr -d ' ')
        if [[ "$changed_files" -gt "$max_files_changed" ]]; then
            violation="files_changed=$changed_files > max=$max_files_changed"
        fi

        # Count newly created code files (exclude state files and EVALS/)
        new_files=$(git -C "$WORKSPACE" diff --diff-filter=A --name-only "$PRE_CODE_COMMIT"..HEAD 2>/dev/null \
            | { grep -v -E '^(PROGRESS\.md|FEATURES\.md|DECISIONS\.md|AGENT\.md|PROGRAM\.md|RUNBOOK\.md|EVALS/.*)$' || true; } \
            | wc -l | tr -d ' ')
        if [[ -z "$violation" && "$new_files" -gt "$max_files_created" ]]; then
            violation="files_created=$new_files > max=$max_files_created"
        fi

        # Count diff lines (all files, since line count reflects total mutation size)
        diff_lines=$(git -C "$WORKSPACE" diff --stat "$PRE_CODE_COMMIT"..HEAD 2>/dev/null | tail -1 | awk '{print $4+$6}')
        diff_lines="${diff_lines:-0}"
        if [[ -z "$violation" && "$diff_lines" -gt "$max_diff_lines" ]]; then
            violation="diff_lines=$diff_lines > max=$max_diff_lines"
        fi
    fi

    if [[ -n "$violation" ]]; then
        log "WARN" "CODE_AUDIT: cap violation — $violation"
        log_json "code_audit_violation" "$violation"
        # Rollback
        if [[ -n "$PRE_CODE_COMMIT" ]]; then
            git -C "$WORKSPACE" reset --hard "$PRE_CODE_COMMIT" 2>&1 | tee -a "$JOB_LOG" || true
            log "INFO" "CODE_AUDIT: rolled back to $PRE_CODE_COMMIT"
        fi
        JUDGE_VERDICT="discard_audit"
        CONSECUTIVE_DISCARDS=$((CONSECUTIVE_DISCARDS + 1))
        log_state_transition "CODE_AUDIT" "LEDGER"
        STATE="LEDGER"
    else
        log "INFO" "CODE_AUDIT: all caps OK"
        log_json "code_audit_passed" "changed=$changed_files new=$new_files diff=$diff_lines"
        log_state_transition "CODE_AUDIT" "TEST"
        STATE="TEST"
    fi
}

# ---------------------------------------------------------------------------
# State: JUDGE — compare SCORE_AFTER vs SCORE_BEFORE → keep or discard
# ---------------------------------------------------------------------------
state_judge() {
    cd "$WORKSPACE"
    log "INFO" "JUDGE: comparing scores (before=$SCORE_BEFORE after=$SCORE_AFTER)"
    log_json "judge_start" "score_before=$SCORE_BEFORE score_after=$SCORE_AFTER"

    local keep
    keep=$(awk "BEGIN { print ($SCORE_AFTER > $SCORE_BEFORE) ? 1 : 0 }")

    if [[ "$keep" -eq 1 ]]; then
        log "INFO" "JUDGE: KEEP — score improved ($SCORE_BEFORE → $SCORE_AFTER)"
        log_json "judge_keep" "before=$SCORE_BEFORE after=$SCORE_AFTER"
        JUDGE_VERDICT="keep"
        CONSECUTIVE_DISCARDS=0
        LAST_COMMIT_HASH=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo "")
    else
        log "WARN" "JUDGE: DISCARD — score did not improve ($SCORE_BEFORE → $SCORE_AFTER)"
        log_json "judge_discard" "before=$SCORE_BEFORE after=$SCORE_AFTER"
        JUDGE_VERDICT="discard_regression"
        CONSECUTIVE_DISCARDS=$((CONSECUTIVE_DISCARDS + 1))
        # Rollback to pre-code commit
        if [[ -n "$PRE_CODE_COMMIT" ]]; then
            git -C "$WORKSPACE" reset --hard "$PRE_CODE_COMMIT" 2>&1 | tee -a "$JOB_LOG" || true
            log "INFO" "JUDGE: rolled back to $PRE_CODE_COMMIT"
        fi
    fi

    # Track plateau: consecutive loops where score improvement < min_improvement_delta
    # Skip plateau tracking for discard_audit (CODE didn't run, scores unchanged)
    if [[ "$JUDGE_VERDICT" != "discard_audit" ]]; then
        local is_plateau
        is_plateau=$(awk "BEGIN {
            diff = $SCORE_AFTER - $SCORE_BEFORE
            if (diff < 0) diff = -diff
            print (diff < $MIN_IMPROVEMENT_DELTA) ? 1 : 0
        }")
        if [[ "$is_plateau" -eq 1 ]]; then
            PLATEAU_COUNT=$((PLATEAU_COUNT + 1))
            log "INFO" "JUDGE: improvement below min_delta=$MIN_IMPROVEMENT_DELTA (plateau_count=$PLATEAU_COUNT/$MAX_PLATEAU_LOOPS)"
        else
            PLATEAU_COUNT=0
            log "INFO" "JUDGE: improvement OK (plateau_count reset to 0)"
        fi
        log_json "judge_plateau" "plateau_count=$PLATEAU_COUNT max_plateau=$MAX_PLATEAU_LOOPS min_delta=$MIN_IMPROVEMENT_DELTA"
    fi

    log_state_transition "JUDGE" "LEDGER"
    STATE="LEDGER"
}

# ---------------------------------------------------------------------------
# State: LEDGER — append experiment record to EVALS/ledger.jsonl
# ---------------------------------------------------------------------------
state_ledger() {
    cd "$WORKSPACE"
    log "INFO" "LEDGER: recording experiment (verdict=$JUDGE_VERDICT)"
    log_json "ledger_write" "verdict=$JUDGE_VERDICT"

    local ledger_file="$WORKSPACE/EVALS/ledger.jsonl"
    mkdir -p "$WORKSPACE/EVALS"

    # Extract hypothesis from PROGRESS.md
    local hypothesis=""
    if [[ -f "$WORKSPACE/PROGRESS.md" ]]; then
        hypothesis=$(sed -n '/^### Hypothesis/,/^### /p' "$WORKSPACE/PROGRESS.md" 2>/dev/null \
            | grep -v '^### ' | head -5 | tr '\n' ' ' | head -c 200)
    fi

    # Compute wall seconds for this loop
    local wall_seconds=0
    if [[ -n "$LOOP_START_TIME" ]]; then
        wall_seconds=$(( $(date +%s) - LOOP_START_TIME ))
    fi

    # Files touched
    local files_touched=""
    if [[ -n "$PRE_CODE_COMMIT" ]]; then
        files_touched=$(git -C "$WORKSPACE" diff --name-only "$PRE_CODE_COMMIT"..HEAD 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    fi

    local current_sha
    current_sha=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo "")

    local kept=false
    [[ "$JUDGE_VERDICT" == "keep" ]] && kept=true

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    jq -cn \
        --argjson loop "$LOOP_COUNT" \
        --arg hypothesis "$hypothesis" \
        --arg files_touched "$files_touched" \
        --argjson wall_seconds "$wall_seconds" \
        --arg score_before "${SCORE_BEFORE:-0}" \
        --arg score_after "${SCORE_AFTER:-0}" \
        --argjson kept "$kept" \
        --arg commit_sha "$current_sha" \
        --arg timestamp "$ts" \
        --arg verdict "$JUDGE_VERDICT" \
        '{loop:$loop, hypothesis:$hypothesis, files_touched:$files_touched, wall_seconds:$wall_seconds, score_before:$score_before, score_after:$score_after, kept:$kept, commit_sha:$commit_sha, timestamp:$timestamp, verdict:$verdict}' \
        >> "$ledger_file" 2>/dev/null || log "WARN" "Failed to write ledger entry"

    log "INFO" "LEDGER: entry written to $ledger_file"
    log_json "ledger_done" "verdict=$JUDGE_VERDICT kept=$kept"

    # Reset stall detector after any loop (discard is intentional, not a stall)
    # Next loop's EVAL_BASELINE will commit new EVALS → HEAD will change → stall resets
    LAST_COMMIT_HASH=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo "")
    NO_PROGRESS_COUNT=0

    log_state_transition "LEDGER" "LOOP_CHECK"
    STATE="LOOP_CHECK"
}

# ---------------------------------------------------------------------------
# State: LOOP_CHECK — decide whether to continue, advance day, or finish
# ---------------------------------------------------------------------------
state_loop_check() {
    cd "$WORKSPACE"
    log "INFO" "Loop check (loop $LOOP_COUNT / $MAX_LOOPS, day $CURRENT_DAY)"
    log_json "loop_check" "loop=$LOOP_COUNT max=$MAX_LOOPS day=$CURRENT_DAY"

    # Check cancellation
    if ! check_cancelled; then
        STATE="FAILED"
        return
    fi

    # Check time budget
    if ! check_time_budget; then
        log "WARN" "Time budget exceeded at loop $LOOP_COUNT"
        STATE="PUSH"
        return
    fi

    # Check loop limit
    if [[ $LOOP_COUNT -ge $MAX_LOOPS ]]; then
        log "INFO" "Max loops ($MAX_LOOPS) reached"
        log_json "max_loops_reached" "loop=$LOOP_COUNT"
        STATE="PUSH"
        return
    fi

    # Target score reached — success stop
    if [[ -n "$SCORE_AFTER" ]]; then
        local target_reached
        target_reached=$(awk "BEGIN { print ($SCORE_AFTER >= $TARGET_SCORE) ? 1 : 0 }")
        if [[ "$target_reached" -eq 1 ]]; then
            log "INFO" "Target score reached ($SCORE_AFTER >= $TARGET_SCORE) — stopping"
            log_json "target_score_reached" "score=$SCORE_AFTER target=$TARGET_SCORE"
            STATE="PUSH"
            return
        fi
    fi

    # Plateau detection — score improvement stalled for too many loops
    if [[ $PLATEAU_COUNT -ge $MAX_PLATEAU_LOOPS ]]; then
        log "INFO" "Plateau stop: no improvement for $PLATEAU_COUNT loops (min_delta=$MIN_IMPROVEMENT_DELTA)"
        log_json "plateau_stop" "plateau_count=$PLATEAU_COUNT max=$MAX_PLATEAU_LOOPS min_delta=$MIN_IMPROVEMENT_DELTA score=$SCORE_AFTER"
        STATE="PUSH"
        return
    fi

    # Consecutive discard limit (safety net)
    if [[ $CONSECUTIVE_DISCARDS -ge $MAX_CONSECUTIVE_DISCARDS ]]; then
        log "WARN" "Consecutive discard limit reached ($CONSECUTIVE_DISCARDS >= $MAX_CONSECUTIVE_DISCARDS)"
        log_json "consecutive_discard_stop" "discards=$CONSECUTIVE_DISCARDS max=$MAX_CONSECUTIVE_DISCARDS"
        STATE="PUSH"
        return
    fi

    # Stall detection
    if ! check_progress; then
        log "WARN" "Stall detected in product mode, pushing partial results"
        STATE="PUSH"
        return
    fi

    # Check if all features are done
    if [[ -f "$WORKSPACE/FEATURES.md" ]]; then
        local remaining_features
        remaining_features=$(grep -c 'not-started\|in-progress' "$WORKSPACE/FEATURES.md" 2>/dev/null || echo "0")
        if [[ "$remaining_features" -eq 0 ]]; then
            log "INFO" "All features completed!"
            log_json "all_features_done" "loop=$LOOP_COUNT"
            STATE="PUSH"
            return
        fi
    fi

    # Day boundary check (if day plan exists)
    if [[ "$DAY_PLAN_JSON" != "null" && -n "$DAY_PLAN_JSON" ]]; then
        local day_max_loops
        day_max_loops=$(echo "$DAY_PLAN_JSON" | jq -r ".days[$CURRENT_DAY].max_loops // 999999" 2>/dev/null)

        # Count loops in current day (approximate: track from day start)
        # For simplicity, check if we've exceeded the day's loop budget
        local day_loops_file="$WORKSPACE/.day_loop_count"
        local day_loop_count=0
        if [[ -f "$day_loops_file" ]]; then
            day_loop_count=$(cat "$day_loops_file" 2>/dev/null || echo "0")
        fi
        day_loop_count=$((day_loop_count + 1))
        echo "$day_loop_count" > "$day_loops_file"

        if [[ $day_loop_count -ge $day_max_loops ]]; then
            # Advance to next day
            local next_day=$((CURRENT_DAY + 1))
            local total_days
            total_days=$(echo "$DAY_PLAN_JSON" | jq -r '.days | length' 2>/dev/null)

            if [[ $next_day -lt $total_days ]]; then
                log "INFO" "Day $CURRENT_DAY complete. Advancing to Day $next_day"
                log_json "day_transition" "from=$CURRENT_DAY to=$next_day"
                CURRENT_DAY=$next_day
                echo "0" > "$day_loops_file"

                # Update PROGRESS.md with day transition
                if [[ -f "$WORKSPACE/PROGRESS.md" ]]; then
                    sed -i "s/## Day: .*/## Day: $CURRENT_DAY/" "$WORKSPACE/PROGRESS.md" 2>/dev/null || true
                fi
            else
                log "INFO" "All days completed (day $CURRENT_DAY was the last)"
                log_json "all_days_done" "final_day=$CURRENT_DAY"
                STATE="PUSH"
                return
            fi
        fi
    fi

    # Continue to next loop iteration
    log_state_transition "LOOP_CHECK" "SYNC" "continuing"
    STATE="SYNC"
}

# ---------------------------------------------------------------------------
# Create new repository (for --create-repo mode)
# ---------------------------------------------------------------------------
state_create_repo() {
    log "INFO" "Creating new repository for product: $PRODUCT_NAME"
    log_json "create_repo_start" "product=$PRODUCT_NAME"

    mkdir -p "$WORKSPACE"
    cd "$WORKSPACE"

    git init 2>&1 | tee -a "$JOB_LOG"
    git config user.name "Autonomous Agent" 2>/dev/null
    git config user.email "agent@autonomous-coding-agent.local" 2>/dev/null

    # Create initial README
    cat > "$WORKSPACE/README.md" <<EOF
# ${PRODUCT_NAME}

> Built by Product Forge - Autonomous Coding Agent

## Description
${TASK}

## Getting Started
See RUNBOOK.md for setup and deployment instructions.
EOF

    # Create .gitignore
    cat > "$WORKSPACE/.gitignore" <<EOF
node_modules/
__pycache__/
.venv/
*.pyc
.env
.env.local
dist/
build/
coverage/
.DS_Store
*.log
EOF

    git add -A
    git commit -m "chore: initial repository setup for ${PRODUCT_NAME}" 2>&1 | tee -a "$JOB_LOG"
    git checkout -b "$WORK_BRANCH" 2>/dev/null || true

    # If gh CLI is available and GH_TOKEN set, create remote repo
    if command -v gh &>/dev/null && [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
        local repo_slug
        repo_slug=$(echo "$PRODUCT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
        if gh repo create "$repo_slug" --private --source=. --push 2>&1 | tee -a "$JOB_LOG"; then
            log "INFO" "Remote repository created: $repo_slug"
            log_json "remote_repo_created" "slug=$repo_slug"
            REPO="https://github.com/$(gh api user -q .login 2>/dev/null || echo 'unknown')/$repo_slug"
        else
            log "WARN" "Failed to create remote repo (continuing with local-only)"
            log_json "remote_repo_failed" "continuing local"
        fi
    fi

    # Copy CLAUDE.md into workspace
    if [[ ! -f "$WORKSPACE/CLAUDE.md" ]]; then
        cp "${HARNESS_DIR}/CLAUDE.md" "$WORKSPACE/CLAUDE.md" 2>/dev/null || true
    fi

    LAST_COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "")
    log_json "create_repo_success" "workspace=$WORKSPACE"
    log_state_transition "CREATE_REPO" "SETUP"
    STATE="SETUP"
}

# ---------------------------------------------------------------------------
# Cleanup workspace
# ---------------------------------------------------------------------------
cleanup() {
    local elapsed=$(( $(date +%s) - JOB_START_TIME ))
    log "INFO" "Job cleanup: duration=${elapsed}s iterations=${ITERATION} cost=\$${TOTAL_COST_USD}"
    log_json "cleanup" "duration=${elapsed}s iterations=${ITERATION} cost=${TOTAL_COST_USD}"

    if [[ -d "$WORKSPACE" ]]; then
        if [[ "${CLAUDE_MOCK:-false}" == "true" || "${PRESERVE_WORKSPACE:-false}" == "true" ]]; then
            log "INFO" "Preserving workspace for inspection: $WORKSPACE"
        else
            log "INFO" "Removing workspace: $WORKSPACE"
            rm -rf "$WORKSPACE"
        fi
    fi
    rm -f "$ERROR_COUNTS_FILE"
}

# =============================================================================
# Main State Machine
# =============================================================================
main() {
    log "INFO" "=========================================="
    log "INFO" "Job started: $JOB_ID"
    log "INFO" "Mode: $MODE"
    log "INFO" "Repo: $REPO"
    log "INFO" "Branch: $BASE_REF -> $WORK_BRANCH"
    log "INFO" "Task: $TASK"
    log "INFO" "Time budget: ${TIME_BUDGET}s"
    log "INFO" "GPU required: $GPU_REQUIRED"
    if [[ "$MODE" == "product" ]]; then
        log "INFO" "Product: $PRODUCT_NAME"
        log "INFO" "Max loops: $MAX_LOOPS"
        log "INFO" "Create repo: $CREATE_REPO"
    fi
    log "INFO" "=========================================="
    log_json "job_start" "repo=$REPO task=$TASK budget=${TIME_BUDGET}s mode=$MODE"
    fire_webhooks "job_start" || true

    # Product mode: use CREATE_REPO state instead of CLONE if --create-repo
    if [[ "$MODE" == "product" && "$CREATE_REPO" == "true" ]]; then
        STATE="CREATE_REPO"
    fi

    # Write agent PID into the job file so cancel-job.sh / dashboard can signal us
    if [[ -f "$JOB_FILE" ]]; then
        jq --argjson pid $$ '. + {agent_pid: $pid}' "$JOB_FILE" > "$JOB_FILE.tmp" \
            && mv "$JOB_FILE.tmp" "$JOB_FILE" 2>/dev/null || true
    fi

    trap cleanup EXIT

    while true; do
        # Check for user-initiated cancellation on each state transition
        if ! check_cancelled; then
            STATE="FAILED"
        fi

        # Persist loop state after each iteration (product mode only)
        persist_loop_state

        case "$STATE" in
            CLONE)      state_clone ;;
            CREATE_REPO) state_create_repo ;;
            SETUP)      state_setup ;;
            INIT)       state_init  ;;
            CODE)
                if [[ "$MODE" == "product" ]]; then
                    state_product_code
                else
                    state_code
                fi
                ;;
            TEST)
                if [[ "$MODE" == "product" ]]; then
                    state_product_test
                else
                    state_test
                fi
                ;;
            SCAFFOLD)   state_scaffold ;;
            SYNC)       state_sync ;;
            INIT_SH)    state_init_sh ;;
            PLAN)       state_plan ;;
            EVAL_BASELINE) state_eval_baseline ;;
            CODE_AUDIT)    state_code_audit ;;
            JUDGE)         state_judge ;;
            LEDGER)        state_ledger ;;
            LOOP_CHECK) state_loop_check ;;
            PUSH)       state_push ;;
            DONE)
                log "INFO" "Job completed successfully: $JOB_ID"
                log_json "job_done" "success=true"
                fire_webhooks "job_done" || true
                exit 0
                ;;
            FAILED)
                log "ERROR" "Job failed: $JOB_ID"
                log_json "job_failed" ""
                fire_webhooks "job_failed" || true

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

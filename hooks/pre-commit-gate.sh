#!/usr/bin/env bash
# =============================================================================
# pre-commit-gate.sh - PreCommit quality gate hook
# Runs project test commands before allowing a commit.
# Exit 0 = allow commit, Exit 2 = block commit (tests failed).
# =============================================================================
set -euo pipefail

# Read the workspace path from environment or detect from git
WORKSPACE="${WORKSPACE_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Look for test commands in the job file or common patterns
TEST_PASSED=true

# Try to find test commands from the job context
JOB_FILE="${JOB_FILE:-}"
if [[ -n "$JOB_FILE" && -f "$JOB_FILE" ]]; then
    TEST_CMDS=$(jq -r '.commands.test // [] | .[]' "$JOB_FILE" 2>/dev/null)
    if [[ -n "$TEST_CMDS" ]]; then
        while IFS= read -r cmd; do
            [[ -z "$cmd" ]] && continue
            echo "[pre-commit-gate] Running: $cmd"
            if ! (cd "$WORKSPACE" && bash -c "$cmd" 2>&1 | tail -20); then
                echo "[pre-commit-gate] FAILED: $cmd"
                TEST_PASSED=false
            fi
        done <<< "$TEST_CMDS"
    fi
fi

# If no job file, try common test patterns
if [[ -z "$JOB_FILE" || ! -f "$JOB_FILE" ]]; then
    if [[ -f "$WORKSPACE/package.json" ]] && grep -q '"test"' "$WORKSPACE/package.json" 2>/dev/null; then
        echo "[pre-commit-gate] Running: npm test"
        if ! (cd "$WORKSPACE" && npm test 2>&1 | tail -20); then
            TEST_PASSED=false
        fi
    elif [[ -f "$WORKSPACE/pyproject.toml" ]] || [[ -f "$WORKSPACE/setup.py" ]]; then
        echo "[pre-commit-gate] Running: python -m pytest"
        if ! (cd "$WORKSPACE" && python -m pytest --tb=short 2>&1 | tail -20); then
            TEST_PASSED=false
        fi
    elif [[ -f "$WORKSPACE/Cargo.toml" ]]; then
        echo "[pre-commit-gate] Running: cargo test"
        if ! (cd "$WORKSPACE" && cargo test 2>&1 | tail -20); then
            TEST_PASSED=false
        fi
    elif [[ -f "$WORKSPACE/go.mod" ]]; then
        echo "[pre-commit-gate] Running: go test ./..."
        if ! (cd "$WORKSPACE" && go test ./... 2>&1 | tail -20); then
            TEST_PASSED=false
        fi
    fi
fi

if [[ "$TEST_PASSED" == "true" ]]; then
    echo "[pre-commit-gate] All tests passed — commit allowed"
    exit 0
else
    echo "[pre-commit-gate] Tests failed — commit blocked"
    exit 2
fi

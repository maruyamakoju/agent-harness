#!/usr/bin/env bash
# =============================================================================
# post-edit-lint.sh - PostToolUse hook for Edit/Write operations
# Runs file-type-specific linters after edits (informational, non-blocking).
# Exit 0 always — provides feedback but does not block the agent.
# =============================================================================
set -euo pipefail

# Read the tool result from stdin (JSON with tool_name, tool_input)
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null)

# Only process Edit and Write tool results
case "$TOOL_NAME" in
    Edit|Write) ;;
    *) exit 0 ;;
esac

[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

# Get file extension
EXT="${FILE_PATH##*.}"

lint_output=""
case "$EXT" in
    py)
        if command -v ruff &>/dev/null; then
            lint_output=$(ruff check --select=E,W "$FILE_PATH" 2>&1 | head -20) || true
        elif command -v flake8 &>/dev/null; then
            lint_output=$(flake8 --max-line-length=120 "$FILE_PATH" 2>&1 | head -20) || true
        fi
        ;;
    ts|tsx|js|jsx)
        if command -v eslint &>/dev/null; then
            lint_output=$(eslint --no-eslintrc --rule '{"no-unused-vars":"warn","no-undef":"error"}' "$FILE_PATH" 2>&1 | head -20) || true
        fi
        ;;
    go)
        if command -v gofmt &>/dev/null; then
            lint_output=$(gofmt -l "$FILE_PATH" 2>&1) || true
            if [[ -n "$lint_output" ]]; then
                lint_output="Needs formatting: $lint_output"
            fi
        fi
        ;;
    rs)
        if command -v clippy-driver &>/dev/null; then
            lint_output=$(clippy-driver "$FILE_PATH" 2>&1 | head -20) || true
        fi
        ;;
    sh|bash)
        if command -v shellcheck &>/dev/null; then
            lint_output=$(shellcheck --severity=error "$FILE_PATH" 2>&1 | head -20) || true
        fi
        ;;
esac

if [[ -n "$lint_output" ]]; then
    echo "[post-edit-lint] Lint hints for $FILE_PATH:"
    echo "$lint_output"
fi

# Always exit 0 — informational only
exit 0

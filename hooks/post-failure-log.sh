#!/usr/bin/env bash
# =============================================================================
# post-failure-log.sh - PostFailure hook
# Logs failures to PROGRESS.md and creates incident files in TASKS/.
# Exit 0 always — informational, non-blocking.
# =============================================================================
set -euo pipefail

# Read failure context from stdin
INPUT=$(cat)
ERROR_MSG=$(echo "$INPUT" | jq -r '.error // .message // "unknown error"' 2>/dev/null || echo "unknown error")
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)

# Detect workspace
WORKSPACE="${WORKSPACE_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS_SLUG=$(date -u +%Y%m%d-%H%M%S)

# Append to PROGRESS.md if it exists
if [[ -f "$WORKSPACE/PROGRESS.md" ]]; then
    {
        echo ""
        echo "### Failure at $TIMESTAMP"
        echo "- Tool: $TOOL_NAME"
        echo "- Error: ${ERROR_MSG:0:500}"
    } >> "$WORKSPACE/PROGRESS.md"
    echo "[post-failure-log] Appended failure to PROGRESS.md"
fi

# Create incident file in TASKS/
TASKS_DIR="$WORKSPACE/TASKS"
if [[ -d "$TASKS_DIR" ]]; then
    INCIDENT_FILE="$TASKS_DIR/incident-${TS_SLUG}.md"
    cat > "$INCIDENT_FILE" <<EOF
# Incident: ${TS_SLUG}

- **Timestamp**: ${TIMESTAMP}
- **Tool**: ${TOOL_NAME}
- **Status**: open

## Error
\`\`\`
${ERROR_MSG:0:2000}
\`\`\`

## Resolution
_(to be filled by the debugger agent)_
EOF
    echo "[post-failure-log] Created incident: $INCIDENT_FILE"
fi

exit 0

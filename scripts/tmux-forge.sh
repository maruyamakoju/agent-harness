#!/usr/bin/env bash
# =============================================================================
# tmux-forge.sh - Product Forge tmux session manager
# Creates a 4-pane session for monitoring the Product Forge.
# Usage: tmux-forge.sh [attach|detach|kill]
# =============================================================================
set -euo pipefail

SESSION_NAME="product-forge"
HARNESS_DIR="${HARNESS_DIR:-/harness}"

case "${1:-attach}" in
    attach)
        # Check if session already exists
        if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            echo "Attaching to existing session: $SESSION_NAME"
            tmux attach-session -t "$SESSION_NAME"
            exit 0
        fi

        echo "Creating new Product Forge session..."

        # Create session with first pane: agent loop
        tmux new-session -d -s "$SESSION_NAME" -n "forge" \
            "echo '=== Agent Loop ==='; tail -f ${HARNESS_DIR}/logs/*.log 2>/dev/null || echo 'Waiting for logs...'; bash"

        # Split horizontally: dashboard
        tmux split-window -h -t "$SESSION_NAME:forge" \
            "echo '=== Dashboard ==='; cd ${HARNESS_DIR}/dashboard && python app.py 2>&1 || echo 'Dashboard not running'; bash"

        # Split first pane vertically: log tail
        tmux split-window -v -t "$SESSION_NAME:forge.0" \
            "echo '=== Event Log ==='; tail -f ${HARNESS_DIR}/logs/*.jsonl 2>/dev/null | jq -r '.event + \" \" + .detail' 2>/dev/null || echo 'Waiting for events...'; bash"

        # Split second pane vertically: system monitor
        tmux split-window -v -t "$SESSION_NAME:forge.1" \
            "echo '=== System Monitor ==='; watch -n 5 'echo \"--- Jobs ---\"; ls ${HARNESS_DIR}/jobs/*/  2>/dev/null | head -20; echo; echo \"--- Disk ---\"; df -h /workspaces 2>/dev/null; echo; echo \"--- Memory ---\"; free -h 2>/dev/null || echo N/A' 2>/dev/null || bash"

        # Select layout
        tmux select-layout -t "$SESSION_NAME:forge" tiled

        # Attach
        tmux attach-session -t "$SESSION_NAME"
        ;;

    detach)
        if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            echo "Session $SESSION_NAME is running. Detach with: tmux detach"
        else
            echo "No session named $SESSION_NAME"
        fi
        ;;

    kill)
        if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            tmux kill-session -t "$SESSION_NAME"
            echo "Session $SESSION_NAME killed"
        else
            echo "No session named $SESSION_NAME"
        fi
        ;;

    status)
        if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            echo "Session $SESSION_NAME is running"
            tmux list-panes -t "$SESSION_NAME" -F "  Pane #{pane_index}: #{pane_current_command} (#{pane_width}x#{pane_height})"
        else
            echo "Session $SESSION_NAME is not running"
        fi
        ;;

    *)
        echo "Usage: tmux-forge.sh [attach|detach|kill|status]"
        exit 1
        ;;
esac

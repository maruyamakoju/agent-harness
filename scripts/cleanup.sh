#!/usr/bin/env bash
# =============================================================================
# cleanup.sh - Periodic cleanup for disk space management
# Run via cron: 0 3 * * * /home/agent/agent-harness/scripts/cleanup.sh
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
JOBS_DIR="${HARNESS_DIR}/jobs"
LOGS_DIR="${HARNESS_DIR}/logs"
WORKSPACES_DIR="${WORKSPACES_DIR:-/workspaces}"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting cleanup..."

# ---------------------------------------------------------------------------
# 1. Remove completed job files older than 30 days
# ---------------------------------------------------------------------------
echo "Cleaning old completed jobs..."
find "$JOBS_DIR/done" -name "*.json" -mtime +30 -delete 2>/dev/null || true
DONE_CLEANED=$(find "$JOBS_DIR/done" -name "*.json" -mtime +30 2>/dev/null | wc -l)
echo "  Removed $DONE_CLEANED old completed job files"

# ---------------------------------------------------------------------------
# 2. Remove failed job files older than 14 days
# ---------------------------------------------------------------------------
echo "Cleaning old failed jobs..."
find "$JOBS_DIR/failed" -name "*.json" -mtime +14 -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. Compress and rotate logs older than 7 days
# ---------------------------------------------------------------------------
echo "Rotating logs..."
find "$LOGS_DIR" -name "*.log" -mtime +7 -exec gzip {} \; 2>/dev/null || true
find "$LOGS_DIR" -name "*.log.gz" -mtime +30 -delete 2>/dev/null || true

# Rotate JSONL logs
if [[ -f "$LOGS_DIR/agent-loop.jsonl" ]]; then
    local_size=$(stat -c%s "$LOGS_DIR/agent-loop.jsonl" 2>/dev/null || echo 0)
    if [[ $local_size -gt 104857600 ]]; then  # > 100MB
        mv "$LOGS_DIR/agent-loop.jsonl" "$LOGS_DIR/agent-loop.$(date +%Y%m%d).jsonl"
        gzip "$LOGS_DIR/agent-loop.$(date +%Y%m%d).jsonl"
        echo "  Rotated agent-loop.jsonl"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Remove orphaned workspaces
# ---------------------------------------------------------------------------
echo "Cleaning orphaned workspaces..."
if [[ -d "$WORKSPACES_DIR" ]]; then
    for ws in "$WORKSPACES_DIR"/*/; do
        [[ -d "$ws" ]] || continue
        ws_name=$(basename "$ws")
        # Check if there's a corresponding running job
        if ! find "$JOBS_DIR/running" -name "${ws_name}.json" -print -quit 2>/dev/null | grep -q .; then
            echo "  Removing orphaned workspace: $ws_name"
            rm -rf "$ws"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 5. Docker cleanup
# ---------------------------------------------------------------------------
echo "Docker cleanup..."
docker system prune -f --volumes 2>/dev/null || true
docker image prune -f 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Report disk usage
# ---------------------------------------------------------------------------
echo ""
echo "Disk usage:"
df -h / /harness /workspaces 2>/dev/null | head -5
echo ""
echo "Jobs directory:"
du -sh "$JOBS_DIR"/* 2>/dev/null || true
echo ""
echo "Logs directory:"
du -sh "$LOGS_DIR" 2>/dev/null || true
echo ""

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Cleanup complete."

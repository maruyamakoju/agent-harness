#!/usr/bin/env bash
# =============================================================================
# cancel-job.sh - Cancel a pending or running job
# Usage: cancel-job.sh <job-id-pattern>
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
JOBS_DIR="${HARNESS_DIR}/jobs"
PATTERN="${1:-}"

if [[ -z "$PATTERN" ]]; then
    echo "Usage: cancel-job.sh <job-id-pattern>"
    echo "  Pattern matches against job filenames (supports wildcards)"
    echo ""
    echo "Examples:"
    echo "  cancel-job.sh 2026-02-16*"
    echo "  cancel-job.sh *user-auth*"
    exit 1
fi

FOUND=0

# Check pending jobs
for f in "$JOBS_DIR/pending"/*${PATTERN}*.json; do
    [[ -f "$f" ]] || continue
    local job_id
    job_id=$(jq -r '.id' "$f")
    echo "Cancelling pending job: $job_id"
    mv "$f" "$JOBS_DIR/failed/$(basename "$f")"
    FOUND=$((FOUND + 1))
done

# Check running jobs (mark for cancellation, loop will pick it up)
for f in "$JOBS_DIR/running"/*${PATTERN}*.json; do
    [[ -f "$f" ]] || continue
    local job_id
    job_id=$(jq -r '.id' "$f")
    echo "Marking running job for cancellation: $job_id"
    # Add cancelled flag
    jq '. + {cancelled: true}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    FOUND=$((FOUND + 1))
done

if [[ $FOUND -eq 0 ]]; then
    echo "No matching jobs found for pattern: $PATTERN"
    exit 1
else
    echo "$FOUND job(s) cancelled"
fi

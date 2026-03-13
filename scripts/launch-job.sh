#!/usr/bin/env bash
# launch-job.sh — thin wrapper to set HARNESS_DIR and call run-job.sh
# Usage: bash scripts/launch-job.sh <job-file>
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACES_DIR="${WORKSPACES_DIR:-$HARNESS_DIR/workspaces}"
export HARNESS_DIR WORKSPACES_DIR
exec bash "$HARNESS_DIR/scripts/run-job.sh" "$1"

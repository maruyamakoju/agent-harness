#!/usr/bin/env bash
# launch-job.sh — thin wrapper to set HARNESS_DIR and call run-job.sh
# Usage: bash scripts/launch-job.sh <job-file>
set -euo pipefail

# On Windows/MSYS2, compact PATH to prevent environment block corruption
if [[ "$(uname -o 2>/dev/null || true)" == "Msys" ]]; then
    _CLEAN_PATH="/mingw64/bin:/usr/bin:/bin"
    [[ -d "$HOME/bin" ]] && _CLEAN_PATH="$HOME/bin:$_CLEAN_PATH"
    export PATH="$_CLEAN_PATH"
    unset _CLEAN_PATH
fi

HARNESS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACES_DIR="${WORKSPACES_DIR:-$HARNESS_DIR/workspaces}"
export HARNESS_DIR WORKSPACES_DIR
exec bash "$HARNESS_DIR/scripts/run-job.sh" "$1"

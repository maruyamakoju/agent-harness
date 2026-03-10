#!/usr/bin/env bash
# Launch autoresearch experiment in WSL
set -euo pipefail

export PATH="$HOME/bin:$PATH"
export HARNESS_DIR="/mnt/c/Users/07013/Desktop/0216muzin"
export WORKSPACES_DIR="/mnt/c/Users/07013/Desktop/0216muzin/workspaces"
export PRESERVE_WORKSPACE=true

JOB_FILE="/mnt/c/Users/07013/Desktop/0216muzin/jobs/pending/autoresearch-cli-taskman-001.json"

echo "=== Pre-flight check ==="
echo "HARNESS_DIR: $HARNESS_DIR"
echo "WORKSPACES_DIR: $WORKSPACES_DIR"
echo "JOB_FILE: $JOB_FILE"
echo "job id: $(jq -r .id "$JOB_FILE")"
echo "claude: $(which claude)"
echo "git: $(git --version)"
echo "jq: $(jq --version)"
echo "python: $(python3 --version)"
echo "=== Launching experiment ==="

exec bash "$HARNESS_DIR/scripts/run-job.sh" "$JOB_FILE"

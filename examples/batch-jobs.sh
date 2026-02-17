#!/usr/bin/env bash
# =============================================================================
# batch-jobs.sh - Example: Submit multiple jobs at once
# Customize this file for your project's recurring tasks
# =============================================================================
set -euo pipefail

SCRIPTS_DIR="${HARNESS_DIR:-/home/agent/agent-harness}/scripts"
REPO="git@github.com:your-org/your-repo.git"

echo "Submitting batch jobs..."

# Job 1: Feature implementation
"$SCRIPTS_DIR/create-job.sh" \
    --repo "$REPO" \
    --task "Implement user registration API endpoint with email validation" \
    --setup "npm ci" \
    --test "npm test" \
    --time-budget 3600

# Job 2: Bug fix
"$SCRIPTS_DIR/create-job.sh" \
    --repo "$REPO" \
    --task "Fix the race condition in the checkout flow where inventory count goes negative" \
    --setup "npm ci" \
    --test "npm test" --test "npm run e2e" \
    --time-budget 1800

# Job 3: Test coverage
"$SCRIPTS_DIR/create-job.sh" \
    --repo "$REPO" \
    --task "Add unit tests for all functions in src/utils/ to achieve 90% coverage" \
    --setup "npm ci" \
    --test "npm test -- --coverage" \
    --time-budget 2400

# Job 4: Dependency update
"$SCRIPTS_DIR/create-job.sh" \
    --repo "$REPO" \
    --task "Update all npm dependencies to latest compatible versions, fix any breaking changes" \
    --setup "npm ci" \
    --test "npm test" --test "npm run build" \
    --time-budget 3600

echo ""
echo "All jobs submitted. Check queue:"
"$SCRIPTS_DIR/list-jobs.sh" pending

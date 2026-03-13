#!/usr/bin/env bash
# =============================================================================
# create-variant-jobs.sh — Generate A/B experiment jobs from program.md variants
#
# Given a base job JSON and multiple program.md files, creates one job per
# variant with the same features, caps, and scaffold but different arena rules.
#
# Usage:
#   bash scripts/create-variant-jobs.sh <base-job.json> <program-v1.md> [<program-v2.md> ...]
#
# Output: creates jobs/pending/<base-id>-v1.json, jobs/pending/<base-id>-v2.json, etc.
#
# After running experiments, compare results with:
#   bash scripts/compare-programs.sh workspaces/<base-id>-v1 workspaces/<base-id>-v2
# =============================================================================
set -euo pipefail

PATH="$HOME/bin:$PATH"

if [[ $# -lt 2 ]]; then
    echo "Usage: create-variant-jobs.sh <base-job.json> <program-v1.md> [<program-v2.md> ...]"
    echo ""
    echo "Creates one job per program.md variant for A/B comparison."
    echo "All variants share the same features, caps, and scaffold."
    exit 1
fi

BASE_JOB="$1"
shift

if [[ ! -f "$BASE_JOB" ]]; then
    echo "ERROR: Base job file not found: $BASE_JOB"
    exit 1
fi

BASE_ID=$(jq -r '.id' "$BASE_JOB")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$HARNESS_DIR/jobs/pending"

VARIANT_NUM=0
for program_file in "$@"; do
    VARIANT_NUM=$((VARIANT_NUM + 1))

    if [[ ! -f "$program_file" ]]; then
        echo "WARN: Program file not found, skipping: $program_file"
        continue
    fi

    local_id="${BASE_ID}-v${VARIANT_NUM}"
    local_branch="forge/${local_id}"

    # Read program.md content, escape for JSON
    program_content=$(jq -Rs '.' "$program_file")

    # Create variant job: same base but with overridden id, branch, and program_md
    jq --arg id "$local_id" \
       --arg branch "$local_branch" \
       --argjson program_md "$program_content" \
       '.id = $id | .work_branch = $branch | .program_md = $program_md' \
       "$BASE_JOB" > "$HARNESS_DIR/jobs/pending/${local_id}.json"

    echo "Created: jobs/pending/${local_id}.json (variant $VARIANT_NUM: $(basename "$program_file"))"
done

echo ""
echo "All $VARIANT_NUM variant jobs created in jobs/pending/"
echo ""
echo "Run them with:"
for i in $(seq 1 "$VARIANT_NUM"); do
    echo "  bash scripts/launch-job.sh jobs/running/${BASE_ID}-v${i}.json"
done
echo ""
echo "After completion, compare with:"
echo "  bash scripts/compare-programs.sh workspaces/${BASE_ID}-v*/"

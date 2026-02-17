#!/usr/bin/env bash
# =============================================================================
# list-jobs.sh - List and inspect jobs
# Usage: list-jobs.sh [pending|running|done|failed|all] [--json]
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
JOBS_DIR="${HARNESS_DIR}/jobs"
FILTER="${1:-all}"
FORMAT="${2:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ---------------------------------------------------------------------------
# JSON output mode
# ---------------------------------------------------------------------------
if [[ "$FORMAT" == "--json" ]]; then
    result="[]"
    for status in pending running done failed; do
        if [[ "$FILTER" != "all" && "$FILTER" != "$status" ]]; then
            continue
        fi
        for f in "$JOBS_DIR/$status"/*.json; do
            [[ -f "$f" ]] || continue
            entry=$(jq --arg s "$status" '. + {status: $s}' "$f")
            result=$(echo "$result" | jq --argjson e "$entry" '. + [$e]')
        done
    done
    echo "$result" | jq .
    exit 0
fi

# ---------------------------------------------------------------------------
# Human-readable output
# ---------------------------------------------------------------------------
print_jobs() {
    local status="$1"
    local color="$2"
    local icon="$3"

    local count
    count=$(find "$JOBS_DIR/$status" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')

    if [[ $count -eq 0 ]]; then
        return
    fi

    echo -e "\n${BOLD}${color}── ${status^^} (${count}) ──${NC}"

    find "$JOBS_DIR/$status" -name "*.json" -type f 2>/dev/null | sort | while read -r f; do
        local job_id task repo created budget
        job_id=$(jq -r '.id // "?"' "$f")
        task=$(jq -r '.task // "?"' "$f")
        repo=$(jq -r '.repo // "?"' "$f")
        created=$(jq -r '.created_at // "?"' "$f")
        budget=$(jq -r '.time_budget_sec // "?"' "$f")

        echo -e "  ${color}${icon}${NC} ${BOLD}${job_id}${NC}"
        echo -e "    Task:    ${task:0:70}"
        echo -e "    Repo:    ${repo}"
        echo -e "    Created: ${created}"
        echo -e "    Budget:  ${budget}s"
    done
}

echo -e "${BOLD}${CYAN}Agent Job Queue${NC}"
echo -e "$(date '+%Y-%m-%d %H:%M:%S')"

case "$FILTER" in
    pending) print_jobs "pending" "$BLUE" "◦" ;;
    running) print_jobs "running" "$YELLOW" "▶" ;;
    done)    print_jobs "done" "$GREEN" "✓" ;;
    failed)  print_jobs "failed" "$RED" "✗" ;;
    all)
        print_jobs "running" "$YELLOW" "▶"
        print_jobs "pending" "$BLUE" "◦"
        print_jobs "done" "$GREEN" "✓"
        print_jobs "failed" "$RED" "✗"
        ;;
    *)
        echo "Usage: list-jobs.sh [pending|running|done|failed|all] [--json]"
        exit 1
        ;;
esac

# Summary
echo ""
local p r d f
p=$(find "$JOBS_DIR/pending" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
r=$(find "$JOBS_DIR/running" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
d=$(find "$JOBS_DIR/done" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
f=$(find "$JOBS_DIR/failed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
echo -e "Total: ${BLUE}${p} pending${NC} | ${YELLOW}${r} running${NC} | ${GREEN}${d} done${NC} | ${RED}${f} failed${NC}"

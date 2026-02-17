#!/usr/bin/env bash
# =============================================================================
# view-job-log.sh - View and analyze job logs
# Usage:
#   view-job-log.sh <job-id>             - Show full log
#   view-job-log.sh <job-id> --summary   - Show summary only
#   view-job-log.sh <job-id> --errors    - Show errors only
#   view-job-log.sh <job-id> --states    - Show state transitions
#   view-job-log.sh <job-id> --follow    - Tail the log (live)
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
LOGS_DIR="${HARNESS_DIR}/logs"

JOB_ID="${1:-}"
MODE="${2:---full}"

if [[ -z "$JOB_ID" ]]; then
    echo "Usage: view-job-log.sh <job-id> [--summary|--errors|--states|--follow|--full]"
    echo ""
    echo "Available job logs:"
    ls -1t "$LOGS_DIR"/*.log 2>/dev/null | head -20 | while read -r f; do
        echo "  $(basename "$f" .log)"
    done
    exit 1
fi

LOG_FILE="${LOGS_DIR}/${JOB_ID}.log"
JSONL_FILE="${LOGS_DIR}/${JOB_ID}.jsonl"

if [[ ! -f "$LOG_FILE" && ! -f "$JSONL_FILE" ]]; then
    # Try fuzzy match
    MATCH=$(find "$LOGS_DIR" -name "*${JOB_ID}*" -type f 2>/dev/null | head -1)
    if [[ -n "$MATCH" ]]; then
        echo "Exact match not found. Using: $(basename "$MATCH")"
        if [[ "$MATCH" == *.jsonl ]]; then
            JSONL_FILE="$MATCH"
            LOG_FILE="${MATCH%.jsonl}.log"
        else
            LOG_FILE="$MATCH"
            JSONL_FILE="${MATCH%.log}.jsonl"
        fi
    else
        echo "No log found for job: $JOB_ID"
        exit 1
    fi
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

case "$MODE" in
    --summary)
        echo -e "${BOLD}${CYAN}Job Summary: ${JOB_ID}${NC}"
        echo ""

        if [[ -f "$JSONL_FILE" ]]; then
            # Extract key events
            echo -e "${BOLD}Timeline:${NC}"
            jq -r '
                select(.event == "job_start" or .event == "state_transition" or .event == "job_done" or .event == "job_failed") |
                "  \(.timestamp) [\(.event)] \(.detail)"
            ' "$JSONL_FILE" 2>/dev/null

            echo ""
            echo -e "${BOLD}Stats:${NC}"
            local total_events
            total_events=$(wc -l < "$JSONL_FILE")
            local duration
            duration=$(jq -r 'select(.event == "cleanup") | .detail' "$JSONL_FILE" 2>/dev/null | head -1)
            echo "  Total events: $total_events"
            echo "  Duration: ${duration:-unknown}"
        fi

        if [[ -f "$LOG_FILE" ]]; then
            echo ""
            echo -e "${BOLD}Error count:${NC} $(grep -c '\[ERROR\]' "$LOG_FILE" 2>/dev/null || echo 0)"
            echo -e "${BOLD}Warning count:${NC} $(grep -c '\[WARN\]' "$LOG_FILE" 2>/dev/null || echo 0)"
            echo -e "${BOLD}Log size:${NC} $(du -h "$LOG_FILE" | cut -f1)"
        fi
        ;;

    --errors)
        echo -e "${BOLD}${RED}Errors for: ${JOB_ID}${NC}"
        echo ""
        if [[ -f "$LOG_FILE" ]]; then
            grep -n '\[ERROR\]\|\[WARN\]' "$LOG_FILE" | while IFS= read -r line; do
                if echo "$line" | grep -q '\[ERROR\]'; then
                    echo -e "${RED}${line}${NC}"
                else
                    echo -e "${YELLOW}${line}${NC}"
                fi
            done
        fi
        ;;

    --states)
        echo -e "${BOLD}${BLUE}State Transitions: ${JOB_ID}${NC}"
        echo ""
        if [[ -f "$JSONL_FILE" ]]; then
            jq -r '
                select(.event == "state_transition") |
                "  \(.timestamp) | \(.detail)"
            ' "$JSONL_FILE" 2>/dev/null
        elif [[ -f "$LOG_FILE" ]]; then
            grep "State transition:" "$LOG_FILE"
        fi
        ;;

    --follow)
        echo -e "${BOLD}Following log: ${JOB_ID}${NC}"
        echo "(Ctrl+C to stop)"
        echo ""
        if [[ -f "$LOG_FILE" ]]; then
            tail -f "$LOG_FILE"
        else
            echo "Log file not found: $LOG_FILE"
        fi
        ;;

    --full|*)
        if [[ -f "$LOG_FILE" ]]; then
            # Colorize output
            while IFS= read -r line; do
                if echo "$line" | grep -q '\[ERROR\]'; then
                    echo -e "${RED}${line}${NC}"
                elif echo "$line" | grep -q '\[WARN\]'; then
                    echo -e "${YELLOW}${line}${NC}"
                elif echo "$line" | grep -q 'State transition:'; then
                    echo -e "${CYAN}${line}${NC}"
                elif echo "$line" | grep -q '===='; then
                    echo -e "${BOLD}${line}${NC}"
                else
                    echo "$line"
                fi
            done < "$LOG_FILE"
        else
            echo "Log file not found: $LOG_FILE"
        fi
        ;;
esac

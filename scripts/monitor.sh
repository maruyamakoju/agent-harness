#!/usr/bin/env bash
# =============================================================================
# monitor.sh - Agent System Dashboard
# Shows live status of the agent loop, jobs, and system health
# =============================================================================
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-/harness}"
JOBS_DIR="${HARNESS_DIR}/jobs"
LOGS_DIR="${HARNESS_DIR}/logs"
HEARTBEAT_FILE="${LOGS_DIR}/heartbeat.json"
LOOP_LOG="${LOGS_DIR}/agent-loop.jsonl"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

clear_screen() {
    printf '\033[2J\033[H'
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       24/7 Autonomous Coding Agent - System Monitor        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
}

# ---------------------------------------------------------------------------
# Heartbeat status
# ---------------------------------------------------------------------------
print_heartbeat() {
    echo -e "${BOLD}── Agent Heartbeat ──${NC}"
    if [[ -f "$HEARTBEAT_FILE" ]]; then
        local last_beat
        last_beat=$(jq -r '.timestamp' "$HEARTBEAT_FILE" 2>/dev/null || echo "unknown")
        local status
        status=$(jq -r '.status' "$HEARTBEAT_FILE" 2>/dev/null || echo "unknown")
        local consec_fail
        consec_fail=$(jq -r '.consecutive_failures' "$HEARTBEAT_FILE" 2>/dev/null || echo "0")

        # Check if heartbeat is stale
        local file_age
        file_age=$(( $(date +%s) - $(date -r "$HEARTBEAT_FILE" +%s 2>/dev/null || echo 0) ))

        if [[ $file_age -lt 300 ]]; then
            echo -e "  Status:   ${GREEN}● ALIVE${NC} (last: ${last_beat})"
        else
            echo -e "  Status:   ${RED}● STALE${NC} (last: ${last_beat}, ${file_age}s ago)"
        fi

        if [[ "$consec_fail" -gt 0 ]]; then
            echo -e "  Failures: ${YELLOW}${consec_fail} consecutive${NC}"
        else
            echo -e "  Failures: ${GREEN}0${NC}"
        fi
    else
        echo -e "  Status:   ${RED}● NO HEARTBEAT${NC}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Job queue status
# ---------------------------------------------------------------------------
print_queue() {
    echo -e "${BOLD}── Job Queue ──${NC}"

    local pending running done failed
    pending=$(find "$JOBS_DIR/pending" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    running=$(find "$JOBS_DIR/running" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    done=$(find "$JOBS_DIR/done" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    failed=$(find "$JOBS_DIR/failed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

    echo -e "  Pending:  ${BLUE}${pending}${NC}"
    echo -e "  Running:  ${YELLOW}${running}${NC}"
    echo -e "  Done:     ${GREEN}${done}${NC}"
    echo -e "  Failed:   ${RED}${failed}${NC}"
    echo ""

    # Show currently running job
    if [[ "$running" -gt 0 ]]; then
        echo -e "${BOLD}── Running Jobs ──${NC}"
        for f in "$JOBS_DIR/running"/*.json; do
            [[ -f "$f" ]] || continue
            local job_id task
            job_id=$(jq -r '.id' "$f" 2>/dev/null || echo "unknown")
            task=$(jq -r '.task' "$f" 2>/dev/null || echo "unknown")
            echo -e "  ${YELLOW}▶${NC} ${job_id}"
            echo -e "    Task: ${task:0:70}"
        done
        echo ""
    fi

    # Show pending jobs
    if [[ "$pending" -gt 0 ]]; then
        echo -e "${BOLD}── Pending Jobs ──${NC}"
        for f in "$JOBS_DIR/pending"/*.json; do
            [[ -f "$f" ]] || continue
            local job_id task
            job_id=$(jq -r '.id' "$f" 2>/dev/null || echo "unknown")
            task=$(jq -r '.task' "$f" 2>/dev/null || echo "unknown")
            echo -e "  ${BLUE}◦${NC} ${job_id}"
            echo -e "    Task: ${task:0:70}"
        done
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Recent activity (last 10 events)
# ---------------------------------------------------------------------------
print_recent_activity() {
    echo -e "${BOLD}── Recent Activity (last 10) ──${NC}"
    if [[ -f "$LOOP_LOG" ]]; then
        tail -n 10 "$LOOP_LOG" | while IFS= read -r line; do
            local level
            level=$(echo "$line" | jq -r '.level' 2>/dev/null || echo "")
            local event
            event=$(echo "$line" | jq -r '.event' 2>/dev/null || echo "")
            local ts
            ts=$(echo "$line" | jq -r '.timestamp' 2>/dev/null || echo "")
            local detail
            detail=$(echo "$line" | jq -r '.detail // ""' 2>/dev/null || echo "")

            local color="$NC"
            case "$level" in
                ERROR) color="$RED" ;;
                WARN)  color="$YELLOW" ;;
                INFO)  color="$GREEN" ;;
            esac
            echo -e "  ${color}${ts} [${level}] ${event}${NC} ${detail:+(${detail})}"
        done
    else
        echo "  No activity log found."
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# System resources
# ---------------------------------------------------------------------------
print_system() {
    echo -e "${BOLD}── System Resources ──${NC}"

    # Disk usage
    local disk_usage
    disk_usage=$(df -h "$HARNESS_DIR" 2>/dev/null | tail -1 | awk '{print $5 " used of " $2}' || echo "N/A")
    echo -e "  Disk:     ${disk_usage}"

    # Memory
    local mem_info
    mem_info=$(free -h 2>/dev/null | awk '/Mem:/ {print $3 " / " $2}' || echo "N/A")
    echo -e "  Memory:   ${mem_info}"

    # GPU (if nvidia-smi available)
    if command -v nvidia-smi &>/dev/null; then
        local gpu_util gpu_mem gpu_temp
        gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A")
        gpu_mem=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A")
        gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A")
        echo -e "  GPU Util: ${gpu_util}%"
        echo -e "  GPU Mem:  ${gpu_mem} MiB"
        echo -e "  GPU Temp: ${gpu_temp}°C"
    else
        echo -e "  GPU:      ${YELLOW}nvidia-smi not available${NC}"
    fi

    # Docker containers
    if command -v docker &>/dev/null; then
        local containers
        containers=$(docker ps --format "{{.Names}} ({{.Status}})" 2>/dev/null | head -5 || echo "N/A")
        echo -e "  Docker:   ${containers}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Recent failures
# ---------------------------------------------------------------------------
print_failures() {
    local failed_count
    failed_count=$(find "$JOBS_DIR/failed" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$failed_count" -gt 0 ]]; then
        echo -e "${BOLD}${RED}── Recent Failures (last 5) ──${NC}"
        find "$JOBS_DIR/failed" -name "*.json" -type f 2>/dev/null \
            | sort -r \
            | head -5 \
            | while read -r f; do
                local job_id task
                job_id=$(jq -r '.id' "$f" 2>/dev/null || echo "unknown")
                task=$(jq -r '.task' "$f" 2>/dev/null || echo "unknown")
                echo -e "  ${RED}✗${NC} ${job_id}"
                echo -e "    Task: ${task:0:70}"
            done
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================
MODE="${1:-once}"

case "$MODE" in
    watch)
        # Continuous refresh mode
        while true; do
            clear_screen
            print_header
            print_heartbeat
            print_queue
            print_recent_activity
            print_system
            print_failures
            echo -e "${CYAN}Refreshing every 5s... (Ctrl+C to exit)${NC}"
            sleep 5
        done
        ;;
    once|*)
        print_header
        print_heartbeat
        print_queue
        print_recent_activity
        print_system
        print_failures
        ;;
esac

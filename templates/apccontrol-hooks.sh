#!/usr/bin/env bash
# =============================================================================
# apccontrol-hooks.sh - UPS Event Hooks for Agent System
# Copy to /etc/apcupsd/apccontrol or source from apccontrol
#
# Events: onbattery, offbattery, failing, shutdown, etc.
# =============================================================================

AGENT_HARNESS="/home/agent/agent-harness"
NOTIFY_SCRIPT="${AGENT_HARNESS}/scripts/notify.sh"

case "$1" in
    onbattery)
        # Power failure detected - running on battery
        "$NOTIFY_SCRIPT" "ups_on_battery" "system" "Running on battery power!" 2>/dev/null || true
        ;;

    offbattery)
        # Power restored
        "$NOTIFY_SCRIPT" "ups_power_restored" "system" "AC power restored" 2>/dev/null || true
        ;;

    failing)
        # Battery low - shutdown imminent
        "$NOTIFY_SCRIPT" "ups_failing" "system" "Battery critically low! Initiating shutdown..." 2>/dev/null || true

        # Gracefully stop agent container
        docker stop coding-agent --time 120 2>/dev/null || true

        # Sync filesystem
        sync
        ;;

    doshutdown)
        # Performing shutdown
        "$NOTIFY_SCRIPT" "ups_shutdown" "system" "UPS-triggered shutdown in progress" 2>/dev/null || true

        # Stop all containers
        docker compose -f "${AGENT_HARNESS}/docker-compose.yml" down --timeout 60 2>/dev/null || true
        sync
        ;;

    changeme)
        # Battery needs replacement
        "$NOTIFY_SCRIPT" "ups_battery_replace" "system" "UPS battery needs replacement!" 2>/dev/null || true
        ;;
esac

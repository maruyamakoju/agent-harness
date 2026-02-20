#!/usr/bin/env bash
# =============================================================================
# notify.sh - Send notifications for job events
# Supports: Telegram, Discord webhook, generic webhook
# Usage: notify.sh <event> <job_id> [message]
# =============================================================================
set -uo pipefail

EVENT="${1:-unknown}"
JOB_ID="${2:-unknown}"
MESSAGE="${3:-}"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build notification text
case "$EVENT" in
    job_start)
        ICON="▶️"
        TEXT="Job started: ${JOB_ID}"
        ;;
    job_done)
        ICON="✅"
        TEXT="Job completed: ${JOB_ID}"
        ;;
    job_failed)
        ICON="❌"
        TEXT="Job failed: ${JOB_ID}"
        ;;
    circuit_breaker)
        ICON="⚠️"
        TEXT="Circuit breaker triggered! Consecutive failures."
        ;;
    stale_heartbeat)
        ICON="💀"
        TEXT="Agent heartbeat stale! System may be down."
        ;;
    auth_failed)
        ICON="🔑"
        TEXT="Claude Code auth failed! Run: docker exec -it coding-agent claude login"
        ;;
    quota_exceeded)
        ICON="📊"
        TEXT="Daily job quota reached. Pausing until midnight."
        ;;
    auto_queue)
        ICON="🔄"
        TEXT="Auto-queue: New job created (count=${JOB_ID})"
        ;;
    *)
        ICON="ℹ️"
        TEXT="Event: ${EVENT} | Job: ${JOB_ID}"
        ;;
esac

FULL_TEXT="${ICON} [Agent] ${TEXT}"
[[ -n "$MESSAGE" ]] && FULL_TEXT="${FULL_TEXT}\n${MESSAGE}"
FULL_TEXT="${FULL_TEXT}\n🕐 ${TIMESTAMP}"

# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=$(echo -e "$FULL_TEXT")" \
        -d "parse_mode=HTML" \
        > /dev/null 2>&1 || echo "WARN: Telegram notification failed"
fi

# ---------------------------------------------------------------------------
# Discord webhook
# ---------------------------------------------------------------------------
if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
    payload=$(jq -n --arg content "$(echo -e "$FULL_TEXT")" '{"content": $content}')
    curl -s -X POST \
        "${DISCORD_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        > /dev/null 2>&1 || echo "WARN: Discord notification failed"
fi

# ---------------------------------------------------------------------------
# Generic webhook (Slack-compatible)
# ---------------------------------------------------------------------------
if [[ -n "${WEBHOOK_URL:-}" ]]; then
    payload=$(jq -n --arg text "$(echo -e "$FULL_TEXT")" '{"text": $text}')
    curl -s -X POST \
        "${WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        > /dev/null 2>&1 || echo "WARN: Webhook notification failed"
fi

# Always log
echo "[${TIMESTAMP}] [NOTIFY] ${EVENT} ${JOB_ID} ${MESSAGE}" >> "${HARNESS_DIR:-/harness}/logs/notifications.log" 2>/dev/null || true

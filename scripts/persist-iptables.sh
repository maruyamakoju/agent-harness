#!/usr/bin/env bash
# =============================================================================
# persist-iptables.sh - Save and restore Docker egress rules
# Docker recreates networks on restart, so iptables rules need to be reapplied.
#
# Usage:
#   persist-iptables.sh save    - Save current rules
#   persist-iptables.sh restore - Restore saved rules (call after docker compose up)
#   persist-iptables.sh auto    - Install systemd service for auto-restore
# =============================================================================
set -euo pipefail

RULES_FILE="/etc/iptables/agent-egress.rules"
AGENT_HARNESS="${AGENT_HARNESS_DIR:-/home/agent/agent-harness}"

case "${1:-help}" in
    save)
        echo "Saving current DOCKER-USER rules..."
        mkdir -p "$(dirname "$RULES_FILE")"
        iptables -S DOCKER-USER > "$RULES_FILE" 2>/dev/null
        echo "Saved to $RULES_FILE"
        cat "$RULES_FILE"
        ;;

    restore)
        echo "Restoring egress rules..."

        # Wait for Docker network to be ready
        local retries=0
        while ! docker network ls 2>/dev/null | grep -q "agent-net"; do
            retries=$((retries + 1))
            if [[ $retries -gt 30 ]]; then
                echo "ERROR: Docker network 'agent-net' not found after 30 attempts"
                exit 1
            fi
            echo "Waiting for Docker network... (attempt $retries)"
            sleep 2
        done

        # Apply egress rules
        if [[ -f "$AGENT_HARNESS/scripts/setup-egress.sh" ]]; then
            local network_name
            network_name=$(docker network ls --filter "name=agent-net" --format "{{.Name}}" | head -1)
            bash "$AGENT_HARNESS/scripts/setup-egress.sh" "$network_name"
        elif [[ -f "$RULES_FILE" ]]; then
            echo "Applying saved rules from $RULES_FILE..."
            while IFS= read -r rule; do
                [[ "$rule" == "-P"* ]] && continue  # Skip policy rules
                [[ "$rule" == "-N"* ]] && continue  # Skip chain creation
                iptables ${rule/-A/-I} 2>/dev/null || true
            done < "$RULES_FILE"
        else
            echo "No rules file found. Run 'persist-iptables.sh save' first or use setup-egress.sh"
            exit 1
        fi

        echo "Egress rules restored"
        ;;

    auto)
        echo "Installing systemd service for auto-restore..."

        cat > /etc/systemd/system/agent-egress.service <<EOF
[Unit]
Description=Restore Docker egress rules for Agent System
After=docker.service agent-harness.service
Requires=docker.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=${AGENT_HARNESS}/scripts/persist-iptables.sh restore
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable agent-egress.service
        echo "Service installed and enabled: agent-egress.service"
        ;;

    *)
        echo "Usage: persist-iptables.sh [save|restore|auto]"
        echo ""
        echo "  save    - Save current iptables DOCKER-USER rules"
        echo "  restore - Restore rules (run after docker compose up)"
        echo "  auto    - Install systemd service for auto-restore on boot"
        ;;
esac

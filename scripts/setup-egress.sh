#!/usr/bin/env bash
# =============================================================================
# setup-egress.sh - Configure Docker network egress whitelist
# Run after docker compose up to restrict container outbound traffic
# Usage: sudo bash setup-egress.sh [network-name]
# =============================================================================
set -euo pipefail

NETWORK_NAME="${1:-0216muzin_agent-net}"

echo "Configuring egress rules for network: $NETWORK_NAME"

# Get subnet
SUBNET=$(docker network inspect "$NETWORK_NAME" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
if [[ -z "$SUBNET" ]]; then
    echo "ERROR: Could not find subnet for network '$NETWORK_NAME'"
    echo "Available networks:"
    docker network ls
    exit 1
fi

echo "Subnet: $SUBNET"

# Flush existing DOCKER-USER rules for this subnet (idempotent)
iptables -S DOCKER-USER 2>/dev/null | grep "$SUBNET" | while read -r rule; do
    iptables $(echo "$rule" | sed 's/-A/-D/') 2>/dev/null || true
done

# Default: DROP all egress from container subnet
iptables -I DOCKER-USER -s "$SUBNET" -j DROP
echo "  [+] Default DROP for $SUBNET"

# Allow DNS (required for all operations)
iptables -I DOCKER-USER -s "$SUBNET" -p udp --dport 53 -j ACCEPT
iptables -I DOCKER-USER -s "$SUBNET" -p tcp --dport 53 -j ACCEPT
echo "  [+] Allow DNS"

# Allow HTTPS (port 443) to specific destinations
# GitHub
for cidr in 140.82.112.0/20 192.30.252.0/22 185.199.108.0/22 143.55.64.0/20; do
    iptables -I DOCKER-USER -s "$SUBNET" -d "$cidr" -j ACCEPT
    echo "  [+] Allow GitHub: $cidr"
done

# npm registry (Cloudflare + Fastly)
for cidr in 104.16.0.0/12; do
    iptables -I DOCKER-USER -s "$SUBNET" -d "$cidr" -j ACCEPT
    echo "  [+] Allow npm: $cidr"
done

# PyPI (Fastly)
for cidr in 151.101.0.0/16; do
    iptables -I DOCKER-USER -s "$SUBNET" -d "$cidr" -j ACCEPT
    echo "  [+] Allow PyPI: $cidr"
done

# Anthropic API
for cidr in 160.75.0.0/16 104.18.0.0/16; do
    iptables -I DOCKER-USER -s "$SUBNET" -d "$cidr" -j ACCEPT
    echo "  [+] Allow Anthropic: $cidr"
done

# Allow established/related connections (for return traffic)
iptables -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
echo "  [+] Allow established connections"

# Allow container-to-host (for Ollama on host)
DOCKER_GATEWAY=$(docker network inspect "$NETWORK_NAME" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
if [[ -n "$DOCKER_GATEWAY" ]]; then
    iptables -I DOCKER-USER -s "$SUBNET" -d "$DOCKER_GATEWAY" -j ACCEPT
    echo "  [+] Allow container→host gateway: $DOCKER_GATEWAY"
fi

echo ""
echo "Egress rules configured successfully."
echo "Verify with: sudo iptables -L DOCKER-USER -n --line-numbers"

#!/usr/bin/env bash
# =============================================================================
# setup-host.sh - Host Machine Setup Script
# Run this on a fresh Ubuntu 24.04 Server to prepare the RTX 4090 runner
# Usage: sudo bash setup-host.sh
# =============================================================================
set -euo pipefail

echo "============================================"
echo " 24/7 Autonomous Coding Agent - Host Setup"
echo "============================================"
echo ""

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"
HARNESS_DIR="${AGENT_HOME}/agent-harness"

# ---------------------------------------------------------------------------
# 1. System updates
# ---------------------------------------------------------------------------
echo "[1/10] Updating system packages..."
apt-get update && apt-get upgrade -y
apt-get install -y \
    curl wget git jq htop tmux unzip \
    ufw fail2ban \
    unattended-upgrades apt-listchanges \
    apcupsd

# ---------------------------------------------------------------------------
# 2. Create agent user
# ---------------------------------------------------------------------------
echo "[2/10] Creating agent user..."
if ! id "$AGENT_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$AGENT_USER"
    echo "Agent user created: $AGENT_USER"
else
    echo "Agent user already exists"
fi

# ---------------------------------------------------------------------------
# 3. NVIDIA drivers + Container Toolkit
# ---------------------------------------------------------------------------
echo "[3/10] Installing NVIDIA drivers and container toolkit..."

# NVIDIA driver (if not already installed)
if ! command -v nvidia-smi &>/dev/null; then
    apt-get install -y nvidia-driver-550
    echo "NVIDIA driver installed. REBOOT REQUIRED after script completes."
fi

# NVIDIA Container Toolkit
if ! command -v nvidia-ctk &>/dev/null; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    echo "NVIDIA Container Toolkit installed"
fi

# ---------------------------------------------------------------------------
# 4. Docker Engine
# ---------------------------------------------------------------------------
echo "[4/10] Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$AGENT_USER"
    systemctl enable docker
    systemctl start docker
    echo "Docker installed"
else
    echo "Docker already installed"
fi

# ---------------------------------------------------------------------------
# 5. Firewall (ufw)
# ---------------------------------------------------------------------------
echo "[5/10] Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "SSH"
ufw allow 41641/udp comment "Tailscale"
ufw --force enable
echo "Firewall configured: SSH + Tailscale only"

# ---------------------------------------------------------------------------
# 6. Fail2ban
# ---------------------------------------------------------------------------
echo "[6/10] Configuring fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# 7. Disable sleep/suspend
# ---------------------------------------------------------------------------
echo "[7/10] Disabling sleep/suspend/hibernate..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# ---------------------------------------------------------------------------
# 8. Unattended upgrades
# ---------------------------------------------------------------------------
echo "[8/10] Configuring unattended security upgrades..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

dpkg-reconfigure -f noninteractive unattended-upgrades

# ---------------------------------------------------------------------------
# 9. Tailscale
# ---------------------------------------------------------------------------
echo "[9/10] Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale installed. Run 'sudo tailscale up' to authenticate."
else
    echo "Tailscale already installed"
fi

# ---------------------------------------------------------------------------
# 10. Prepare harness directory structure
# ---------------------------------------------------------------------------
echo "[10/10] Setting up harness directory..."
mkdir -p "$HARNESS_DIR"/{jobs/{pending,running,done,failed},logs,scripts,hooks,templates}

# Copy files if running from the project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    cp -r "$PROJECT_DIR"/{docker-compose.yml,Dockerfile,CLAUDE.md,.claude} "$HARNESS_DIR/"
    cp -r "$PROJECT_DIR"/scripts/* "$HARNESS_DIR/scripts/"
    cp -r "$PROJECT_DIR"/hooks/* "$HARNESS_DIR/hooks/"
    chmod +x "$HARNESS_DIR"/scripts/*.sh "$HARNESS_DIR"/hooks/*.sh
    echo "Project files copied to $HARNESS_DIR"
fi

chown -R "$AGENT_USER":"$AGENT_USER" "$HARNESS_DIR"

# Install systemd service
if [[ -f "$PROJECT_DIR/templates/agent-harness.service" ]]; then
    cp "$PROJECT_DIR/templates/agent-harness.service" /etc/systemd/system/
    systemctl daemon-reload
    echo "Systemd service installed. Enable with: systemctl enable agent-harness"
fi

# ---------------------------------------------------------------------------
# Network egress rules for Docker
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo " Egress Firewall Rules (apply manually)"
echo "============================================"
echo ""
echo "Run these commands to restrict Docker container egress:"
echo ""
echo "  # Get Docker network subnet (default bridge or agent-net)"
echo "  SUBNET=\$(docker network inspect agent-harness_agent-net -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
echo ""
echo "  # Block all egress from containers"
echo "  sudo iptables -I DOCKER-USER -s \$SUBNET -j DROP"
echo ""
echo "  # Allow GitHub"
echo "  sudo iptables -I DOCKER-USER -s \$SUBNET -d 140.82.112.0/20 -j ACCEPT"
echo "  sudo iptables -I DOCKER-USER -s \$SUBNET -d 192.30.252.0/22 -j ACCEPT"
echo ""
echo "  # Allow npm registry"
echo "  sudo iptables -I DOCKER-USER -s \$SUBNET -d 104.16.0.0/12 -j ACCEPT"
echo ""
echo "  # Allow PyPI"
echo "  sudo iptables -I DOCKER-USER -s \$SUBNET -d 151.101.0.0/16 -j ACCEPT"
echo ""
echo "  # Allow Anthropic API"
echo "  sudo iptables -I DOCKER-USER -s \$SUBNET -d 160.75.0.0/16 -j ACCEPT"
echo ""
echo "  # Allow DNS"
echo "  sudo iptables -I DOCKER-USER -s \$SUBNET -p udp --dport 53 -j ACCEPT"
echo "  sudo iptables -I DOCKER-USER -s \$SUBNET -p tcp --dport 53 -j ACCEPT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo " Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Reboot if NVIDIA driver was freshly installed"
echo "  2. Run 'sudo tailscale up' to join Tailscale network"
echo "  3. Set up SSH keys for the agent user:"
echo "     sudo -u $AGENT_USER ssh-keygen -t ed25519 -C 'agent@runner'"
echo "  4. Add the public key to GitHub as a deploy key"
echo "  5. Create .env file in $HARNESS_DIR:"
echo "     ANTHROPIC_API_KEY=sk-ant-..."
echo "     GITHUB_TOKEN=ghp_..."
echo "     SSH_KEY_PATH=/home/$AGENT_USER/.ssh/id_ed25519"
echo "  6. Build and start:"
echo "     cd $HARNESS_DIR"
echo "     docker compose build"
echo "     docker compose up -d"
echo "  7. Enable auto-start:"
echo "     sudo systemctl enable agent-harness"
echo "     sudo systemctl start agent-harness"
echo ""

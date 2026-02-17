#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - Ubuntu初回起動後の完全自動セットアップ
#
# デュアルブートのUbuntu 24.04で最初に実行するスクリプト。
# これ1本で、OSの初期設定からエージェント起動まで全部やる。
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<user>/agent-harness/main/scripts/bootstrap.sh | sudo bash
#   または:
#   sudo bash scripts/bootstrap.sh
#
# 所要時間: 約15-30分（ネットワーク速度による）
# =============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()    { echo -e "${GREEN}[$(date +%H:%M:%S)] OK${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN${NC} $*"; }
fail()  { echo -e "${RED}[$(date +%H:%M:%S)] FAIL${NC} $*"; exit 1; }

# Must be root
[[ $EUID -eq 0 ]] || fail "Run with sudo: sudo bash bootstrap.sh"

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"
HARNESS_DIR="${AGENT_HOME}/agent-harness"
LOG_FILE="/tmp/bootstrap-$(date +%Y%m%d-%H%M%S).log"

echo -e "${BOLD}${CYAN}"
echo "================================================================"
echo "  24/7 Autonomous Coding Agent - Bootstrap"
echo "  Target: Ubuntu 24.04 + RTX 4090 Dual Boot"
echo "================================================================"
echo -e "${NC}"
echo "Log: $LOG_FILE"
echo ""

exec > >(tee -a "$LOG_FILE") 2>&1

# =========================================================================
# Phase 1: System Base
# =========================================================================
echo -e "\n${BOLD}=== Phase 1/7: System Base ===${NC}"

info "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
ok "System updated"

info "Installing essential packages..."
apt-get install -y -qq \
    curl wget git jq htop tmux unzip bc \
    build-essential software-properties-common \
    ufw fail2ban \
    unattended-upgrades apt-listchanges \
    openssh-server net-tools
ok "Essential packages installed"

# Timezone
timedatectl set-timezone Asia/Tokyo
ok "Timezone set to Asia/Tokyo"

# =========================================================================
# Phase 2: NVIDIA Driver
# =========================================================================
echo -e "\n${BOLD}=== Phase 2/7: NVIDIA GPU ===${NC}"

if nvidia-smi &>/dev/null; then
    ok "NVIDIA driver already installed: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
else
    info "Installing NVIDIA driver..."

    # Add NVIDIA PPA
    add-apt-repository -y ppa:graphics-drivers/ppa 2>/dev/null || true
    apt-get update -qq

    # Install latest recommended driver
    local recommended
    recommended=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | awk '{print $3}' || echo "nvidia-driver-550")
    info "Installing $recommended..."
    apt-get install -y -qq "$recommended"

    ok "NVIDIA driver installed. REBOOT WILL BE NEEDED."
    NEED_REBOOT=true
fi

# NVIDIA Container Toolkit
if ! command -v nvidia-ctk &>/dev/null; then
    info "Installing NVIDIA Container Toolkit..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y -qq nvidia-container-toolkit
    ok "NVIDIA Container Toolkit installed"
else
    ok "NVIDIA Container Toolkit already installed"
fi

# =========================================================================
# Phase 3: Docker
# =========================================================================
echo -e "\n${BOLD}=== Phase 3/7: Docker ===${NC}"

if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed"
else
    ok "Docker already installed: $(docker --version)"
fi

# Configure NVIDIA runtime for Docker
nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
systemctl enable docker
systemctl restart docker
ok "Docker configured with NVIDIA runtime"

# =========================================================================
# Phase 4: Agent User
# =========================================================================
echo -e "\n${BOLD}=== Phase 4/7: Agent User ===${NC}"

if ! id "$AGENT_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$AGENT_USER"
    ok "User '$AGENT_USER' created"
else
    ok "User '$AGENT_USER' already exists"
fi

# Add to docker group
usermod -aG docker "$AGENT_USER"
ok "Added to docker group"

# Generate SSH key
if [[ ! -f "${AGENT_HOME}/.ssh/id_ed25519" ]]; then
    sudo -u "$AGENT_USER" mkdir -p "${AGENT_HOME}/.ssh"
    sudo -u "$AGENT_USER" ssh-keygen -t ed25519 -C "agent@$(hostname)" -N "" -f "${AGENT_HOME}/.ssh/id_ed25519"
    ok "SSH key generated"
    echo ""
    echo -e "${YELLOW}========================================="
    echo "  IMPORTANT: Add this SSH public key to GitHub!"
    echo "  Settings → SSH Keys → New SSH Key"
    echo "=========================================${NC}"
    echo ""
    cat "${AGENT_HOME}/.ssh/id_ed25519.pub"
    echo ""
else
    ok "SSH key already exists"
fi

# =========================================================================
# Phase 5: Security Hardening
# =========================================================================
echo -e "\n${BOLD}=== Phase 5/7: Security ===${NC}"

# Firewall
info "Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "SSH"
ufw allow 41641/udp comment "Tailscale"
ufw --force enable
ok "Firewall: SSH + Tailscale only"

# Fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
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
ok "Fail2ban configured"

# Disable sleep/suspend
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null
ok "Sleep/suspend disabled"

# Auto security updates
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null
ok "Automatic security updates enabled"

# =========================================================================
# Phase 6: Tailscale
# =========================================================================
echo -e "\n${BOLD}=== Phase 6/7: Tailscale ===${NC}"

if ! command -v tailscale &>/dev/null; then
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed"
    echo -e "${YELLOW}Run 'sudo tailscale up' to connect${NC}"
else
    ok "Tailscale already installed"
fi

# =========================================================================
# Phase 7: Agent Harness
# =========================================================================
echo -e "\n${BOLD}=== Phase 7/7: Agent Harness ===${NC}"

# Clone the repo (or copy if running from the repo directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    # Running from within the repo
    info "Copying harness from $PROJECT_DIR..."
    if [[ "$PROJECT_DIR" != "$HARNESS_DIR" ]]; then
        cp -r "$PROJECT_DIR" "$HARNESS_DIR"
    fi
else
    # Need to clone
    info "Clone the agent-harness repo:"
    echo -e "${YELLOW}"
    echo "  sudo -u $AGENT_USER git clone <your-repo-url> $HARNESS_DIR"
    echo -e "${NC}"
fi

if [[ -d "$HARNESS_DIR" ]]; then
    # Fix ownership
    chown -R "$AGENT_USER":"$AGENT_USER" "$HARNESS_DIR"

    # Make scripts executable
    chmod +x "$HARNESS_DIR"/scripts/*.sh "$HARNESS_DIR"/hooks/*.sh 2>/dev/null || true

    # Create job directories
    sudo -u "$AGENT_USER" mkdir -p "$HARNESS_DIR"/jobs/{pending,running,done,failed} "$HARNESS_DIR"/logs

    # Install systemd service
    if [[ -f "$HARNESS_DIR/templates/agent-harness.service" ]]; then
        cp "$HARNESS_DIR/templates/agent-harness.service" /etc/systemd/system/
        systemctl daemon-reload
        ok "Systemd service installed"
    fi

    # Install bash aliases
    if [[ -f "$HARNESS_DIR/templates/bashrc-aliases.sh" ]]; then
        if ! grep -q "agent-harness" "${AGENT_HOME}/.bashrc" 2>/dev/null; then
            echo "source ${HARNESS_DIR}/templates/bashrc-aliases.sh" >> "${AGENT_HOME}/.bashrc"
            ok "Bash aliases installed"
        fi
    fi

    # Create .env if not exists
    if [[ ! -f "$HARNESS_DIR/.env" ]]; then
        cp "$HARNESS_DIR/.env.example" "$HARNESS_DIR/.env" 2>/dev/null || true
        warn ".env created from example - EDIT IT WITH YOUR API KEYS"
    fi

    ok "Harness directory ready: $HARNESS_DIR"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "================================================================"
echo "  Bootstrap Complete!"
echo "================================================================"
echo -e "${NC}"
echo ""
echo "System Info:"
echo "  Hostname:  $(hostname)"
echo "  IP:        $(hostname -I | awk '{print $1}')"
echo "  GPU:       $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'driver needs reboot')"
echo "  Docker:    $(docker --version 2>/dev/null || echo 'installed')"
echo "  Tailscale: $(tailscale status 2>/dev/null | head -1 || echo 'installed, run: sudo tailscale up')"
echo ""

if [[ "${NEED_REBOOT:-false}" == "true" ]]; then
    echo -e "${RED}${BOLD}REBOOT REQUIRED for NVIDIA driver!${NC}"
    echo "  Run: sudo reboot"
    echo "  After reboot, continue with the remaining steps below."
    echo ""
fi

echo "Remaining manual steps:"
echo ""
echo "  1. Add SSH key to GitHub (if not done):"
echo "     cat ${AGENT_HOME}/.ssh/id_ed25519.pub"
echo ""
echo "  2. Clone the harness repo (if not auto-copied):"
echo "     sudo -u $AGENT_USER git clone git@github.com:<you>/agent-harness.git $HARNESS_DIR"
echo ""
echo "  3. Configure API keys:"
echo "     sudo -u $AGENT_USER nano $HARNESS_DIR/.env"
echo "     # Set ANTHROPIC_API_KEY and GITHUB_TOKEN"
echo ""
echo "  4. Build and start the agent:"
echo "     cd $HARNESS_DIR"
echo "     sudo -u $AGENT_USER docker compose build"
echo "     sudo -u $AGENT_USER docker compose up -d"
echo ""
echo "  5. Apply network egress restrictions:"
echo "     sudo bash $HARNESS_DIR/scripts/setup-egress.sh"
echo "     sudo bash $HARNESS_DIR/scripts/persist-iptables.sh auto"
echo ""
echo "  6. Enable auto-start on boot:"
echo "     sudo systemctl enable agent-harness"
echo ""
echo "  7. (Optional) Connect Tailscale:"
echo "     sudo tailscale up"
echo ""
echo "  8. (Optional) Setup Ollama for local LLM:"
echo "     bash $HARNESS_DIR/scripts/setup-ollama.sh"
echo ""
echo "  9. Submit your first job:"
echo "     bash $HARNESS_DIR/scripts/create-job.sh \\"
echo "       --repo git@github.com:your-org/repo.git \\"
echo "       --task 'Add hello world endpoint' \\"
echo "       --test 'npm test'"
echo ""
echo "Full log: $LOG_FILE"
echo ""

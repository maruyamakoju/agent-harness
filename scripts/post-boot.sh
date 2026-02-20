#!/usr/bin/env bash
# =============================================================================
# post-boot.sh - Ubuntu起動後のワンショットセットアップ
#
# Ubuntu 24.04 のターミナルでこれ1行でOK:
#
#   curl -fsSL https://raw.githubusercontent.com/maruyamakoju/agent-harness/main/scripts/post-boot.sh | sudo bash
#
# または USBからコピー済みなら:
#   sudo bash /media/agent/USB/agent-harness/scripts/post-boot.sh
#
# やること:
#   1. bootstrap.sh (OS設定、NVIDIA、Docker、Tailscale)
#   2. リポジトリ clone
#   3. .env 配置
#   4. Docker image build
#   5. コンテナ起動
#   6. Claude 認証の案内表示
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${CYAN}>>>${NC} $*"; }
ok()    { echo -e "${GREEN}>>>${NC} $*"; }
warn()  { echo -e "${YELLOW}>>>${NC} $*"; }

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash post-boot.sh"; exit 1; }

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"
HARNESS_DIR="${AGENT_HOME}/agent-harness"
REPO_URL="https://github.com/maruyamakoju/agent-harness.git"

echo -e "${BOLD}${CYAN}"
echo "========================================================"
echo "  24/7 Autonomous Coding Agent - Post-Boot Setup"
echo "  Target: Ubuntu 24.04 + RTX 4090 + Claude Max \$200/mo"
echo "========================================================"
echo -e "${NC}"

# =========================================================================
# Step 1: Bootstrap (OS, NVIDIA, Docker, etc.)
# =========================================================================
info "Step 1/6: Running bootstrap..."

# Minimal bootstrap inline (in case we're running from curl)
apt-get update -qq
apt-get install -y -qq git curl jq

# Create agent user if needed
if ! id "$AGENT_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$AGENT_USER"
    ok "User '$AGENT_USER' created"
fi

# =========================================================================
# Step 2: Clone the repo
# =========================================================================
info "Step 2/6: Cloning agent-harness..."

if [[ -d "$HARNESS_DIR/.git" ]]; then
    ok "Already cloned at $HARNESS_DIR"
    cd "$HARNESS_DIR"
    sudo -u "$AGENT_USER" git pull 2>/dev/null || true
else
    # Check if there's a USB copy
    USB_COPY=""
    for mount in /media/*/agent-harness /mnt/*/agent-harness /tmp/agent-harness; do
        if [[ -f "$mount/docker-compose.yml" ]]; then
            USB_COPY="$mount"
            break
        fi
    done

    if [[ -n "$USB_COPY" ]]; then
        info "Found USB copy at $USB_COPY, copying..."
        cp -r "$USB_COPY" "$HARNESS_DIR"
    else
        sudo -u "$AGENT_USER" git clone "$REPO_URL" "$HARNESS_DIR"
    fi
    ok "Repo ready at $HARNESS_DIR"
fi

chown -R "$AGENT_USER":"$AGENT_USER" "$HARNESS_DIR"
chmod +x "$HARNESS_DIR"/scripts/*.sh "$HARNESS_DIR"/hooks/*.sh 2>/dev/null || true

# =========================================================================
# Step 3: Run full bootstrap from the repo
# =========================================================================
info "Step 3/6: Running full bootstrap (NVIDIA, Docker, Tailscale, security)..."
bash "$HARNESS_DIR/scripts/bootstrap.sh"

# =========================================================================
# Step 4: GitHub CLI auth for the agent user
# =========================================================================
info "Step 4/6: Setting up GitHub authentication..."

# Check if .env exists and has a valid token
if [[ -f "$HARNESS_DIR/.env" ]]; then
    source "$HARNESS_DIR/.env" 2>/dev/null || true
fi

if [[ -z "${GITHUB_TOKEN:-}" || "$GITHUB_TOKEN" == *"XXXX"* ]]; then
    warn "GITHUB_TOKEN not set. Setting up gh CLI auth..."
    echo ""
    echo -e "${YELLOW}GitHub authentication needed for the agent.${NC}"
    echo "Run this as the agent user:"
    echo ""
    echo "  sudo -u $AGENT_USER gh auth login"
    echo ""
    echo "Then update the .env:"
    echo "  sudo -u $AGENT_USER nano $HARNESS_DIR/.env"
    echo ""
else
    # Configure gh CLI with the token.
    # Pass token via stdin (not command-line args) to avoid exposure in ps aux.
    echo "$GITHUB_TOKEN" | sudo -u "$AGENT_USER" gh auth login --with-token 2>/dev/null || true
    ok "GitHub token configured"
fi

# =========================================================================
# Step 5: Docker build and start
# =========================================================================
info "Step 5/6: Building and starting Docker container..."

# Need to check if NVIDIA driver is loaded
if nvidia-smi &>/dev/null; then
    ok "NVIDIA GPU detected: $(nvidia-smi --query-gpu=name --format=csv,noheader)"

    cd "$HARNESS_DIR"
    sudo -u "$AGENT_USER" docker compose build
    sudo -u "$AGENT_USER" docker compose up -d
    ok "Container started"
else
    warn "NVIDIA driver not loaded. Reboot first, then re-run:"
    warn "  sudo bash $HARNESS_DIR/scripts/post-boot.sh"
    echo ""
    echo -e "${RED}${BOLD}REBOOT NOW: sudo reboot${NC}"
    echo "After reboot, run this script again."
    exit 0
fi

# =========================================================================
# Step 5.5: Setup cron jobs (watchdog + cleanup)
# =========================================================================
info "Setting up cron jobs..."

# Install watchdog (every 5 min) and cleanup (daily 3am) for agent user
CRON_TMP=$(mktemp)
trap 'rm -f "$CRON_TMP" "${CRON_TMP}.clean"' EXIT
crontab -u "$AGENT_USER" -l 2>/dev/null > "$CRON_TMP" || true
# Remove old entries if any
grep -v "agent-harness" "$CRON_TMP" > "${CRON_TMP}.clean" || true
mv "${CRON_TMP}.clean" "$CRON_TMP"
# Add new entries
echo "*/5 * * * * HARNESS_DIR=$HARNESS_DIR bash $HARNESS_DIR/scripts/watchdog.sh >> $HARNESS_DIR/logs/watchdog.log 2>&1" >> "$CRON_TMP"
echo "0 3 * * * HARNESS_DIR=$HARNESS_DIR bash $HARNESS_DIR/scripts/cleanup.sh >> $HARNESS_DIR/logs/cleanup.log 2>&1" >> "$CRON_TMP"
crontab -u "$AGENT_USER" "$CRON_TMP"
rm -f "$CRON_TMP"
ok "Cron jobs installed (watchdog: 5min, cleanup: daily 3am)"

# =========================================================================
# Step 6: Instructions for Claude auth
# =========================================================================
info "Step 6/6: Almost done!"

echo ""
echo -e "${BOLD}${GREEN}"
echo "========================================================"
echo "  Setup Complete!"
echo "========================================================"
echo -e "${NC}"
echo ""
echo -e "${BOLD}Last step - Claude Code にログイン:${NC}"
echo ""
echo "  bash $HARNESS_DIR/scripts/setup-claude-auth.sh"
echo ""
echo "  → 表示されるURLをブラウザで開く"
echo "  → Anthropicアカウント（Max \$200プラン）でログイン"
echo "  → 認証完了後、エージェントが自動稼働開始"
echo ""
echo -e "${BOLD}動作確認:${NC}"
echo ""
echo "  # ステータス確認"
echo "  bash $HARNESS_DIR/scripts/monitor.sh"
echo ""
echo "  # テストジョブ投入"
echo "  bash $HARNESS_DIR/scripts/create-job.sh \\"
echo "    --repo git@github.com:maruyamakoju/agent-harness.git \\"
echo "    --task 'READMEに日本語の説明を追加' \\"
echo "    --time-budget 600"
echo ""
echo -e "${BOLD}リモートアクセス (Optional):${NC}"
echo "  sudo tailscale up"
echo ""

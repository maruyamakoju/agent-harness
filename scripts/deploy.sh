#!/usr/bin/env bash
# =============================================================================
# deploy.sh - Full deployment script
# Handles everything from first-time setup to updates
#
# Usage:
#   First time:  sudo bash scripts/deploy.sh --full
#   Update:      bash scripts/deploy.sh --update
#   Rebuild:     bash scripts/deploy.sh --rebuild
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

MODE="${1:---help}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
    info "Running pre-flight checks..."

    # .env file
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        error ".env file not found!"
        echo ""
        echo "  cp .env.example .env"
        echo "  # Edit .env with your ANTHROPIC_API_KEY and GITHUB_TOKEN"
        echo ""
        exit 1
    fi

    # Check required env vars
    source "$PROJECT_DIR/.env"
    if [[ -z "${GITHUB_TOKEN:-}" || "$GITHUB_TOKEN" == *"XXXX"* ]]; then
        error "GITHUB_TOKEN not configured in .env"
        exit 1
    fi
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        info "ANTHROPIC_API_KEY not set — using Max plan auth (claude login)"
    fi

    # Docker
    if ! command -v docker &>/dev/null; then
        error "Docker is not installed. Run: sudo bash scripts/setup-host.sh"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        error "Docker daemon is not running"
        exit 1
    fi

    # Docker Compose
    if ! docker compose version &>/dev/null 2>&1; then
        error "Docker Compose not found"
        exit 1
    fi

    ok "Pre-flight checks passed"
}

# ---------------------------------------------------------------------------
# Full deployment (first time)
# ---------------------------------------------------------------------------
deploy_full() {
    echo -e "${BOLD}${CYAN}"
    echo "============================================"
    echo " Full Deployment - 24/7 Autonomous Agent"
    echo "============================================"
    echo -e "${NC}"

    if [[ $EUID -ne 0 ]]; then
        error "Full deployment requires root. Run: sudo bash scripts/deploy.sh --full"
        exit 1
    fi

    # Step 1: Host setup
    info "Step 1/6: Host setup"
    bash "$SCRIPT_DIR/setup-host.sh"
    ok "Host setup complete"

    # Step 2: Pre-flight
    info "Step 2/6: Pre-flight checks"
    preflight

    # Step 3: Build
    info "Step 3/6: Building Docker image"
    cd "$PROJECT_DIR"
    docker compose build --no-cache
    ok "Docker image built"

    # Step 4: Start
    info "Step 4/6: Starting agent"
    docker compose up -d
    ok "Agent container started"

    # Step 5: Egress rules
    info "Step 5/6: Configuring egress firewall"
    sleep 5  # Wait for Docker network to initialize
    local network_name
    network_name=$(docker network ls --filter "name=agent-net" --format "{{.Name}}" 2>/dev/null | head -1)
    if [[ -n "$network_name" ]]; then
        bash "$SCRIPT_DIR/setup-egress.sh" "$network_name"
        bash "$SCRIPT_DIR/persist-iptables.sh" save
        bash "$SCRIPT_DIR/persist-iptables.sh" auto
        ok "Egress firewall configured and persisted"
    else
        warn "Could not find agent network. Egress rules not applied."
    fi

    # Step 6: Enable systemd
    info "Step 6/6: Enabling systemd services"
    if [[ -f "$PROJECT_DIR/templates/agent-harness.service" ]]; then
        cp "$PROJECT_DIR/templates/agent-harness.service" /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable agent-harness.service
        ok "Systemd service enabled"
    fi

    echo ""
    echo -e "${BOLD}${GREEN}============================================"
    echo " Deployment Complete!"
    echo "============================================${NC}"
    echo ""
    echo "The agent is now running. Useful commands:"
    echo ""
    echo "  # Check status"
    echo "  docker compose logs -f"
    echo "  bash scripts/monitor.sh watch"
    echo ""
    echo "  # Submit a job"
    echo "  bash scripts/create-job.sh --repo <git-url> --task <description>"
    echo ""
    echo "  # View logs"
    echo "  bash scripts/view-job-log.sh <job-id>"
    echo ""
}

# ---------------------------------------------------------------------------
# Update deployment (pull changes, rebuild)
# ---------------------------------------------------------------------------
deploy_update() {
    echo -e "${BOLD}${CYAN}Updating agent system...${NC}"

    preflight

    cd "$PROJECT_DIR"

    info "Pulling latest changes..."
    git pull 2>/dev/null || warn "Not a git repo or no remote configured"

    info "Rebuilding Docker image..."
    docker compose build

    info "Restarting agent..."
    docker compose down --timeout 120
    docker compose up -d

    ok "Update complete. Agent restarted."
}

# ---------------------------------------------------------------------------
# Rebuild (force rebuild without cache)
# ---------------------------------------------------------------------------
deploy_rebuild() {
    echo -e "${BOLD}${CYAN}Rebuilding agent system...${NC}"

    preflight

    cd "$PROJECT_DIR"

    info "Stopping agent..."
    docker compose down --timeout 120 2>/dev/null || true

    info "Rebuilding Docker image (no cache)..."
    docker compose build --no-cache

    info "Starting agent..."
    docker compose up -d

    ok "Rebuild complete. Agent restarted."
}

# ---------------------------------------------------------------------------
# Status check
# ---------------------------------------------------------------------------
deploy_status() {
    echo -e "${BOLD}${CYAN}Agent System Status${NC}"
    echo ""

    # Docker container
    info "Container status:"
    docker compose ps 2>/dev/null || echo "  Container not running"
    echo ""

    # Health
    info "Health check:"
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' coding-agent 2>/dev/null || echo "unknown")
    if [[ "$health" == "healthy" ]]; then
        ok "Container is healthy"
    elif [[ "$health" == "unhealthy" ]]; then
        error "Container is unhealthy"
    else
        warn "Health status: $health"
    fi
    echo ""

    # Heartbeat
    if [[ -f "$PROJECT_DIR/logs/heartbeat.json" ]]; then
        info "Heartbeat:"
        jq . "$PROJECT_DIR/logs/heartbeat.json"
    fi
    echo ""

    # Recent logs
    info "Recent container logs:"
    docker compose logs --tail 10 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------
deploy_stop() {
    echo -e "${BOLD}${YELLOW}Stopping agent system...${NC}"
    cd "$PROJECT_DIR"
    docker compose down --timeout 120
    ok "Agent stopped"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$MODE" in
    --full)     deploy_full ;;
    --update)   deploy_update ;;
    --rebuild)  deploy_rebuild ;;
    --status)   deploy_status ;;
    --stop)     deploy_stop ;;
    --preflight) preflight ;;
    *)
        echo "Usage: deploy.sh <command>"
        echo ""
        echo "Commands:"
        echo "  --full       First-time full deployment (requires sudo)"
        echo "  --update     Pull changes and restart"
        echo "  --rebuild    Force rebuild without cache"
        echo "  --status     Show current status"
        echo "  --stop       Stop the agent"
        echo "  --preflight  Run pre-flight checks only"
        ;;
esac

#!/usr/bin/env bash
# =============================================================================
# setup-claude-auth.sh - Claude Code Max Plan Authentication
#
# Max プランでは API キーではなく、アカウントログインで認証する。
# このスクリプトはDockerコンテナ内で 'claude login' を実行し、
# 認証セッションを claude-config volume に永続化する。
#
# Usage:
#   # コンテナが起動している状態で:
#   bash scripts/setup-claude-auth.sh
#
# 初回のみ対話的な操作が必要（ブラウザでの認証）。
# 以降はセッションが volume に保存されるので再認証不要。
# =============================================================================
set -euo pipefail

CONTAINER_NAME="coding-agent"

echo "============================================"
echo " Claude Code Max Plan - Authentication Setup"
echo "============================================"
echo ""

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container '$CONTAINER_NAME' is not running."
    echo ""
    echo "Start it first:"
    echo "  docker compose up -d"
    echo ""
    echo "Note: The first time, the agent-loop will fail because"
    echo "Claude Code is not authenticated yet. That's expected."
    echo "Run this script to authenticate, then it will work."
    exit 1
fi

echo "This will open Claude Code login inside the container."
echo "You'll need to:"
echo "  1. Copy the URL that appears"
echo "  2. Open it in your browser"
echo "  3. Log in with your Anthropic account (Max plan)"
echo "  4. Authorize the CLI"
echo ""
echo "The session will be saved in a Docker volume and persist"
echo "across container restarts."
echo ""
read -p "Press Enter to continue..."

# Run claude login interactively inside the container
docker exec -it "$CONTAINER_NAME" claude login

echo ""
echo "============================================"

# Verify authentication
echo "Verifying authentication..."
if docker exec "$CONTAINER_NAME" claude -p --output-format json "Say 'auth ok'" > /dev/null 2>&1; then
    echo ""
    echo "SUCCESS! Claude Code is authenticated."
    echo ""
    echo "The agent loop will now be able to process jobs."
    echo "Authentication is persisted in the 'claude-config' Docker volume."
    echo ""
    echo "If you ever need to re-authenticate:"
    echo "  bash scripts/setup-claude-auth.sh"
else
    echo ""
    echo "WARNING: Authentication verification failed."
    echo "Try running 'claude login' manually:"
    echo "  docker exec -it $CONTAINER_NAME claude login"
fi

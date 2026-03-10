#!/usr/bin/env bash
# =============================================================================
# init.sh - Session initialization script for {{PRODUCT_NAME}}
# Run at the start of each agent session to bootstrap the dev environment.
# The agent should customize this file during the SCAFFOLD phase.
# =============================================================================
set -euo pipefail

echo "[init.sh] Initializing development environment for {{PRODUCT_NAME}}..."

# --- Dependency Installation ---
# Uncomment and customize based on project type:
# npm ci
# pip install -r requirements.txt
# go mod download
# cargo build

# --- Database / Service Setup ---
# docker compose up -d
# npx prisma migrate dev

# --- Health Check ---
# curl -sf http://localhost:3000/health || echo "Warning: health check failed"

echo "[init.sh] Environment ready."

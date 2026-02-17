#!/usr/bin/env bash
# =============================================================================
# setup-ollama.sh - Install Ollama and pull recommended models
# Run on the host machine (not inside Docker)
# Usage: bash setup-ollama.sh
# =============================================================================
set -euo pipefail

echo "============================================"
echo " Ollama Setup for Local LLM Offloading"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Install Ollama
# ---------------------------------------------------------------------------
if ! command -v ollama &>/dev/null; then
    echo "[1/3] Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    echo "Ollama installed"
else
    echo "[1/3] Ollama already installed"
fi

# ---------------------------------------------------------------------------
# Start Ollama service
# ---------------------------------------------------------------------------
echo "[2/3] Starting Ollama service..."
if systemctl is-active --quiet ollama 2>/dev/null; then
    echo "Ollama service is already running"
else
    sudo systemctl enable ollama
    sudo systemctl start ollama
    sleep 3
    echo "Ollama service started"
fi

# Verify GPU access
echo ""
echo "GPU Status:"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || echo "  WARNING: nvidia-smi not available"
echo ""

# ---------------------------------------------------------------------------
# Pull models
# ---------------------------------------------------------------------------
echo "[3/3] Pulling recommended models..."
echo ""

MODELS=(
    "deepseek-coder-v2:16b"    # Code review / generation (~16GB VRAM)
    "phi3.5:latest"             # Lightweight classification (~3GB VRAM)
)

for model in "${MODELS[@]}"; do
    echo "Pulling: $model"
    ollama pull "$model" || echo "  WARNING: Failed to pull $model"
    echo ""
done

echo "============================================"
echo " Ollama Setup Complete"
echo "============================================"
echo ""
echo "Available models:"
ollama list 2>/dev/null || echo "  (run 'ollama list' to check)"
echo ""
echo "Test with:"
echo "  ollama run deepseek-coder-v2:16b 'Write a hello world in Python'"
echo ""
echo "Ollama API endpoint: http://localhost:11434"
echo "From Docker containers: http://host.docker.internal:11434"

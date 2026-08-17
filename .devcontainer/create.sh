#!/usr/bin/env bash
set -euo pipefail

echo "=== Codespace AI Provisioning ==="

# Install base tools as root
echo "Installing base tools..."
apt-get update
apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    ripgrep \
    unzip \
    build-essential \
    git \
    apt-transport-https \
    ca-certificates \
    gnupg

# Install Node.js (v20) and npm using nodesource
echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Install Python 3 and pip
echo "Installing Python 3 and pip..."
apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv

# Install OpenCode (GitHub's AI coding tool)
echo "Installing OpenCode..."
if [ -n "${OPENCODE_TOKEN:-}" ]; then
    echo "OpenCode token provided via Codespaces secret, skipping install"
else
    # Install OpenCode from the official source
    curl -fsSL https://raw.githubusercontent.com/openocode/cli/main/scripts/install.sh | bash 2>/dev/null || true
fi

# Install GitHub CLI (already in Dockerfile, but ensure it's available)
echo "Ensuring GitHub CLI is installed..."
if ! command -v gh &>/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update && apt-get install -y gh
fi

# Configure git
echo "Configuring git..."
git config --global pull.rebase true
git config --global init.defaultBranch main

# Install useful global npm packages
echo "Installing global npm packages..."
npm install -g pnpm

# Set up zsh if available
SHELL_NAME="${SHELL##*/}"
if [ "$SHELL_NAME" != "zsh" ]; then
    apt-get install -y zsh 2>/dev/null || true
    chsh -s $(which zsh) 2>/dev/null || true
fi

# OpenRouter support - use the OPENROUTER_API_KEY environment variable
# (provided via Codespaces secret, do NOT persist to /etc/environment)
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    echo "OpenRouter API key is available in environment"
    # Export for this session only - do NOT write to /etc/environment
    export OPENROUTER_API_KEY="${OPENROUTER_API_KEY}"
else
    echo "OpenRouter API key not set - set OPENROUTER_API_KEY Codespaces secret"
fi

# Create project directories (repo-relative, not hardcoded)
mkdir -p "${containerWorkspaceFolder:-/workspace}"

echo "=== Provisioning Complete ==="
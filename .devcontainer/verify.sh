#!/usr/bin/env bash
set -euo pipefail

echo "=== Codespace AI Verification ==="

# Verify OpenCode is installed and accessible
if command -v opencode &>/dev/null; then
    echo "OpenCode: $(opencode --version 2>/dev/null || echo 'installed')"
else
    echo "WARNING: OpenCode not found in PATH"
fi

# Verify GitHub CLI is installed and working
if command -v gh &>/dev/null; then
    echo "GitHub CLI: $(gh version 2>/dev/null | head -1)"
    gh auth status 2>/dev/null || echo "GH not authenticated"
else
    echo "WARNING: GitHub CLI not found"
fi

# Verify Node.js and npm
if command -v node &>/dev/null; then
    NODE_VERSION=$(node --version)
    NPM_VERSION=$(npm --version)
    echo "Node.js: $NODE_VERSION, npm: $NPM_VERSION"
else
    echo "WARNING: Node.js not found"
fi

# Verify Python and pip
if command -v python3 &>/dev/null; then
    PYTHON_VERSION=$(python3 --version 2>&1)
    PIP_VERSION=$(pip3 --version 2>&1 | awk '{print $2}')
    echo "Python: $PYTHON_VERSION, pip: $PIP_VERSION"
else
    echo "WARNING: Python 3 not found"
fi

# Verify Docker access (if Docker is available)
if command -v docker &>/dev/null; then
    echo "Docker: $(docker --version 2>/dev/null || echo 'available')"
    docker info >/dev/null 2>&1 && echo "Docker daemon: running" || echo "Docker daemon: not accessible"
else
    echo "WARNING: Docker not found (install Docker Desktop or use Codespaces docker)"
fi

# Verify ripgrep/jq are available
for tool in ripgrep jq; do
    if command -v "$tool" &>/dev/null; then
        echo "$tool: available"
    else
        echo "WARNING: $tool not found"
    fi
done

# Verify OpenRouter API key is available (not persisted, just in environment)
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    echo "OpenRouter API key: available in environment"
else
    echo "OpenRouter API key: not set (set OPENROUTER_API_KEY Codespaces secret)"
fi

# Verify git configuration
echo "Git config pull: $(git config --global pull.rebase)"
echo "Git init branch: $(git config --global init.defaultBranch)"

echo "=== Verification Complete ==="
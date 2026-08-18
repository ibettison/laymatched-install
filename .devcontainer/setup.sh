#!/usr/bin/env bash
set -euo pipefail

echo "=== Codespace AI bootstrap ==="

if command -v opencode >/dev/null 2>&1; then
  echo "OpenCode already installed: $(opencode --version 2>/dev/null || true)"
else
  echo "Installing OpenCode..."
  curl -fsSL https://opencode.ai/install | bash
fi

# Make the common OpenCode install location available in future shells.
if [ -d "$HOME/.opencode/bin" ]; then
  case ":$PATH:" in
    *":$HOME/.opencode/bin:"*) ;;
    *) export PATH="$HOME/.opencode/bin:$PATH" ;;
  esac
fi

if command -v opencode >/dev/null 2>&1; then
  echo "OpenCode ready: $(opencode --version 2>/dev/null || true)"
else
  echo "WARNING: OpenCode installed but is not yet on PATH. Open a new terminal before running opencode."
fi

if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  echo "OpenRouter secret: available"
else
  echo "OpenRouter secret: NOT available"
  echo "Add OPENROUTER_API_KEY in GitHub Settings > Codespaces > Secrets and allow this repository."
fi

echo "=== Bootstrap complete ==="

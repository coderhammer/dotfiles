#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Claude Code
mkdir -p ~/.claude

# Settings
cp "$DOTFILES_DIR/claude/settings.json" ~/.claude/settings.json
echo "✓ Claude settings"

# Credentials (via secret env variable)
if [ -n "${CLAUDE_CREDENTIALS:-}" ]; then
  echo "$CLAUDE_CREDENTIALS" > ~/.claude/.credentials.json
  echo "✓ Claude credentials"
else
  echo "⚠ CLAUDE_CREDENTIALS not set, skipping"
fi

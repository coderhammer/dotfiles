#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Claude Code
mkdir -p ~/.claude

# Settings
cp "$DOTFILES_DIR/claude/settings.json" ~/.claude/settings.json
echo "✓ Claude settings"

# Auth: long-lived OAuth token from `claude setup-token`.
# Passed as a secret env var at install time, written to a 0600 file that
# zsh sources on every shell start (so `claude` never prompts to re-login).
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  mkdir -p ~/.config/claude
  ( umask 177; printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN" > ~/.config/claude/token.env )
  echo "✓ Claude OAuth token"
else
  echo "⚠ CLAUDE_CODE_OAUTH_TOKEN not set, skipping"
fi

# Skip onboarding wizard on first launch
python3 - <<'EOF'
import json, os

path = os.path.expanduser("~/.claude.json")
patch = {"hasCompletedOnboarding": True, "lastOnboardingVersion": "2.1.92"}

data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)

data.update(patch)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
EOF
echo "✓ Claude onboarding skipped"

# Zsh (idempotent: append once, guarded by a marker)
ZSH_MARKER="# >>> dotfiles zsh >>>"
if grep -qF "$ZSH_MARKER" ~/.zshrc 2>/dev/null; then
  echo "✓ Zsh config (already present)"
else
  {
    echo ""              # leading newline: existing ~/.zshrc may lack a trailing one,
    echo "$ZSH_MARKER"   # which would otherwise glue the marker onto the last line
    cat "$DOTFILES_DIR/zsh/.zshrc"
    echo "# <<< dotfiles zsh <<<"
  } >> ~/.zshrc
  echo "✓ Zsh config"
fi

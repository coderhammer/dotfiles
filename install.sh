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

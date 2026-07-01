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
  ( umask 177; printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q
' "$CLAUDE_CODE_OAUTH_TOKEN" > ~/.config/claude/token.env )
  echo "✓ Claude OAuth token"
else
  echo "⚠ CLAUDE_CODE_OAUTH_TOKEN not set, skipping"
fi

# gcloud: write ADC user credentials from env var, configure CLI to use them.
# GOOGLE_APPLICATION_CREDENTIALS_JSON holds the authorized_user JSON (refresh token).
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON:-}" ]; then
  mkdir -p ~/.config/gcloud
  CRED_FILE=~/.config/gcloud/application_default_credentials.json
  # The secret sometimes arrives wrapped in an extra layer of quotes or
  # JSON-string-encoded (each " became \"). Normalize it and validate that the
  # result is real JSON before writing, so a malformed secret fails loudly
  # instead of silently producing an invalid credentials file.
  if GOOGLE_APPLICATION_CREDENTIALS_JSON="$GOOGLE_APPLICATION_CREDENTIALS_JSON" \
     CRED_FILE="$CRED_FILE" python3 - <<'EOF'
import json, os

raw = os.environ["GOOGLE_APPLICATION_CREDENTIALS_JSON"]
path = os.environ["CRED_FILE"]

def normalize(s):
    s = s.strip()
    # Peel up to two layers: a JSON string that encodes the JSON (double-encoded),
    # or plain surrounding quotes pasted around the object.
    for _ in range(2):
        try:
            obj = json.loads(s)
        except json.JSONDecodeError:
            return None
        if isinstance(obj, dict):
            return obj          # got the actual credentials object
        if isinstance(obj, str):
            s = obj             # unwrapped one layer, try again
            continue
        return None
    return None

obj = normalize(raw)
if obj is None:
    raise SystemExit("could not parse GOOGLE_APPLICATION_CREDENTIALS_JSON as JSON")

fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(obj, f)
EOF
  then
    gcloud config set auth/credential_file_override "$CRED_FILE" --quiet 2>/dev/null || true
    ( umask 177; echo 'export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcloud/application_default_credentials.json"' > ~/.config/gcloud/auth.env )
    echo "✓ gcloud auth"
  else
    echo "⚠ GOOGLE_APPLICATION_CREDENTIALS_JSON is not valid JSON, skipping gcloud auth"
  fi
else
  echo "⚠ GOOGLE_APPLICATION_CREDENTIALS_JSON not set, skipping"
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

#!/usr/bin/env bash
#
# dotfiles install script.
#
# NOTE ON SECRETS & SHELL QUOTING
# -------------------------------
# Some dotfiles runners do NOT honor the shebang and instead interpolate the
# secret *values* into a shell command, e.g.  `zsh -c "SECRET=<value> ./install.sh"`.
# If a secret value contains a shell-special character (a single quote ', a
# double quote ", a backslash \ — common in double-encoded JSON) the shell
# fails to parse the command *before this script ever runs*. That surfaces as:
#
#     zsh:1: unmatched '
#     Dotfiles install script exited with 1
#
# with zero output from this script. The robust fix is to store such secrets
# base64-encoded (charset [A-Za-z0-9+/=] has no shell-special chars) and let
# this script decode them. For each secret FOO we accept FOO_B64 (preferred)
# or the raw FOO.

# Re-exec under bash if started by another shell (so bashisms like `printf %q`
# and ${BASH_SOURCE} behave). Only possible when $0 points at a real file.
if [ -z "${BASH_VERSION:-}" ] && [ -f "$0" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging / verbosity
# ---------------------------------------------------------------------------
log() { printf '%s\n' "$*"; }
dbg() { printf '  · %s\n' "$*" >&2; }   # diagnostics go to stderr
# Full command trace opt-in:  DOTFILES_DEBUG=x
case "${DOTFILES_DEBUG:-}" in
  x|trace|xtrace) set -x ;;
esac

# Resolve this script's directory portably (bash & zsh; run as a path or not).
# ${BASH_SOURCE:-$0} avoids the `set -u` "BASH_SOURCE: parameter not set"
# crash under zsh, where BASH_SOURCE does not exist.
SELF="${BASH_SOURCE:-$0}"
DOTFILES_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || true)"
if [ -z "${DOTFILES_DIR:-}" ] || [ ! -e "$DOTFILES_DIR/claude/settings.json" ]; then
  # Fallback for runners that pipe the script in (no usable $0 path).
  DOTFILES_DIR="${DOTFILES_DIR_OVERRIDE:-$HOME/dotfiles}"
fi

log "── dotfiles install ─────────────────────────────────────────"
dbg "shell : $0  (bash=${BASH_VERSION:-no} zsh=${ZSH_VERSION:-no})"
dbg "when  : $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
dbg "who   : $(id -un 2>/dev/null || echo '?')  home=$HOME  pwd=$PWD"
dbg "dir   : $DOTFILES_DIR"

# Report whether each expected secret is visible at execution time.
# Prints presence + length only — NEVER the value.
report_secret() {
  local name="$1" val=""
  eval "val=\${$name:-}"
  if [ -n "$val" ]; then dbg "secret $name = present (len=${#val})"
  else                   dbg "secret $name = MISSING"; fi
}
report_secret CLAUDE_CODE_OAUTH_TOKEN
report_secret CLAUDE_CODE_OAUTH_TOKEN_B64
report_secret GOOGLE_APPLICATION_CREDENTIALS_JSON
report_secret GOOGLE_APPLICATION_CREDENTIALS_JSON_B64
dbg "env var names visible: $(env 2>/dev/null | sed 's/=.*//' | sort | tr '\n' ' ')"

# Decode base64 secret variants into their plain counterparts (preferred form,
# because base64 is shell-quoting-safe — see header note).
b64_into() {
  local src="$1" dst="$2" enc="" dec=""
  eval "enc=\${$src:-}"
  [ -z "$enc" ] && return 0
  if dec="$(printf '%s' "$enc" | base64 -d 2>/dev/null)" && [ -n "$dec" ]; then
    eval "$dst=\$dec"
    dbg "decoded $src → $dst (len=${#dec})"
  else
    dbg "WARN: $src is set but not valid base64 — ignoring it"
  fi
}
b64_into CLAUDE_CODE_OAUTH_TOKEN_B64          CLAUDE_CODE_OAUTH_TOKEN
b64_into GOOGLE_APPLICATION_CREDENTIALS_JSON_B64 GOOGLE_APPLICATION_CREDENTIALS_JSON

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------
mkdir -p ~/.claude

# Settings
cp "$DOTFILES_DIR/claude/settings.json" ~/.claude/settings.json
log "✓ Claude settings"

# Auth: long-lived OAuth token from `claude setup-token`.
# Passed as a secret env var at install time, written to a 0600 file that
# zsh sources on every shell start (so `claude` never prompts to re-login).
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  mkdir -p ~/.config/claude
  ( umask 177; printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN" > ~/.config/claude/token.env )
  dbg "wrote ~/.config/claude/token.env"
  log "✓ Claude OAuth token"
else
  log "⚠ CLAUDE_CODE_OAUTH_TOKEN not set, skipping"
fi

# ---------------------------------------------------------------------------
# gcloud: write ADC user credentials from env var, configure CLI to use them.
# GOOGLE_APPLICATION_CREDENTIALS_JSON holds the authorized_user JSON (refresh token).
# ---------------------------------------------------------------------------
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON:-}" ]; then
  mkdir -p ~/.config/gcloud
  CRED_FILE=~/.config/gcloud/application_default_credentials.json
  # The secret sometimes arrives wrapped in an extra layer of quotes or
  # JSON-string-encoded (each " became \"). Normalize it and validate that the
  # result is real JSON before writing, so a malformed secret fails loudly
  # instead of silently producing an invalid credentials file.
  if GOOGLE_APPLICATION_CREDENTIALS_JSON="$GOOGLE_APPLICATION_CREDENTIALS_JSON" \
     CRED_FILE="$CRED_FILE" python3 - <<'EOF'
import json, os, sys

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
    print("  · [debug] could not parse as JSON (len=%d, starts=%r)"
          % (len(raw), raw[:12]), file=sys.stderr)
    raise SystemExit("could not parse GOOGLE_APPLICATION_CREDENTIALS_JSON as JSON")

print("  · [debug] parsed credentials JSON, keys=%s" % sorted(obj), file=sys.stderr)
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(obj, f)
EOF
  then
    gcloud config set auth/credential_file_override "$CRED_FILE" --quiet 2>/dev/null || true
    ( umask 177; echo 'export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcloud/application_default_credentials.json"' > ~/.config/gcloud/auth.env )
    dbg "wrote $CRED_FILE and ~/.config/gcloud/auth.env"
    log "✓ gcloud auth"
  else
    log "⚠ GOOGLE_APPLICATION_CREDENTIALS_JSON is not valid JSON, skipping gcloud auth"
  fi
else
  log "⚠ GOOGLE_APPLICATION_CREDENTIALS_JSON not set, skipping"
fi

# ---------------------------------------------------------------------------
# Skip onboarding wizard on first launch
# ---------------------------------------------------------------------------
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
log "✓ Claude onboarding skipped"

# ---------------------------------------------------------------------------
# Zsh (idempotent: append once, guarded by a marker)
# ---------------------------------------------------------------------------
ZSH_MARKER="# >>> dotfiles zsh >>>"
if grep -qF "$ZSH_MARKER" ~/.zshrc 2>/dev/null; then
  log "✓ Zsh config (already present)"
else
  {
    echo ""              # leading newline: existing ~/.zshrc may lack a trailing one,
    echo "$ZSH_MARKER"   # which would otherwise glue the marker onto the last line
    cat "$DOTFILES_DIR/zsh/.zshrc"
    echo "# <<< dotfiles zsh <<<"
  } >> ~/.zshrc
  log "✓ Zsh config"
fi

log "── dotfiles install done ────────────────────────────────────"

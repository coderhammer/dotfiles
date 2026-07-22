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
report_secret GCP_SERVICE_ACCOUNT_KEY
report_secret GCP_SERVICE_ACCOUNT_KEY_B64
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
b64_into CLAUDE_CODE_OAUTH_TOKEN_B64             CLAUDE_CODE_OAUTH_TOKEN
b64_into GCP_SERVICE_ACCOUNT_KEY_B64             GCP_SERVICE_ACCOUNT_KEY
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
# gcloud credentials.
#   Preferred: GCP_SERVICE_ACCOUNT_KEY — a service_account key JSON (best for
#   headless automation). Written to a 0600 file, activated in gcloud, and
#   exported via GOOGLE_APPLICATION_CREDENTIALS so client libraries (ADC) use it.
#   Fallback: GOOGLE_APPLICATION_CREDENTIALS_JSON — authorized_user ADC JSON.
#   Each accepts a *_B64 variant (see header note on shell-quoting safety).
# ---------------------------------------------------------------------------
if [ -n "${GCP_SERVICE_ACCOUNT_KEY:-}" ]; then
  mkdir -p ~/.config/gcloud
  SA_FILE=~/.config/gcloud/service_account.json
  if GCP_SERVICE_ACCOUNT_KEY="$GCP_SERVICE_ACCOUNT_KEY" SA_FILE="$SA_FILE" python3 - <<'EOF'
import json, os, sys

raw = os.environ["GCP_SERVICE_ACCOUNT_KEY"].strip()
# Tolerate an extra layer of JSON-string encoding (each " became \").
obj = None
for _ in range(2):
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        obj = None
        break
    if isinstance(obj, dict):
        break
    if isinstance(obj, str):
        raw = obj
        continue
    obj = None
    break

if not isinstance(obj, dict) or obj.get("type") != "service_account":
    print("  · [debug] GCP_SERVICE_ACCOUNT_KEY is not a service_account JSON", file=sys.stderr)
    raise SystemExit(1)

print("  · [debug] service account: %s (project=%s)"
      % (obj.get("client_email"), obj.get("project_id")), file=sys.stderr)
fd = os.open(os.environ["SA_FILE"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(obj, f)
EOF
  then
    gcloud auth activate-service-account --key-file="$SA_FILE" --quiet 2>/dev/null \
      && dbg "activated service account in gcloud" \
      || dbg "WARN: gcloud auth activate-service-account failed (gcloud missing?)"
    ( umask 177; echo 'export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcloud/service_account.json"' > ~/.config/gcloud/auth.env )
    dbg "wrote $SA_FILE and ~/.config/gcloud/auth.env"
    log "✓ gcloud auth (service account)"
  else
    log "⚠ GCP_SERVICE_ACCOUNT_KEY is not valid service_account JSON, skipping"
  fi
elif [ -n "${GOOGLE_APPLICATION_CREDENTIALS_JSON:-}" ]; then
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
  log "⚠ no GCP credentials set (GCP_SERVICE_ACCOUNT_KEY / GOOGLE_APPLICATION_CREDENTIALS_JSON), skipping"
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
# Ensure zsh is installed (idempotent, best-effort).
#
# This is deliberately NON-FATAL: installing a system package needs a package
# manager AND the privileges to use it, neither of which is guaranteed. A
# failure here (no root/sudo, no package manager, offline) must NOT abort the
# whole dotfiles install — hence the install logic lives in a function called
# with `|| true`, which also suspends `set -e` for everything inside it.
# ---------------------------------------------------------------------------
_install_zsh() {
  # Privilege prefix: nothing if root; `sudo -n` (never prompt) if available.
  # Bail early with a clear message when a package manager would need root but
  # we have no way to elevate — otherwise apt/apk just print a raw
  # "Permission denied" and look like a hard error.
  local SUDO=""
  if [ "$(id -u 2>/dev/null || echo 0)" != "0" ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo -n"
    else
      dbg "not root and no sudo — cannot install system packages"
      return 1
    fi
  fi

  if command -v apt-get >/dev/null 2>&1; then
    dbg "installing zsh via apt-get"
    $SUDO apt-get update -qq && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh
  elif command -v apk >/dev/null 2>&1; then
    dbg "installing zsh via apk"
    $SUDO apk add --no-cache zsh
  elif command -v dnf >/dev/null 2>&1; then
    dbg "installing zsh via dnf"
    $SUDO dnf install -y zsh
  elif command -v yum >/dev/null 2>&1; then
    dbg "installing zsh via yum"
    $SUDO yum install -y zsh
  elif command -v pacman >/dev/null 2>&1; then
    dbg "installing zsh via pacman"
    $SUDO pacman -Sy --noconfirm zsh
  elif command -v brew >/dev/null 2>&1; then
    dbg "installing zsh via brew"
    brew install zsh
  else
    dbg "no supported package manager found"
    return 1
  fi
}

if command -v zsh >/dev/null 2>&1; then
  log "✓ Zsh present ($(zsh --version 2>/dev/null | head -1))"
else
  _install_zsh || true   # `|| true` keeps a failed install from aborting set -e
  if command -v zsh >/dev/null 2>&1; then
    log "✓ Zsh installed"
  else
    log "⚠ could not install zsh (needs root/sudo + a package manager) — skipping, config below still applies"
  fi
fi

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

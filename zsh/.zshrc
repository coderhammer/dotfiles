alias dc="docker compose"
alias c="claude --dangerously-skip-permissions"

# Claude Code: long-lived OAuth token (written by install.sh)
[ -f ~/.config/claude/token.env ] && source ~/.config/claude/token.env

# Claude Code: state directory on the persistent volume (written by install.sh)
[ -f ~/.config/claude/config-dir.env ] && source ~/.config/claude/config-dir.env

# gcloud: ADC credentials path (written by install.sh)
[ -f ~/.config/gcloud/auth.env ] && source ~/.config/gcloud/auth.env

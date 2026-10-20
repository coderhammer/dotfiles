alias dc="docker compose"
alias c="claude --dangerously-skip-permissions"

# Claude Code: default state directory on the persistent volume (written by
# install.sh only when the environment did not set one)
[ -f ~/.config/claude/config-dir.env ] && source ~/.config/claude/config-dir.env

# gcloud: ADC credentials path (written by install.sh)
[ -f ~/.config/gcloud/auth.env ] && source ~/.config/gcloud/auth.env

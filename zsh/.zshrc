alias dc="docker compose"
alias c="claude --dangerously-skip-permissions"

# Claude Code: long-lived OAuth token (written by install.sh)
[ -f ~/.config/claude/token.env ] && source ~/.config/claude/token.env

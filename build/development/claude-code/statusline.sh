#!/bin/bash
# Claude Code status line: PS1-style user@host:cwd, plus active model and context usage.
input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // ""')
model=$(echo "$input" | jq -r '.model.display_name // ""')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

printf "\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m" "$(whoami)" "$(hostname -s)" "$cwd"

if [ -n "$model" ]; then
  printf " \033[00;33m[%s]\033[00m" "$model"
fi

if [ -n "$used" ]; then
  printf " \033[00;36mctx:%.0f%%\033[00m" "$used"
fi

printf "\n"

#!/bin/sh
# Status line: optional machine-role label (from git-ignored ~/.claude/machine-role.md)
# followed by claude-hud. Portable: machines without the role file show no label.
input=$(cat)
role=$(sed -n '1s/^Role:[[:space:]]*//p' "$HOME/.claude/machine-role.md" 2>/dev/null)
[ -n "$role" ] && printf '\033[1;41;97m %s \033[0m ' "$role"
hud="$HOME/.claude/plugins/claude-hud/statusline.mjs"
[ -f "$hud" ] || hud=$(ls -td "$HOME"/.claude/plugins/cache/claude-hud/claude-hud/*/dist/index.js 2>/dev/null | head -1)
[ -n "$hud" ] && [ -f "$hud" ] && printf '%s' "$input" | node "$hud"

#!/bin/sh
# Claude Code status line
# Shows: cwd | context% | tokens used/max | session tokens | cost
input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
model=$(echo "$input" | jq -r '.model.display_name // "?"')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# Format token counts as K
ctx_max=$(echo "$ctx_size" | awk '{printf "%.0fK", $1/1000}')
session_tokens=$(echo "$total_in $total_out" | awk '{printf "%.1fK", ($1+$2)/1000}')

# Current context usage tokens
cur_in=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cur_out=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')
used_tokens=$(echo "$cur_in $cur_out" | awk '{printf "%.1fK", ($1+$2)/1000}')

# Format cost
cost_fmt=$(printf '$%.2f' "$cost")

# Color context % based on usage
if [ "$ctx_pct" -ge 80 ] 2>/dev/null; then
  ctx_color="\033[0;31m"
elif [ "$ctx_pct" -ge 50 ] 2>/dev/null; then
  ctx_color="\033[0;33m"
else
  ctx_color="\033[0;32m"
fi

# Build context bar (10 chars wide)
bar_width=10
if [ "$ctx_pct" -gt 0 ] 2>/dev/null; then
  filled=$(( ctx_pct * bar_width / 100 ))
  empty=$(( bar_width - filled ))
else
  filled=0
  empty=$bar_width
fi
bar_filled=$(printf '%*s' "$filled" '' | tr ' ' '#')
bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '-')
ctx_bar="${ctx_color}${bar_filled}\033[0;90m${bar_empty}\033[0m"

sep="\033[0;90m|\033[0m"

printf "\033[0;37m%s\033[0m %b \033[0;34m%s\033[0m %b ctx:%b ${ctx_color}%s%%\033[0m %b \033[0;36m%s/%s\033[0m %b \033[0;35msession:%s\033[0m %b \033[0;33m%s\033[0m" \
  "$model" "$sep" "$cwd" "$sep" "$ctx_bar" "$ctx_pct" "$sep" "$used_tokens" "$ctx_max" "$sep" "$session_tokens" "$sep" "$cost_fmt"

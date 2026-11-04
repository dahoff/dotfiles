#!/bin/sh
# Claude Code status line
# Shows: cwd | context% | session tokens | cost | [rate limit bars if CLAUDE_STATUS_RATE_LIMITS=1]
input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd')
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
model=$(echo "$input" | jq -r '.model.display_name // "?"')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

# Format token counts as K
session_tokens=$(echo "$total_in $total_out" | awk '{printf "%.1fK", ($1+$2)/1000}')

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

# Build a progress bar given a percentage and width
make_bar() {
  pct="$1"
  width="$2"
  color="$3"
  if [ "$pct" -ge 80 ] 2>/dev/null; then
    bar_color="\033[0;31m"
  elif [ "$pct" -ge 50 ] 2>/dev/null; then
    bar_color="\033[0;33m"
  else
    bar_color="\033[0;32m"
  fi
  if [ "$pct" -gt 0 ] 2>/dev/null; then
    filled=$(( pct * width / 100 ))
    [ "$filled" -gt "$width" ] && filled=$width
    empty=$(( width - filled ))
  else
    filled=0
    empty=$width
  fi
  bar_filled=$(printf '%*s' "$filled" '' | tr ' ' '#')
  bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '-')
  printf "${bar_color}%s\033[0;90m%s\033[0m" "$bar_filled" "$bar_empty"
}

# Build context bar (10 chars wide)
ctx_bar=$(make_bar "$ctx_pct" 10)

sep="\033[0;90m|\033[0m"

printf "\033[0;37m%s\033[0m %b \033[0;34m%s\033[0m %b ctx:%b ${ctx_color}%s%%\033[0m %b \033[0;35msession:%s\033[0m %b \033[0;33m%s\033[0m" \
  "$model" "$sep" "$cwd" "$sep" "$ctx_bar" "$ctx_pct" "$sep" "$session_tokens" "$sep" "$cost_fmt"

# Rate limit bars — only shown when CLAUDE_STATUS_RATE_LIMITS=1
if [ "${CLAUDE_STATUS_RATE_LIMITS:-0}" = "1" ]; then
  five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0')
  five_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')
  seven_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0')
  seven_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0')

  now=$(date +%s)

  five_mins=$(( (five_resets - now) / 60 ))
  if [ "$five_mins" -lt 0 ] 2>/dev/null; then five_mins=0; fi
  five_bar=$(make_bar "$five_pct" 8)

  seven_hrs=$(( (seven_resets - now) / 3600 ))
  if [ "$seven_hrs" -lt 0 ] 2>/dev/null; then seven_hrs=0; fi
  seven_bar=$(make_bar "$seven_pct" 8)

  if [ "$five_pct" -ge 80 ] 2>/dev/null; then five_pct_color="\033[0;31m"
  elif [ "$five_pct" -ge 50 ] 2>/dev/null; then five_pct_color="\033[0;33m"
  else five_pct_color="\033[0;32m"; fi

  if [ "$seven_pct" -ge 80 ] 2>/dev/null; then seven_pct_color="\033[0;31m"
  elif [ "$seven_pct" -ge 50 ] 2>/dev/null; then seven_pct_color="\033[0;33m"
  else seven_pct_color="\033[0;32m"; fi

  printf " %b 5h:%b ${five_pct_color}%s%%\033[0m\033[0;90m(-%dm)\033[0m %b 7d:%b ${seven_pct_color}%s%%\033[0m\033[0;90m(-%dh)\033[0m" \
    "$sep" "$five_bar" "$five_pct" "$five_mins" "$sep" "$seven_bar" "$seven_pct" "$seven_hrs"
fi

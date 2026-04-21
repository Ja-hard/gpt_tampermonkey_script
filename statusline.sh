#!/usr/bin/env bash

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  echo "statusline: jq missing"
  exit 0
fi

dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""')
model=$(printf '%s' "$input" | jq -r '.model.display_name // .model.id // "unknown"')
used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
input_tokens=$(printf '%s' "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_creation_tokens=$(printf '%s' "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read_tokens=$(printf '%s' "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')

if [ -z "$dir" ] || [ "$dir" = "null" ]; then
  dir="unknown-dir"
fi

dir_name=${dir##*/}
if [ -z "$dir_name" ]; then
  dir_name="$dir"
fi

used_tokens=$((input_tokens + cache_creation_tokens + cache_read_tokens))
used_k=$(awk -v tokens="$used_tokens" 'BEGIN { printf "%.1f", tokens / 1000 }')

BLUE='\033[34m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
MAGENTA='\033[35m'
RESET='\033[0m'
CACHE_MAX_AGE=10

if [ "$used_pct" -ge 90 ]; then
  ctx_color="$RED"
elif [ "$used_pct" -ge 70 ]; then
  ctx_color="$YELLOW"
else
  ctx_color="$GREEN"
fi

sum_numstat() {
  awk '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      added += $1
      deleted += $2
    }
    END {
      printf "%d %d", added + 0, deleted + 0
    }
  '
}

sum_untracked_numstat() {
  git -C "$dir" ls-files --others --exclude-standard -z 2>/dev/null |
    while IFS= read -r -d '' path; do
      git -C "$dir" diff --no-index --numstat -- /dev/null "$dir/$path" 2>/dev/null
    done | sum_numstat
}

cache_file_for_dir() {
  printf '%s' "$dir" | sha1sum | awk '{print "/tmp/claude-statusline-git-" $1}'
}

cache_is_stale() {
  [ ! -f "$1" ] || [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) -gt "$CACHE_MAX_AGE" ]
}

output="📁 ${BLUE}${dir_name}${RESET} | 🤖 ${CYAN}${model}${RESET} | 🧠 ${ctx_color}${used_k}k${RESET}"

if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  cache_file=$(cache_file_for_dir)

  if cache_is_stale "$cache_file"; then
    branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
      branch="(detached)"
    fi

    read -r unstaged_added unstaged_deleted <<EOF
$(git -C "$dir" diff --numstat 2>/dev/null | sum_numstat)
EOF
    read -r staged_added staged_deleted <<EOF
$(git -C "$dir" diff --cached --numstat 2>/dev/null | sum_numstat)
EOF
    read -r untracked_added untracked_deleted <<EOF
$(sum_untracked_numstat)
EOF

    added=$((unstaged_added + staged_added + untracked_added))
    deleted=$((unstaged_deleted + staged_deleted + untracked_deleted))

    printf '%s|%s|%s\n' "$branch" "$added" "$deleted" > "$cache_file"
  fi

  IFS='|' read -r branch added deleted < "$cache_file"
  output="$output | 🌿 ${MAGENTA}${branch}${RESET} | ${RED}-$deleted${RESET} ${GREEN}+$added${RESET}"
fi

echo -e "$output"

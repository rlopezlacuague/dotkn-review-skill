#!/usr/bin/env bash
# dotkn-review uninstaller — removes the skill from Claude Code and Cursor skill dirs.
set -euo pipefail

project=""
if [[ "${1:-}" == "--project" ]]; then
  [[ $# -ge 2 ]] || { echo "error: --project requires a path" >&2; exit 1; }
  project="$2"
fi

if [[ -n "$project" ]]; then
  targets=("$project/.claude/skills/dotkn-review" "$project/.cursor/skills/dotkn-review")
else
  targets=("$HOME/.claude/skills/dotkn-review" "$HOME/.cursor/skills/dotkn-review")
fi

removed=false
for target in "${targets[@]}"; do
  if [[ -d "$target" ]]; then
    rm -rf "$target"
    echo "removed: $target"
    removed=true
  fi
done

[[ "$removed" == true ]] || echo "nothing to remove"

#!/usr/bin/env bash
# dotkn-review installer — copies skills/dotkn-review into Claude Code and/or Cursor skill dirs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$SCRIPT_DIR/skills/dotkn-review"

usage() {
  cat <<EOF
Usage: ./install.sh [--claude] [--cursor] [--project <path>] [--all]

  (no flags)         Install to ~/.claude/skills and ~/.cursor/skills (same as --all)
  --claude           Install to ~/.claude/skills only
  --cursor           Install to ~/.cursor/skills only
  --project <path>   Install into <path>/.claude/skills and <path>/.cursor/skills
                     (combine with --claude/--cursor to narrow)
  --all              Install to both user-level locations
EOF
}

claude=false
cursor=false
project=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude) claude=true ;;
    --cursor) cursor=true ;;
    --all) claude=true; cursor=true ;;
    --project)
      shift
      [[ $# -gt 0 ]] || { echo "error: --project requires a path" >&2; exit 1; }
      project="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

# Default: both tools
if [[ "$claude" == false && "$cursor" == false ]]; then
  claude=true
  cursor=true
fi

[[ -f "$SKILL_SRC/SKILL.md" ]] || { echo "error: $SKILL_SRC/SKILL.md not found" >&2; exit 1; }

if [[ -n "$project" ]]; then
  [[ -d "$project" ]] || { echo "error: project path not found: $project" >&2; exit 1; }
  base_claude="$project/.claude/skills"
  base_cursor="$project/.cursor/skills"
else
  base_claude="$HOME/.claude/skills"
  base_cursor="$HOME/.cursor/skills"
fi

targets=()
[[ "$claude" == true ]] && targets+=("$base_claude")
[[ "$cursor" == true ]] && targets+=("$base_cursor")

for target in "${targets[@]}"; do
  mkdir -p "$target"
  rm -rf "$target/dotkn-review"
  cp -R "$SKILL_SRC" "$target/dotkn-review"
  echo "installed: $target/dotkn-review"
done

echo
echo "Done. Try it: open a repo with changes and run /dotkn-review"

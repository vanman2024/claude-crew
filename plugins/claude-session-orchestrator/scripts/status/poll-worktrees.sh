#!/bin/bash
# Poll orchestrator status files to see what each worktree agent is doing
# Usage: bash poll-worktrees.sh [worktree-name]
#
# Project-agnostic: runs from the orchestrator's cwd (an `orchestrator` worktree
# under the worktrees base). The status dir and worktree base are derived from cwd:
#   WORKTREE_BASE = dirname(PWD)   (parent of the orchestrator worktree)
#   STATUS_DIR    = WORKTREE_BASE/.orchestrator

STATUS_DIR="$(dirname "$PWD")/.orchestrator"
WORKTREE_BASE="$(dirname "$PWD")"

if [ ! -d "$STATUS_DIR" ]; then
  echo "No orchestrator status directory. No hooks reporting yet."
  exit 0
fi

if [ -n "$1" ]; then
  # Single worktree
  FILE="$STATUS_DIR/$1.status"
  if [ -f "$FILE" ]; then
    cat "$FILE"
  else
    echo "No status for $1 — agent hasn't reported yet"
  fi
else
  # All worktrees
  echo "ORCHESTRATOR STATUS"
  echo "==================="
  echo ""
  for f in "$STATUS_DIR"/*.status; do
    [ -f "$f" ] || continue
    node -e "
      const fs = require('fs');
      const d = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      const name = (d.worktree || '?').padEnd(30);
      const status = (d.status || '?').padEnd(10);
      const tool = (d.last_tool || '-').padEnd(8);
      const ts = d.timestamp || '';
      console.log('  ' + name + ' ' + status + ' ' + tool + ' ' + ts);
    " "$f" 2>/dev/null
  done

  # Check for worktrees with no status
  echo ""
  for d in "$WORKTREE_BASE"/*/; do
    [ -d "$d" ] || continue
    NAME=$(basename "$d")
    [ "$NAME" = ".orchestrator" ] && continue
    [ "$NAME" = "orchestrator" ] && continue
    if [ ! -f "$STATUS_DIR/$NAME.status" ]; then
      echo "  $NAME — NO HOOKS (not reporting)"
    fi
  done
fi

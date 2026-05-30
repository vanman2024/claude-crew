#!/bin/bash
# Install orchestrator hooks into a worktree's .claude/settings.local.json
# Usage: bash install-worktree-hooks.sh <worktree-path>
#
# Project-agnostic: the hook command points at this plugin's orchestrator-hook.sh.
# Prefer deriving an absolute path from this script's own location (most reliable,
# since CLAUDE_PLUGIN_ROOT may not be set when the hook later fires). Fall back to
# ${CLAUDE_PLUGIN_ROOT} only if the derivation somehow fails.

WORKTREE_PATH="${1:-.}"

# Derive the absolute path to orchestrator-hook.sh from this script's location.
HOOK_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orchestrator-hook.sh"
if [ ! -f "$HOOK_SCRIPT" ] && [ -n "${CLAUDE_PLUGIN_ROOT}" ]; then
  HOOK_SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/status/orchestrator-hook.sh"
fi

SETTINGS_FILE="$WORKTREE_PATH/.claude/settings.local.json"

mkdir -p "$WORKTREE_PATH/.claude"

cat > "$SETTINGS_FILE" <<EOFJ
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [{"type": "command", "command": "bash \"$HOOK_SCRIPT\""}]
      }
    ],
    "Stop": [
      {
        "hooks": [{"type": "command", "command": "bash \"$HOOK_SCRIPT\""}]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [{"type": "command", "command": "bash \"$HOOK_SCRIPT\""}]
      }
    ]
  }
}
EOFJ

echo "Hooks installed in $SETTINGS_FILE"


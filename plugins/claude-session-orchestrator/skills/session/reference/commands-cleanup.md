# Cleanup Command — Detailed Steps

> Paths/session/repo/branch come from `.claude/session-plugin.json` (`<repo>`=repoPath, `<wt>`=worktreesPath, `<base>`=defaultBranch).

Remove zombie worktree directories (stale dirs under `<wt>` not registered with git).

## Steps

1. Verify main repo: `pwd && git branch --show-current` (should be on `<base>`).

2. Get registered worktrees: `git worktree list`

3. List filesystem dirs under the worktrees path:
   ```
   pwsh -NoProfile -Command "Get-ChildItem -Directory '<wt>' | Select-Object -ExpandProperty Name"
   ```

4. Compare lists. Active = present in `git worktree list`. Zombie = filesystem only.

5. If no zombies: "All clean." STOP.

6. Display:
   ```
   WORKTREE CLEANUP
   ================
   Active (registered):
     ● abc-widget       — feature/abc-widget
   Zombies:
     ✗ xyz-referral     — zombie directory
   Remove all N zombie directories?
   ```

7. Ask for confirmation. **Ask before removing anything.**

8. For each approved zombie, remove the directory. Prefer pwsh `Remove-Item`
   (it handles long paths better than `cmd /c rmdir`):
   ```
   pwsh -NoProfile -Command "Remove-Item -LiteralPath '<wt>\<name>' -Recurse -Force"
   ```
   If processes hold handles open inside the dir, kill them first, then retry
   (rename-and-delete fallback breaks the handle association):
   ```
   pwsh -NoProfile -Command "Rename-Item '<wt>\<name>' '<wt>\_del_<name>'; Remove-Item '<wt>\_del_<name>' -Recurse -Force"
   ```

9. `git worktree prune`

10. Report: Removed, Still locked, Active (untouched).

---

**Use the teardown scripts** instead of hand-rolling the above when you can —
they encode the Windows-safe ordering and fallbacks:

- `${CLAUDE_PLUGIN_ROOT}/scripts/teardown/close-worker.ps1` — single worktree,
  junction-first (preferred for targeted teardown).
  `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/teardown/close-worker.ps1" -Name "<name>" -Config "<repo>/.claude/session-plugin.json"`
- `${CLAUDE_PLUGIN_ROOT}/scripts/teardown/cleanup-worktrees.ps1` — remove ALL
  worktree dirs under `<wt>`, then prune (rename-and-delete fallback for stuck dirs).
  `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/teardown/cleanup-worktrees.ps1" -Config "<repo>/.claude/session-plugin.json"`
- `${CLAUDE_PLUGIN_ROOT}/scripts/teardown/nuke-worktrees.ps1` — last resort:
  kills every process with handles in `<wt>`, then deletes everything (robocopy-mirror
  + rename fallbacks).
  `pwsh -File "${CLAUDE_PLUGIN_ROOT}/scripts/teardown/nuke-worktrees.ps1" -Config "<repo>/.claude/session-plugin.json"`

**NOTE**: If a dir is locked by Windows, close editors/terminals pointing into it.
Last resort: reboot, then re-run cleanup.

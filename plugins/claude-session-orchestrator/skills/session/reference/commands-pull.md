# Pull Command — Detailed Steps

> Paths/session/repo/branch come from `.claude/session-plugin.json` (`<repo>`=repoPath, `<wt>`=worktreesPath, `<sess>`=psmuxSession, `<gh>`=githubRepo, `<base>`=defaultBranch).

Show PR status dashboard, pull merged work into `<base>`, cleanup landed worktrees.
Run from the MAIN session. **Principle: show everything, touch nothing, until user says go.**

---

## Phase 1 — Safety checks

1. Verify the main repo is on `<base>`:
   ```
   pwd && git branch --show-current
   ```

2. Check uncommitted changes: `git status --porcelain`
   - Changes exist → ask user to commit first
   - User says NO → STOP

3. Fetch: `git fetch origin <base>`

## Phase 2 — PR status dashboard

4. `git worktree list`

5. Query all PRs:
   ```
   gh pr list --repo <gh> --state all --json headRefName,number,title,state,mergedAt,url,statusCheckRollup --limit 50
   ```

6. CI status per branch: `gh pr checks "<branch>" --repo <gh> 2>/dev/null`

7. Display dashboard:
   ```
   WORKTREE PR STATUS
   ==================
   Branch                   PR#    State     CI        Mergeable  Title
   ───────────────────────  ─────  ────────  ────────  ─────────  ─────────
   feature/abc-widget       #12    MERGED    PASSED    —          Widget assembly
   feature/xyz-referral     #13    OPEN      PASSING   YES        Referral system
   ```

   **State**: MERGED | OPEN | CLOSED | NO PR
   **CI**: PASSING | FAILING | PENDING | PASSED | —
   **Mergeable**: YES | NO | UNKNOWN | —

## Phase 3 — Incoming changes

8. Show what pulling brings:
   ```
   git log --oneline HEAD..origin/<base>
   git diff --stat HEAD..origin/<base>
   ```

## Phase 4 — User approval

9. List each merged PR, total impact. Ask: "Pull these N merged PRs?"
   - NO → skip to Phase 6 (zombie cleanup)
   - YES → proceed

## Phase 5 — Pull with rebase

10. ```
    git pull --rebase origin <base>
    ```
    If conflicts → `git rebase --abort` → STOP.

11. Verify: `git log --oneline -5 && git status --porcelain`

12. Type check / smoke test using the project's test commands from `config.layout`
    (per-part `testCmd`, e.g. a typecheck). If it fails → warn, ask if continue.

## Phase 6 — Cleanup landed worktrees

13. For each MERGED + pulled PR, tear down its worktree with the teardown
    helper. Prefer `close-worker.ps1` for a single worktree — it is junction-first
    (removes the `node_modules` junction LINK before `git worktree remove`, so
    git never follows the junction into the main repo's `node_modules`), kills the
    psmux window, then runs `git worktree remove --force` and `git worktree prune`:
    ```
    pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/teardown/close-worker.ps1" -Name "<name>" -Config "<repo>/.claude/session-plugin.json"
    ```
    Then delete the remote branch: `git push origin --delete "feature/<name>" 2>/dev/null || true`

14. Detect zombies: compare the filesystem (dirs under `<wt>`) against
    `git worktree list`. A dir present on disk but not in git's list is a zombie.
    Ask before removing (see `commands-cleanup.md`).

## Phase 7 — Report

15. Display: Landed (with PR#), Still Active (with status), Zombies Cleaned,
    `<base>` hash, test/typecheck result.

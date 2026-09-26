# Pull Command — Detailed Steps

> Paths/session/repo/branch come from `.claude/session-plugin.json` (`<repo>`=repoPath, `<wt>`=worktreesPath, `<sess>`=psmuxSession, `<gh>`=githubRepo, `<base>`=defaultBranch).

Show PR status dashboard, pull merged work into `<base>`, offer teardown of landed workers.
Run from the MAIN session. **Principle: show everything, touch nothing, until user says go.**

---

## Phase 1 — Safety checks

1. Verify the main repo is on `<base>` (the RESOLVED branch from `status/resolve-config.ps1`,
   not the raw JSON, which may say `auto`):
   ```
   git -C <repo> branch --show-current
   ```
   On another branch → say which, and ask. Never switch branches under the user.

2. Check uncommitted changes: `git -C <repo> status --porcelain`
   - Changes exist → show a grouped summary (count by top-level directory; deleted vs
     modified vs untracked) and ask what the user wants. Never stash, commit or discard
     their work unasked.
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

## Phase 6 — Landed workers: list them, don't tear them down

13. Workers stay alive after merge: the user may iterate on them or give them more work.
    List each worker whose PR is now MERGED and ask whether any are done. Only for the ones
    the user names, tear down with the junction-first helper (removes the `node_modules`
    junction LINK before `git worktree remove`, kills the psmux window, prunes):
    ```
    pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/teardown/close-worker.ps1" -Name "<name>" -Config "<repo>/.claude/session-plugin.json"
    ```
    Then delete that remote branch: `git push origin --delete "<branch>"`

14. Detect zombies: compare the filesystem (dirs under `<wt>`) against
    `git worktree list`. A dir present on disk but not in git's list is a zombie.
    Ask before removing (see `commands-cleanup.md`).

## Phase 7 — Report

15. Display: Landed (with PR#), Still Active (with status), Zombies Cleaned,
    `<base>` hash, test/typecheck result.

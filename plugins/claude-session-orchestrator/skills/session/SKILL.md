---
name: session
description: Start, resume, finish, monitor, orchestrate, and review parallel git-worktree build sessions on Windows using psmux. Spawns Claude workers per worktree, polls them on /loop, and runs a dedicated reviewer that verifies each PR (tests + /code-review) before you merge. Project-agnostic — driven by .claude/session-plugin.json. Triggers on "/session", "start a worktree", "dispatch workers", "orchestrate the build", "review the PRs", "blast through these issues".
argument-hint: "[list|start|start-issues|resume|finish|pull|cleanup|monitor|server-start|server-check|server-stop|orchestrate|review|review-start] [name|issue-numbers]"
disable-model-invocation: false
allowed-tools: Bash(git *), Bash(gh *), Bash(node *), Bash(bash *), Bash(pwsh *), Bash(psmux *), Bash(powershell.exe *), Bash(cmd.exe *), Bash(pwd), Bash(cat *), Read, Glob, Grep
---

# Session — Parallel Worktree Build Orchestrator (psmux)

Manage git worktrees for parallel feature development on Windows using **psmux**
(the Windows tmux port). Each worktree gets its own branch and its own psmux
**window** running an interactive Claude worker you can watch (`capture-pane`) and
steer (`send-keys`) without stealing focus.

This skill is **project-agnostic**. Every path, session name, repo, branch, and
layout comes from the consuming project's config file. Nothing is hardcoded.

## STEP 0 — ALWAYS load config first

Before running ANY subcommand, read the project config:

```
Read  <project-root>/.claude/session-plugin.json
```

If it's missing, tell the user to run `/session-init` to scaffold it. The fields
you'll use: `projectName`, `repoPath`, `worktreesPath`, `psmuxSession`,
`githubRepo`, `defaultBranch`, `workerCmdPath`, `layout`, and optional `teams`.

Throughout this doc, substitute:
- `<repo>` → `repoPath`
- `<wt>` → `worktreesPath`
- `<sess>` → `psmuxSession`
- `<gh>` → `githubRepo`
- `<base>` → `defaultBranch`

The PowerShell scripts read the same config themselves (via `-Config` or by
walking up from cwd), so you usually just pass `-Config "<repo>/.claude/session-plugin.json"`
or run them from the project dir and let them auto-resolve.

## psmux mental model

```
psmux SESSION (= config.psmuxSession) — persistent, survives terminal closing
  └── WINDOW per worktree (e.g. f036-international) — shell cd'd into the worktree
        └── PANE running claude.cmd --dangerously-skip-permissions (the worker)
```

- **Session**: one per project. Created detached on first dispatch: `psmux new -s <sess> -d`
- **Window**: one per worktree. Created by `psmux-dispatch.ps1`.
- You (orchestrator) monitor with `capture-pane` and steer with `send-keys`.

## When to use this (and when NOT to)

| Use a worktree session for... | Do NOT use it for... |
|---|---|
| **Big bulk scaffolding** from a spec; **blasting an issue backlog** (N workers → N PRs) | Granular post-scaffold one-line fixes — those are one PR per issue on `<base>`-derived branches |
| Multiple independent big pieces with little file overlap | Global changes (routing, auth, layout shell) — do those serially on `<base>` |

**Disjoint file-lanes rule (learned the hard way):** dispatch **one worker per module / file-lane**. Do NOT run multiple issues that touch the *same* module's files in parallel — N workers each rewrite the shared file (e.g. that module's page) and **collide at merge time**. Parallelize **across** modules (disjoint files merge in any order); **sequence** issues *within* a module.

## Merge protocol (when the user authorizes a merge)

The orchestrator NEVER merges (Critical Rule 8). When the user says "merge it", the MAIN session does it. Two things gate every merge: **how the user reviews the PR**, and **the merge order** (based on which files each PR touched). **Never auto-merge and never merge before the user has reviewed.**

### Review routing — how the user checks each PR (do this FIRST)

Classify the PR by lane: `gh pr diff <n> --name-only`, compared against the `config.teams` `ownsPaths` (frontend lane vs backend lane).

- **Frontend-only PR** (every changed path is in the frontend lane) → the user reviews it on the **Vercel preview** deployment. Do NOT check it out locally — just report the preview URL and let the user look.
- **Backend or full-stack PR** (any path in the backend lane) → **check the branch out locally** so the user can RUN it on their local env (3000/8000) and see it actually work — a Vercel preview cannot exercise backend behavior. Fetch + check out the branch into a local review checkout (e.g. `git -C <repo> fetch origin <branch>` into the `review-checkout` worktree) and `server-start` it, then hand it to the user.

Surface the routing per PR. The user reviews (preview or local run), iterates if needed, then says "merge it".

### Merge order (based on file overlap)

1. **Find overlap first:** `gh pr view <n> --json files --jq '.files[].path'` for every candidate PR. Any path touched by >1 PR means those PRs must be sequenced.
2. **Disjoint PRs** (no shared files) → merge in any order, freely.
3. **Overlapping PRs** → one at a time: merge the first → rebase the next onto updated `<base>` → resolve the shared-file conflicts → **re-verify** → merge → repeat. Each merge can flip another PR's `mergeable` flag to CONFLICTING, so re-check after every merge.
4. **Squash-merge** each (one clean commit per feature; easy single-feature revert).

### After a merge — do NOT tear down the worker

Leave the worker's worktree + psmux window **running**. The user keeps workers alive to iterate (tell the worker to fix + push, then re-review the preview / re-check the local branch) or to feed them more tasks. The work is already on the remote, so there is no rush to close anything. Tear down (junction-first via `close-worker.ps1`) **only** when the user explicitly says that worker is done. Never auto-clean after a merge.

## Quick Reference

| Command | What it does |
|---------|-------------|
| `list` | Show all worktrees + psmux windows + health |
| `start <name>` | Create worktree, junction deps, dispatch a psmux worker, auto-start monitor loop |
| `start-issues <n> <n> ...` | **BULK.** One worktree worker per GitHub issue. Branch/window `fix/<n>-<slug>` |
| `resume <name>` | Health-check + repair worktree, re-dispatch its psmux window |
| `restore` | **After a crash/power-loss/reboot:** rebuild the psmux session + a window per surviving worktree and **resume each worker's prior conversation** (`claude --continue` / `codex resume --last`). If the psmux session is still alive, just prints the attach command. `-Idle` to resume without nudging; `-Name <wt>` for one worktree. |
| `finish <name>` | Commit → test → rebase → push → create PR (no merge, no cleanup) |
| `pull` | PR dashboard, pull merged work into `<base>`, cleanup |
| `cleanup` | Remove zombie worktree dirs + kill orphan windows |
| `monitor <name>` | Single poll cycle: capture-pane → analyze → send-keys if needed |
| `server-start/check/stop` | Manage a detached dev server for a worktree |
| `orchestrate [...]` | Unified loop: dashboard / dispatch / poll / verify / pull / cleanup |
| `review` | One reviewer cycle: check out the next green PR, run tests + `/code-review`, label `READY-VERIFIED`, update the ordered merge queue. The `/loop` body. |
| `review-start` | Spawn the dedicated **Reviewer** Claude (the overseer) in its own window + `/loop`. Auto-launched by the orchestrator. |

## Scripts (in this plugin, under `scripts/`)

Scripts are organized by function under `scripts/`. Invoke with the plugin root, e.g.:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name <name> -Task "<desc>" -Config "<repo>/.claude/session-plugin.json"
```

| Script (path under `scripts/`) | Purpose |
|--------|---------|
| `dispatch/psmux-dispatch.ps1` | **Primary dispatch.** worktree + env copy + node_modules junction + psmux window + worker launch (boot handshake) + bootstrap. `-Name` + one of `-Task` / `-Bootstrap` / `-BootstrapFile`. Brief flags (when `-Task`): `-Mode feature\|iteration`, `-Spec <repo-rel path>`, `-IssueNumber <n>`. `-WorkerCliName codex` (+ optional `-WorkerCmdOverride`) runs a **Codex** worker in this window instead of Claude — one session can mix both. |
| `dispatch/psmux-dispatch-issues.ps1` | **Bulk dispatch.** `-Issues 510,511,512` (or positional). Fetches each issue, builds a brief, dispatches per issue. |
| `dispatch/restore-session.ps1` | **Crash recovery.** psmux server gone (reboot/power loss) but worktrees survive: rebuilds the session + a window per worktree and resumes each worker's prior conversation via `psmux-dispatch.ps1 -Continue` (`claude --continue` / `codex resume --last`). Session still alive → just prints the attach command. `-Idle` (resume, no nudge), `-Name <wt>` (one worktree). |
| `dispatch/start-orchestrator.ps1` | Spawn the dedicated orchestrator Claude in its own detached worktree + window with the no-auto-merge + batch-scoped brief, then `/loop`. `-IntervalMin 5`. Also spawns the reviewer unless `-NoReviewer`. |
| `dispatch/start-reviewer.ps1` | Spawn the dedicated **reviewer** Claude (the overseer) in its own home worktree + a `review-checkout` worktree + window. Verifies each green PR (tests + `/code-review`) one at a time, labels `READY-VERIFIED`, builds the ordered queue, then `/loop`. `-IntervalMin 5`. Never merges. |
| `dispatch/dispatch-worktree.ps1` | Headless one-shot `claude -p` (logs to file) — when you do NOT want an interactive pane |
| `dispatch/dispatch-codex.ps1` | **Headless `codex exec` build-ahead lane.** Provisions a worktree (shared `Initialize-WorkerWorktree`) then runs Codex to a green PR in the **background**, logging to `.orchestrator/logs/<name>.{jsonl,log}`. Fan out N to fill a verify queue. No psmux pane, no boot handshake. `-Name` + `-Task`/`-Bootstrap`/`-BootstrapFile`; `-Wait` to block. |
| `teardown/close-worker.ps1` | **Junction-first** post-merge teardown. `-Name <worker>`. |
| `teardown/cleanup-worktrees.ps1` / `nuke-worktrees.ps1` / `kill-worktree-agents.ps1` | Cleanup helpers |
| `server/dev-server.ps1` | Start/stop/check a detached dev server. `-Action start\|stop\|status -Dir <worktree>` |
| `status/check-worktree-health.ps1` | Health (git, deps, env). `-Name <n>\|-All [-Json]` |
| `status/check-headless-workers.ps1` | **Monitor the headless build-ahead lane.** Reports each `dispatch-codex.ps1` worker's state (RUNNING/COMPLETE/BLOCKED/EXITED) + PR URL from its meta + logs (they are NOT psmux windows). `-Config <cfg> [-Json]`. |
| `status/install-worktree-hooks.sh` | Install per-worktree status hooks (optional; psmux capture-pane is the primary channel) |
| `util/kill-port.ps1` / `force-remove-dir.ps1` | Low-level helpers (no config) |
| `lib/_session-config.ps1` / `_session-brief.ps1` | Shared loader + brief generator (dot-sourced; never invoked directly) |

## Critical Rules (preserved from the proven pipeline)

1. **Use psmux, never Windows Terminal.** No `wt new-tab`, no SendKeys.
2. **Full `workerCmdPath` in panes** — psmux pwsh runs `-NoProfile`, so bare `claude` isn't found.
3. **Workers run `--dangerously-skip-permissions`** (scoped to their own branch, you review the PR). The orchestrator/main session does NOT.
4. **CLAUDECODE is cleared in panes** before launch (the dispatch scripts do this) so workers can spawn the specialized agent team.
5. **Boot handshake, not blind sleep** — dispatch polls `capture-pane`, auto-picks "2" on the accept screen, waits for the "bypass permissions on" footer before sending the brief.
6. **Junction node_modules, do NOT install** in worker worktrees.
7. **Junction-first teardown** — `close-worker.ps1` detaches the node_modules junction(s) BEFORE `git worktree remove`. Never `git worktree remove` a worktree whose junctions are still attached.
8. **No auto-merge.** The orchestrator never runs `gh pr merge`. Merges are user-authorized ("merge it").
9. **`/loop` is the cron.** Never use Windows scheduled tasks or PowerShell `Start-Sleep` polling loops. The PS scripts' job ends after launching Claude.
10. **Reviewer verifies in its OWN checkout worktree, never the main repo.** The reviewer (overseer) checks out PR branches only in `<wt>/review-checkout`, runs tests + `/code-review` there, labels `READY-VERIFIED`, and produces an ordered merge queue. It NEVER merges (Rule 8) and NEVER touches `<repo>`'s working state (like the orchestrator). One PR at a time, sequenced by file overlap.
11. **Review routing (how the user sees a PR).** A **frontend-only** PR is reviewed on the **Vercel preview** (report the URL, no local checkout). A **backend / full-stack** PR must be **checked out locally** so the user can run it on 3000/8000 — a preview cannot exercise backend behavior. Classify with `gh pr diff <n> --name-only` vs the team `ownsPaths`. See the Merge protocol.
12. **Do NOT auto-tear-down workers.** A merged PR does NOT make a worker disposable — keep its worktree + psmux window alive so the user can iterate (tell the worker to fix → push → re-review, or work the checked-out branch) or assign more tasks. Tear down (junction-first, `close-worker.ps1`) ONLY when the user explicitly says that worker is done. The work is on the remote regardless, so there's no rush.
13. **Worker briefs are data-driven + CLI-aware.** Dispatch with `-Mode feature|iteration` and `-Spec <path>` so the brief leads with the work type + the authoritative spec; `-WorkerCliName codex` runs a Codex worker (it gets file-lanes but not Claude's `subagent_type` agents). Workers run **scoped unit tests + typecheck**, never the full suite (CI runs that). All of this lives in `New-WorkerBrief` — the dispatchers just pass it through.

## Detailed References

- `list`, `start`, `resume`, `finish` — [reference/commands-core.md](reference/commands-core.md)
- `monitor` — [reference/commands-monitor.md](reference/commands-monitor.md)
- `server-start/check/stop` — [reference/commands-server.md](reference/commands-server.md) and [reference/server-rules.md](reference/server-rules.md)
- `pull` — [reference/commands-pull.md](reference/commands-pull.md)
- `cleanup` — [reference/commands-cleanup.md](reference/commands-cleanup.md)
- `orchestrate` — [reference/commands-orchestrate.md](reference/commands-orchestrate.md)
- `review` / `review-start` (the reviewer/overseer loop) — [reference/commands-review.md](reference/commands-review.md)
- build protocol (teams, testing, sub-agents) — [reference/build-protocol.md](reference/build-protocol.md)
- psmux command + keyboard reference — [reference/psmux-cheatsheet.md](reference/psmux-cheatsheet.md)
- the full start/middle/end parallel workflow — [reference/psmux-workflow.md](reference/psmux-workflow.md)

---

## `list`

1. `git -C <repo> worktree list`
2. `psmux list-windows -t <sess>` (which worktrees have live workers)
3. Per worktree: git health, deps (config node_modules mappings), env files
4. Display table: Name, Branch, Window (live?), Health

Use `check-worktree-health.ps1 -All -Config <cfg>` for the health column.

---

## `start <name>`

Create a worktree and dispatch an interactive psmux worker. `$ARGUMENTS[1]` is the name.

**Short version** (full steps in [reference/commands-core.md](reference/commands-core.md)):

0. **CHECK EXISTING STATE** — `gh pr list --repo <gh>` for open/merged PRs on this branch + `git -C <repo> worktree list`. If a green PR exists, report and STOP (prevents duplicate work).
1. Verify main repo on `<base>` and healthy (typecheck/build/test gate from the project's `layout.testCmd`s).
2. Decide the task: a hand-written description, or a spec pointer. You can pass it straight to dispatch as `-Task "<desc>"` — the script will generate the brief and inject the project's `teams` rules.
3. Dispatch:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name "<name>" -Task "<description + spec ref>" -Config "<repo>/.claude/session-plugin.json"
   ```
4. Report: branch, worktree path, psmux target (`<sess>:<name>`), attach command (`psmux attach -t <sess>`).
5. **AUTO-START MONITOR LOOP** — `/loop 3m /session monitor <name>`.

Never `cd` into the worktree from the main session. Watch it with `psmux capture-pane -t <sess>:<name> -p`.

---

## `start-issues <n> <n> ...`

Bulk-dispatch one worktree worker per GitHub issue number.

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch-issues.ps1" -Issues <n>,<n>,<n> -Config "<repo>/.claude/session-plugin.json"
```

Each issue: `gh issue view` (skip if not OPEN) → slug from title → branch/window
`fix/<n>-<slug>` → brief (issue body + project team rules + test/commit/PR
contract, with `Closes #<n>`) → `psmux-dispatch.ps1`. Workers run in parallel
once launched. Report the per-issue status table at the end.

**When to use:** post-scaffold issue-backlog blast (issues already have clear
acceptance criteria). NOT for greenfield scaffolds — those use `start <name>`.

---

## `resume <name>`

1. Verify main repo. 2. Health-check the worktree (`check-worktree-health.ps1 -Name <name>`). Repair gaps. 3. If a psmux window exists, `capture-pane` to see state; else re-dispatch with `-SkipDeps` to re-add the window. 4. Report branch, last commits, repairs. See [reference/commands-core.md](reference/commands-core.md).

---

## `finish <name>`

Commit → test → rebase on `origin/<base>` → push → `gh pr create --repo <gh> --base <base>`. Does NOT merge or remove worktrees. See [reference/commands-core.md](reference/commands-core.md).

---

## `monitor <name>`

Single poll cycle: `psmux capture-pane -t <sess>:<name> -p` → analyze (building / waiting / stuck / errored / done) → `send-keys` correction if needed → report. Stop when a PR exists or the user stops the loop. `/session start` auto-invokes via `/loop 3m /session monitor <name>`. See [reference/commands-monitor.md](reference/commands-monitor.md).

---

## `server-start` / `server-check` / `server-stop`

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start|status|stop -Dir "<wt>/<name>" -Config "<repo>/.claude/session-plugin.json"
```
See [reference/commands-server.md](reference/commands-server.md).

---

## `pull`

PR dashboard → pull merged work into `<base>` → cleanup landed worktrees. Run from the MAIN session. Principle: show everything, touch nothing, until the user says go. See [reference/commands-pull.md](reference/commands-pull.md).

---

## `cleanup`

Remove zombie worktree dirs + orphan psmux windows (ask before removing). See [reference/commands-cleanup.md](reference/commands-cleanup.md).

---

## `orchestrate [dashboard|dispatch|poll|pull|cleanup|verify <name>|verify-all]`

Unified loop, run from a **dedicated orchestrator Claude** spawned by
`start-orchestrator.ps1` into `<sess>:orchestrator` (its own detached worktree,
NOT the main repo). `poll` is the main loop: read worker panes, nudge, flag green
PRs as `READY FOR USER REVIEW` (never merge), clean up after user-merged PRs,
self-terminate when no workers and no batch PRs remain. See
[reference/commands-orchestrate.md](reference/commands-orchestrate.md) — it bakes
in the no-auto-merge + batch-scoping contracts.

To launch the orchestrator (which also launches the reviewer unless `-NoReviewer`):
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-orchestrator.ps1" -IntervalMin 5 -Config "<repo>/.claude/session-plugin.json"
```

---

## `review`

**ONE reviewer cycle** — the body of the reviewer's `/loop`. Run from the dedicated
**Reviewer Claude** (the overseer) spawned by `start-reviewer.ps1` into `<sess>:reviewer`.

Compute the batch (open PRs whose branch matches an active worker worktree) → order by
file overlap → take the first un-verified green PR → check it out in `<wt>/review-checkout`
→ run the project's `config.layout` tests → run `/code-review` on the diff → label it
`READY-VERIFIED` (PASS) or request changes + nudge the worker (FAIL) → report the ordered
verified queue. **One PR per pass, never merges.** Self-terminate when no live workers and
no open batch PRs remain. See [reference/commands-review.md](reference/commands-review.md)
for the full protocol + contracts.

The reviewer is the automated form of the pre-merge verification in the Merge protocol
above: green CI is not enough; each PR is tested **and** reviewed in its own worktree
before it reaches your `READY-VERIFIED` queue, so "merge it" is acting on proven work.

---

## `review-start`

Spawn the dedicated reviewer Claude (its own home + checkout worktrees + psmux window +
`/loop`). Auto-launched by `start-orchestrator.ps1`; run it standalone when you started
workers without the orchestrator:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-reviewer.ps1" -IntervalMin 5 -Config "<repo>/.claude/session-plugin.json"
```
Interval resolves from `-IntervalMin`, else `config.review.intervalMin`, else 5 minutes.
Stop: `psmux kill-window -t <sess>:reviewer` (or it self-terminates).



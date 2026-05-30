---
name: session
description: Start, resume, finish, monitor, and orchestrate parallel git-worktree build sessions on Windows using psmux. Spawns Claude workers per worktree, polls them on /loop, reviews their PRs. Project-agnostic — driven by .claude/session-plugin.json. Triggers on "/session", "start a worktree", "dispatch workers", "orchestrate the build", "blast through these issues".
argument-hint: "[list|start|start-issues|resume|finish|pull|cleanup|monitor|server-start|server-check|server-stop|orchestrate] [name|issue-numbers]"
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
`githubRepo`, `defaultBranch`, `claudeCmdPath`, `layout`, and optional `teams`.

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

## Quick Reference

| Command | What it does |
|---------|-------------|
| `list` | Show all worktrees + psmux windows + health |
| `start <name>` | Create worktree, junction deps, dispatch a psmux worker, auto-start monitor loop |
| `start-issues <n> <n> ...` | **BULK.** One worktree worker per GitHub issue. Branch/window `fix/<n>-<slug>` |
| `resume <name>` | Health-check + repair worktree, re-dispatch its psmux window |
| `finish <name>` | Commit → test → rebase → push → create PR (no merge, no cleanup) |
| `pull` | PR dashboard, pull merged work into `<base>`, cleanup |
| `cleanup` | Remove zombie worktree dirs + kill orphan windows |
| `monitor <name>` | Single poll cycle: capture-pane → analyze → send-keys if needed |
| `server-start/check/stop` | Manage a detached dev server for a worktree |
| `orchestrate [...]` | Unified loop: dashboard / dispatch / poll / verify / pull / cleanup |

## Scripts (in this plugin, under `scripts/`)

Scripts are organized by function under `scripts/`. Invoke with the plugin root, e.g.:
```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name <name> -Task "<desc>" -Config "<repo>/.claude/session-plugin.json"
```

| Script (path under `scripts/`) | Purpose |
|--------|---------|
| `dispatch/psmux-dispatch.ps1` | **Primary dispatch.** worktree + env copy + node_modules junction + psmux window + Claude launch (boot handshake) + bootstrap. `-Name` + one of `-Task` / `-Bootstrap` / `-BootstrapFile`. Auto-injects the project's agent-team rules when given `-Task`. |
| `dispatch/psmux-dispatch-issues.ps1` | **Bulk dispatch.** `-Issues 510,511,512` (or positional). Fetches each issue, builds a brief, dispatches per issue. |
| `dispatch/start-orchestrator.ps1` | Spawn the dedicated orchestrator Claude in its own detached worktree + window with the no-auto-merge + batch-scoped brief, then `/loop`. `-IntervalMin 5`. |
| `dispatch/dispatch-worktree.ps1` | Headless one-shot `claude -p` (logs to file) — when you do NOT want an interactive pane |
| `teardown/close-worker.ps1` | **Junction-first** post-merge teardown. `-Name <worker>`. |
| `teardown/cleanup-worktrees.ps1` / `nuke-worktrees.ps1` / `kill-worktree-agents.ps1` | Cleanup helpers |
| `server/dev-server.ps1` | Start/stop/check a detached dev server. `-Action start\|stop\|status -Dir <worktree>` |
| `status/check-worktree-health.ps1` | Health (git, deps, env). `-Name <n>\|-All [-Json]` |
| `status/install-worktree-hooks.sh` | Install per-worktree status hooks (optional; psmux capture-pane is the primary channel) |
| `util/kill-port.ps1` / `force-remove-dir.ps1` | Low-level helpers (no config) |
| `lib/_session-config.ps1` / `_session-brief.ps1` | Shared loader + brief generator (dot-sourced; never invoked directly) |

## Critical Rules (preserved from the proven pipeline)

1. **Use psmux, never Windows Terminal.** No `wt new-tab`, no SendKeys.
2. **Full `claudeCmdPath` in panes** — psmux pwsh runs `-NoProfile`, so bare `claude` isn't found.
3. **Workers run `--dangerously-skip-permissions`** (scoped to their own branch, you review the PR). The orchestrator/main session does NOT.
4. **CLAUDECODE is cleared in panes** before launch (the dispatch scripts do this) so workers can spawn the specialized agent team.
5. **Boot handshake, not blind sleep** — dispatch polls `capture-pane`, auto-picks "2" on the accept screen, waits for the "bypass permissions on" footer before sending the brief.
6. **Junction node_modules, do NOT install** in worker worktrees.
7. **Junction-first teardown** — `close-worker.ps1` detaches the node_modules junction(s) BEFORE `git worktree remove`. Never `git worktree remove` a worktree whose junctions are still attached.
8. **No auto-merge.** The orchestrator never runs `gh pr merge`. Merges are user-authorized ("merge it").
9. **`/loop` is the cron.** Never use Windows scheduled tasks or PowerShell `Start-Sleep` polling loops. The PS scripts' job ends after launching Claude.

## Detailed References

- `list`, `start`, `resume`, `finish` — [reference/commands-core.md](reference/commands-core.md)
- `monitor` — [reference/commands-monitor.md](reference/commands-monitor.md)
- `server-start/check/stop` — [reference/commands-server.md](reference/commands-server.md) and [reference/server-rules.md](reference/server-rules.md)
- `pull` — [reference/commands-pull.md](reference/commands-pull.md)
- `cleanup` — [reference/commands-cleanup.md](reference/commands-cleanup.md)
- `orchestrate` — [reference/commands-orchestrate.md](reference/commands-orchestrate.md)
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
   powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name "<name>" -Task "<description + spec ref>" -Config "<repo>/.claude/session-plugin.json"
   ```
4. Report: branch, worktree path, psmux target (`<sess>:<name>`), attach command (`psmux attach -t <sess>`).
5. **AUTO-START MONITOR LOOP** — `/loop 3m /session monitor <name>`.

Never `cd` into the worktree from the main session. Watch it with `psmux capture-pane -t <sess>:<name> -p`.

---

## `start-issues <n> <n> ...`

Bulk-dispatch one worktree worker per GitHub issue number.

```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch-issues.ps1" -Issues <n>,<n>,<n> -Config "<repo>/.claude/session-plugin.json"
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
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start|status|stop -Dir "<wt>/<name>" -Config "<repo>/.claude/session-plugin.json"
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

To launch the orchestrator:
```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-orchestrator.ps1" -IntervalMin 5 -Config "<repo>/.claude/session-plugin.json"
```


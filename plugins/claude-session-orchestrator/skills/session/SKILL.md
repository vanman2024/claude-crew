---
name: session
description: The CONDUCTOR role in a crew build - the user's own session. Dispatches parallel git-worktree workers in psmux, launches the orchestrator and reviewer, relays the user's feedback into worker windows, brings workers' changes onto the user's machine to look at, merges on the user's go-ahead into the detected integration branch, pulls merged work into the local checkout, and tears workers down when the user says they are done. Windows + psmux, driven by .claude/session-plugin.json. Triggers on "/crew:session", "plan this spec", "make issues from this spec", "start a worktree", "dispatch workers", "blast through these issues", "tell the worker", "let me see it locally", "merge it", "pull it in".
argument-hint: "[status|plan|start|start-issues|launch|review-start|relay|local|merge|pull|done|list|resume|finish|restore|cleanup|server-start|server-check|server-stop] [name|issue-numbers|PR#]"
disable-model-invocation: false
allowed-tools: Bash(git *), Bash(gh *), Bash(node *), Bash(bash *), Bash(pwsh *), Bash(psmux *), Bash(powershell.exe *), Bash(cmd.exe *), Bash(pwd), Bash(cat *), Read, Glob, Grep, mcp__claude_ai_GitProjects__project_get, mcp__claude_ai_GitProjects__project_list, mcp__claude_ai_GitProjects__project_list_fields, mcp__claude_ai_GitProjects__project_search_items, mcp__claude_ai_GitProjects__github_resolve_issue, mcp__claude_ai_GitProjects__github_resolve_pull_request, mcp__claude_ai_GitProjects__project_add_item_with_fields, mcp__claude_ai_GitProjects__project_update_item_field, mcp__claude_ai_GitProjects__project_bulk_update_items
---

# Session: the conductor

## Which role are you? Check this first

Look for `.claude-bootstrap.md` in your working directory.

- **It exists** → you are a worker, the orchestrator or the reviewer. Follow that file. The
  orchestrator uses `/crew:orchestrate`, the reviewer `/crew:review`. Stop reading here.
- **It doesn't** → you are the **conductor**: the user's own session, in their main checkout.
  Everything below is yours. Take the role without being asked.

## The four roles

| Role | Where | Job | Merges? Touches the main checkout? |
|---|---|---|---|
| Workers | psmux window per worktree | Build one piece, open a PR | No |
| Orchestrator | psmux `orchestrator` window, `/loop` | Poll workers, nudge stuck ones, flag green PRs `READY FOR USER REVIEW` | No |
| Reviewer | psmux `reviewer` window, `/loop` | Test + `/code-review` each green PR, label `READY-VERIFIED`, order the merge queue | No |
| **Conductor (you)** | The user's session, main checkout | **Everything that involves the user or their machine** | **Yes, the only one** |

The orchestrator and reviewer are barred from merging and from the main checkout, so every
job that needs either falls to you. You are the user's single point of contact with the
workers.

**You watch the watchers.** The orchestrator steers workers (reads their panes, nudges them);
you don't duplicate that. What you do is make sure every terminal is up and doing its job:
the orchestrator and reviewer are running their loops, every worker's CLI is alive, nothing
is stuck with unsent input. That is `status`, on a slow `/loop` for as long as a build runs.

### What the conductor does, in the order it usually happens

0. **Plan**, when the user brings a spec and there are no issues for it yet (`plan`): cut the
   spec into issues **without inventing anything**, show the plan, create on their word.
1. **Dispatch** workers (`start`, `start-issues`) and make sure the orchestrator and
   reviewer are running (`launch`).
2. **Watch** every terminal: `/loop 10m /crew:session status`, started by `launch`. Fix what's
   down; bring the user what's ready.
3. **Relay** the user's feedback into the right worker's window (`relay`). "The intake form
   is missing the phone field" means: find the worker that owns it, and tell it.
4. **Bring changes local** so the user can see them before merge (`local`).
5. **Merge** when the user says so, into `<base>`, in overlap order (`merge`).
6. **Pull** merged work into the main checkout so the user has it locally (`pull`).
7. **Tear down** a worker only when the user says it is done (`done`).

**GitHub:** issues and PRs go through the **`gh` CLI**. The **project board** goes through the
**GitHub Projects MCP** (`mcp__claude_ai_GitProjects__*`), never `gh project`. You are the
board's only writer: each step above moves its issues along the board (Status Todo →
In Progress → In review → Done, Blocked while waiting on the user, and Deployed Staging →
Production as merges land). How, and which fields you may fill:
[reference/commands-board.md](reference/commands-board.md).

Steps 3 to 5 repeat per PR. Act on these without the user spelling out the mechanics: "merge
it" means the whole merge protocol, including the base check and the pull offer afterwards.

## STEP 0: resolve the config

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/resolve-config.ps1" -Config "<repo>/.claude/session-plugin.json"
```

If there is no config, tell the user to run `/crew:session-init`. Substitute:
- `<repo>` → `repoPath`, `<wt>` → `worktreesPath`, `<sess>` → `psmuxSession`, `<gh>` → `githubRepo`
- `<base>` → the **resolved** `defaultBranch`. Never read it from the raw JSON: there it may
  be `auto` or absent, meaning it is detected from where merged feature PRs actually land
  (a feature → staging → master repo resolves to `staging`). `defaultBranchSource` says how
  it was decided. Workers branch from `<base>`, PRs target it, merges go into it, `pull`
  brings it down.
- the board → `githubProject` (`ownerKind`, `owner`, `number`). Null → find it once, see
  [reference/commands-board.md](reference/commands-board.md).

The scripts resolve the same config themselves; pass `-Config "<repo>/.claude/session-plugin.json"`.

## psmux mental model

```
psmux SESSION (= <sess>) — persistent, survives terminal closing
  ├── WINDOW orchestrator — the orchestrator's /loop
  ├── WINDOW reviewer     — the reviewer's /loop
  └── WINDOW per worker   — shell in the worker's worktree, running the worker CLI
```

You read a window with `psmux capture-pane -t <sess>:<name> -p` and type into it with
`psmux send-keys`. Neither steals focus. `psmux attach -t <sess>` lets the user watch.

## When to use worktrees (and when NOT to)

| Use a worktree session for... | Do NOT use it for... |
|---|---|
| **Big bulk scaffolding** from a spec; **blasting an issue backlog** (N workers → N PRs) | Granular one-line fixes: one PR per issue, built right here (`/crew:build`) |
| Multiple independent big pieces with little file overlap | Global changes (routing, auth, layout shell): do those serially on `<base>` |

**Disjoint file-lanes rule:** dispatch **one worker per module / file-lane**. Workers that
touch the *same* module's files collide at merge time. Parallelize **across** modules;
**sequence** issues *within* a module.

## Quick Reference

| Command | What it does |
|---------|-------------|
| `status` | **Health watchdog** (the conductor's `/loop` body): every window up and working? Fix what isn't, then the overseers' latest reports |
| `plan <spec...>` | A spec with no issues yet → issues cut from the spec (nothing invented), approved by the user, wave 1 dispatched |
| `start <name>` | Worktree + worker for one piece of work, then `launch` if the orchestrator isn't up |
| `start-issues <n> <n> ...` | **Bulk.** One worker per GitHub issue (`fix/<n>-<slug>`), then `launch` |
| `launch` | Start the orchestrator (+ reviewer) if their windows aren't running |
| `review-start` | Start only the reviewer |
| `relay <worker> "<msg>"` | Send the user's feedback into a worker's window |
| `local <worker\|PR#>` | Run a worker's branch on the user's machine (or give the preview URL) |
| `merge <PR#...>` | The merge protocol: review routing → base check → overlap order → squash-merge |
| `pull` | Pull merged work from `<base>` into the main checkout |
| `done <worker>` | Tear a worker down (junction-first). Only when the user says so |
| `list` | Worktrees + windows + health |
| `resume <name>` | Health-check + repair a worktree, re-dispatch its window |
| `restore` | After a crash/reboot: rebuild the psmux session, resume each worker's conversation |
| `finish <name>` | Commit → test → rebase → push → PR for a worktree, by hand |
| `cleanup` | Remove zombie worktree dirs + orphan windows |
| `server-start/check/stop` | Manage a detached dev server for a worktree |

---

## `status`: are the terminals up and doing their jobs?

The conductor's watchdog, and the body of its `/loop 10m /crew:session status`. Also what
you run when the user asks how it's going.

1. **Health of every terminal:**
   ```
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/status/check-crew-health.ps1" -Config "<repo>/.claude/session-plugin.json" -Json
   ```
   One row per expected window (orchestrator, reviewer, one per worker worktree):

   | State | Meaning | What you do |
   |---|---|---|
   | `running` | CLI is up | Compare `PaneHash` with last tick: an **overseer** whose pane hasn't changed across a tick has a stalled loop → look at it (`capture-pane`) and restart it (`launch`) if it's hung |
   | `pending` | Text sits unsent in its input box: its loop and every nudge are blocked | Show the user the text (`Detail`). Submit it if it's clearly an intended instruction (`psmux send-keys -t <sess>:<name> C-m`; the first submit is sometimes eaten, so re-check and press again), else clear it (`C-u`) |
   | `dialog` | Stuck on a first-run screen (folder trust / bypass warning); it will never read its brief | `capture-pane` to read it. Its options are a menu, not numbered: `psmux send-keys -t <sess>:<name> Down` until `❯` is on the "Yes" option (re-capture to check), then `Enter`. Then send its brief line with `send-to-worker.ps1` (`Read .claude-bootstrap.md and follow it exactly.`) |
   | `exited` | Window is there, CLI has quit | Overseer → `launch`. Worker → `resume <name>` |
   | `missing` | No window | Overseer → `launch`. Worker whose PR is open or unstarted → `resume <name>` (ask first). Worker whose PR merged → dormant, just count it |

   Fix overseers without asking: they hold no user work. Ask before resuming workers.
2. **What the overseers report**, read from their panes, not re-derived:
   ```
   psmux capture-pane -t <sess>:orchestrator -p -S -80
   psmux capture-pane -t <sess>:reviewer -p -S -80
   ```
3. **Board in step?** `project_search_items` for the batch. A PR opened since the last tick →
   its item to **In review**. Board behind reality → advance it, say so in one line.
   Connector unavailable → say the board isn't being updated.
4. **Next wave?** If a `plan` left later waves undispatched, check whether all of a wave's
   `Depends on` issues are now merged. If so, say that wave is unblocked (dispatch on the
   user's word).
5. **Report**, compactly: anything you fixed; then ready for review (and how: preview or
   `local`), the verified queue, blocked workers, merged PRs. One line each. On a `/loop`
   tick with nothing new and nothing fixed, say so in one line.
6. **Stop the loop** when no workers, no open batch PRs, no pending waves and no overseers remain.

## `plan <spec path...>`: a spec, but no issues yet

The user brings a spec, not issues. Don't dispatch from a spec you haven't cut up, and don't
write issues that say more than the spec does. Full protocol:
[reference/commands-plan.md](reference/commands-plan.md).

1. Read the spec IN FULL; check which issues already exist for it (reuse, don't duplicate).
   Too vague to split → say what's missing and ask. Don't draft.
2. Cut along the spec's own sections: one worker, one file-lane, one PR per piece. Order them in
   **waves** by dependency (schema → API → UI).
3. **Invent nothing.** Every requirement and acceptance criterion comes from the spec, with its
   section. Where the spec is silent (a field, an endpoint, a limit, missing acceptance), that's
   an **open question for the user**, not a value you pick. A piece blocked on one is
   `needs-decision` and waits.
4. Show the plan table + open questions. **Create nothing until the user says go.**
5. Create issues with `gh issue create --body-file`, headed by `Spec:` / `Mode:` lines. The
   dispatcher reads them, so the worker is briefed to build that spec as a feature, not to tweak
   existing code. **Put each one on the project board** (Todo for wave 1, Backlog for later
   waves, Blocked for `needs-decision`), filling only fields the spec or user states.
6. `start-issues` for wave 1 only, then `launch`. Later waves on the user's word, once their
   dependencies merge.

A single, already-clear piece doesn't need issues: `start <name> -Task "..."` with
`-Mode feature -Spec <path>` dispatches straight from the spec.

## `start <name>`

Create a worktree and dispatch a worker. Full steps: [reference/commands-core.md](reference/commands-core.md).

0. **Check existing state**: `gh pr list --repo <gh>` for PRs on this branch + `git -C <repo> worktree list`. A green PR already exists → report and STOP.
1. Decide the task: a description or a spec pointer. Pass it as `-Task "<desc>"`; the script
   builds the brief and injects the project's `teams` rules.
2. Dispatch:
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch.ps1" -Name "<name>" -Task "<description + spec ref>" -Config "<repo>/.claude/session-plugin.json"
   ```
3. Report: branch, worktree path, psmux target `<sess>:<name>`, `psmux attach -t <sess>`.
   If the work has an issue, move its board item to **In Progress**.
4. **`launch`** if the orchestrator window isn't running (it starts your `status` watchdog
   too). Don't start a per-worker monitor loop: steering workers is the orchestrator's job.

Never `cd` into a worktree from this session.

## `start-issues <n> <n> ...`

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/psmux-dispatch-issues.ps1" -Issues <n>,<n>,<n> -Config "<repo>/.claude/session-plugin.json"
```

Per issue: `gh issue view` (skip if not OPEN) → branch/window `fix/<n>-<slug>` → brief
(issue body + team rules + test/commit/PR contract with `Closes #<n>`) → dispatch. Report the
per-issue table, move each dispatched issue's board item to **In Progress**
(`project_bulk_update_items`), then **`launch`** if the orchestrator isn't running. Use for backlogs with
clear acceptance criteria; greenfield pieces use `start <name>`.

## `launch`

Start the overseers. Skip either one whose window already exists (`psmux list-windows -t <sess>`).

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-orchestrator.ps1" -IntervalMin 5 -Config "<repo>/.claude/session-plugin.json"
```

This also launches the reviewer (unless `-NoReviewer`). Both run in their own detached
worktrees and `/loop` themselves. Stop one with `psmux kill-window -t <sess>:<name>`; both
self-terminate once no workers and no open batch PRs remain.

Then **verify they came up**: about a minute later run `status`; both should be `running`
with a first report in their panes. And start your own watchdog, if it isn't already
running in this session: `/loop 10m /crew:session status`.

## `review-start`

Only the reviewer (for example when workers were started without the orchestrator):
```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-reviewer.ps1" -IntervalMin 5 -Config "<repo>/.claude/session-plugin.json"
```

## `relay <worker> "<message>"`: the user's feedback, into the worker

The user reviews a PR or a local run and says what's wrong. Get it to the worker that owns it.

1. **Find the worker.** The user may name it by worker name, branch, issue or PR number, or
   just by what's wrong. Map it with `git -C <repo> worktree list --porcelain` and
   `gh pr list --repo <gh> --json number,headRefName,title`. If more than one fits, ask.
2. **Check it's alive**: `psmux list-windows -t <sess>`. Gone → offer `resume <name>` first.
3. **Look before typing**: `psmux capture-pane -t <sess>:<name> -p -S -30`. If the worker
   is mid-task, the message still queues and is read at its next turn.
4. **Send it with the script**, never a bare `psmux send-keys`: words passed separately lose
   their spaces and a missed Enter leaves the message unsent, blocking that window:
   ```
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/send-to-worker.ps1" -Name <name> -Message "<message>" -Config "<repo>/.claude/session-plugin.json"
   ```
   It sends one line, presses Enter separately, and checks the input box emptied: `SENT:`
   or `SEND_FAILED: <why>`. Make the message a complete instruction: what's wrong, what done
   looks like, and "commit and push to the same branch so PR #<n> updates".
5. **Confirm it's acted on**: a minute later, `capture-pane` shows the worker working on it.
6. Tell the user what you sent. Once the worker pushes, the PR and the worker's worktree have
   the fix: `local` again, or a refreshed preview, shows it.

## `local <worker|PR#>`: let the user see it on their machine, before merge

Classify the PR: `gh pr diff <n> --name-only` against `config.teams` `ownsPaths`.

- **Frontend-only**: the Vercel preview is the review surface. Report its URL
  (`gh pr view <n> --json statusCheckRollup` / the PR's deployment comment). Offer a
  local run too.
- **Backend or full-stack**: it must run locally; a preview can't exercise the backend.

Run it **from the worker's own worktree**. It already has the branch, and git refuses to check
out one branch in two places, so never check PR branches out in the main checkout. Use
`-AutoPort` so it runs beside the user's own servers on 3000/8000 instead of colliding:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/backend-server.ps1" -Action start -AutoPort -Dir "<wt>/<name>" -Config "<repo>/.claude/session-plugin.json"
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start -AutoPort -ApiUrl http://localhost:<backend port> -Dir "<wt>/<name>" -Config "<repo>/.claude/session-plugin.json"
```

Skip the backend line for a frontend-only change, and drop `-ApiUrl` to point at the main
backend. Give the user the URL(s) it printed (`AUTO_PORT=...`). When the worker pushes a fix, the
worktree already has it and the server hot-reloads. Stop servers with `-Action stop -Port <n>`
when the user is done looking.

After the merge, `pull` is how the user gets the change in their own checkout.

## `merge <PR#...>`: when the user says "merge it"

Never merge before the user has reviewed, and never merge on your own initiative.

1. **Review routing done?** Each PR was seen on its preview or via `local`, or the user says
   to skip that. If the reviewer is running, prefer PRs it labelled `READY-VERIFIED`, in its
   queue order.
2. **Base check.** `gh pr view <n> --json baseRefName`. It must equal `<base>`. A PR aimed
   elsewhere (e.g. `master` in a repo that integrates on `staging`) is stopped and shown to the
   user, with the fix: `gh pr edit <n> --base <base>`. Don't retarget without saying so.
3. **Overlap order.** `gh pr view <n> --json files --jq '.files[].path'` for every candidate.
   Disjoint PRs merge in any order. PRs sharing a path go one at a time: merge the first,
   have the next one's worker rebase onto `<base>` (`relay`), re-verify, merge, repeat.
   Re-check `mergeable` after every merge.
4. **Squash-merge**: `gh pr merge <n> --repo <gh> --squash`. One commit per feature.
5. **Move the issue on the board**: into a staging `<base>` → **Deployed: Staging** (Status stays
   In review); into production → **Status: Done, Deployed: Production**. Never **Staging
   (verified)**: that is the user's call.
6. **Offer `pull`** so the user has the merged work locally.
7. **Leave the worker running.** The user may iterate on it or give it more work. Teardown is
   `done`, on the user's word only.

## `pull`: merged work into the user's checkout

Full steps: [reference/commands-pull.md](reference/commands-pull.md). Principle: show
everything, touch nothing, until the user says go.

- The main checkout must be on `<base>`. If it's on another branch, say so and ask; never
  switch branches under the user.
- **Uncommitted changes block the pull.** Show a grouped summary (by directory, and deleted vs
  modified) and let the user decide. Never stash, commit or discard their work unasked.
- Then `git -C <repo> pull --rebase origin <base>` and the project's smoke test.

## `done <worker>`: teardown, on the user's word

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/teardown/close-worker.ps1" -Name <worker> -Config "<repo>/.claude/session-plugin.json"
```

Junction-first: detaches `node_modules` junctions BEFORE `git worktree remove`, kills the
window, prunes. Only when the user says that worker is done. Never after a merge by default,
and never for a worker whose PR is still open unless the user insists.

## `list`

1. `git -C <repo> worktree list` 2. `psmux list-windows -t <sess>` 3. health per worktree:
`check-worktree-health.ps1 -All -Config <cfg>` 4. table: Name, Branch, Window (live?), Health.

## `resume <name>`

Verify the main repo; health-check the worktree (`check-worktree-health.ps1 -Name <name>`) and
repair gaps; if its window exists, `capture-pane` to see state, else re-dispatch with
`-SkipDeps`. See [reference/commands-core.md](reference/commands-core.md).

## `restore`

After a crash, power loss or reboot the psmux server is gone but the worktrees survive:
```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/restore-session.ps1" -Config "<repo>/.claude/session-plugin.json"
```
Rebuilds the session with a window per worktree and resumes each worker's conversation
(`claude --continue` / `codex resume --last`). `-Idle` resumes without nudging; `-Name <wt>`
for one. Then `launch` again.

## `finish <name>`

Commit → test → rebase on `origin/<base>` → push → `gh pr create --repo <gh> --base <base>`.
Does NOT merge or remove the worktree. See [reference/commands-core.md](reference/commands-core.md).

## `cleanup`

Remove zombie worktree dirs + orphan psmux windows (ask before removing). See
[reference/commands-cleanup.md](reference/commands-cleanup.md).

## `server-start` / `server-check` / `server-stop`

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start|status|stop -Dir "<wt>/<name>" -Config "<repo>/.claude/session-plugin.json"
```
See [reference/commands-server.md](reference/commands-server.md). For looking at a worker's
branch, `local` is the usual entry point.

---

## Scripts (under `scripts/`)

| Script | Purpose |
|--------|---------|
| `status/resolve-config.ps1` | The config as the scripts see it, including the resolved `<base>` |
| `status/check-crew-health.ps1` | The watchdog: every expected window's state (`running` / `pending` / `exited` / `missing`) + a pane hash to spot stalls |
| `dispatch/send-to-worker.ps1` | Type a message into a window and verify it was submitted |
| `dispatch/psmux-dispatch.ps1` | **Primary dispatch.** Worktree + env + deps + psmux window + worker launch + brief. `-Name` + `-Task`/`-Bootstrap`/`-BootstrapFile`; `-Mode feature\|iteration`, `-Spec`, `-IssueNumber`; `-WorkerCliName codex` for a Codex worker |
| `dispatch/psmux-dispatch-issues.ps1` | **Bulk dispatch**, one worker per issue. `-Issues 510,511,512` |
| `dispatch/start-orchestrator.ps1` | Orchestrator window + its `/loop`; also the reviewer unless `-NoReviewer` |
| `dispatch/start-reviewer.ps1` | Reviewer window + its home and `review-checkout` worktrees + `/loop` |
| `dispatch/restore-session.ps1` | Crash recovery: rebuild the session, resume each worker |
| `dispatch/dispatch-codex.ps1` | Headless `codex exec` build-ahead lane (no psmux pane) |
| `dispatch/dispatch-worktree.ps1` | Headless one-shot `claude -p` |
| `server/dev-server.ps1` / `server/backend-server.ps1` | Detached frontend / backend server for a worktree (`-AutoPort`) |
| `teardown/close-worker.ps1` | **Junction-first** teardown of one worker |
| `teardown/cleanup-worktrees.ps1` / `nuke-worktrees.ps1` / `kill-worktree-agents.ps1` | Cleanup helpers |
| `status/check-worktree-health.ps1` | Health (git, deps, env). `-Name <n>\|-All [-Json]` |
| `status/check-headless-workers.ps1` | State + PR of each headless worker |
| `lib/_session-config.ps1` / `_session-brief.ps1` | Shared loader + brief generator (dot-sourced) |

## Critical Rules

1. **Use psmux, never Windows Terminal.** No `wt new-tab`, no SendKeys.
2. **Full `workerCmdPath` in panes.** psmux pwsh runs `-NoProfile`, so bare `claude` isn't found.
3. **Workers run `--dangerously-skip-permissions`** (scoped to their own branch; the user reviews the PR). The conductor does NOT.
4. **Run scripts with `pwsh`**, never `powershell.exe`: the lib refuses Windows PowerShell 5.1.
5. **Boot handshake, not blind sleep.** Dispatch waits for the worker's ready footer before sending the brief.
6. **Worker deps follow `worktreeDeps`**: `junction` shares the main checkout's `node_modules`, `install` gives each worktree its own.
7. **Junction-first teardown.** Never `git worktree remove` a worktree whose junctions are still attached; use `close-worker.ps1`.
8. **Only the conductor merges**, and only on the user's word.
9. **`/loop` is the cron.** The orchestrator and reviewer loop every few minutes and steer the work; the conductor loops `status` every ~10 minutes and keeps the terminals healthy. The conductor does not nudge workers on its own; it relays the user's feedback.
10. **Never check a PR branch out in the main checkout.** Run it from the worker's worktree (`local`).
11. **Review routing.** Frontend-only → Vercel preview. Backend / full-stack → a local run.
12. **Workers stay alive after merge.** Teardown (`done`) only on the user's word.
13. **Worker briefs are data-driven + CLI-aware** (`-Mode`, `-Spec`, `-WorkerCliName`). Workers run scoped tests + typecheck; CI runs the full suite.
14. **`gh` for issues and PRs; the GitHub Projects MCP for the board; never `gh project`.** Only the conductor writes to the board.

## Detailed References

- `plan` (spec → issues, nothing invented): [reference/commands-plan.md](reference/commands-plan.md)
- the project board (GitHub Projects MCP; `gh` for issues/PRs): [reference/commands-board.md](reference/commands-board.md)
- `start`, `resume`, `finish`, `list`: [reference/commands-core.md](reference/commands-core.md)
- `pull`: [reference/commands-pull.md](reference/commands-pull.md)
- `cleanup`: [reference/commands-cleanup.md](reference/commands-cleanup.md)
- servers: [reference/commands-server.md](reference/commands-server.md), [reference/server-rules.md](reference/server-rules.md)
- build protocol (teams, testing, sub-agents): [reference/build-protocol.md](reference/build-protocol.md)
- psmux commands: [reference/psmux-cheatsheet.md](reference/psmux-cheatsheet.md)
- the whole start-to-finish workflow: [reference/psmux-workflow.md](reference/psmux-workflow.md)
- what the orchestrator does: `/crew:orchestrate` ([its reference](../orchestrate/reference/commands-orchestrate.md))
- what the reviewer does: `/crew:review` ([its reference](../review/reference/commands-review.md))

# Parallel Claude Workflow on Windows (psmux + worktrees)

Companion to [psmux-cheatsheet.md](psmux-cheatsheet.md) (the keyboard/command
reference). This is the **workflow** — start, middle, end of running parallel
Claude workers across git worktrees with the session orchestrator.

Placeholders (from `.claude/session-plugin.json`): `<sess>` = psmuxSession,
`<repo>` = repoPath, `<wt>` = worktreesPath, `<base>` = defaultBranch,
`<gh>` = githubRepo.

---

## Mental model — the most important thing

```
Terminal app (your view)
  └── ONE tab attached to ONE psmux session at a time
        └── psmux SESSION (<sess>) — persistent, survives terminal closing
              └── WINDOWS — each window = ONE WORKTREE
                    └── PANES — a shell rooted IN that worktree (usually a worker Claude)
```

Critical: **a psmux window isn't just a terminal — it's a shell `cd`'d into a
separate git worktree on disk.** Each worktree is an isolated checkout of a
feature branch with its own (junctioned) `node_modules`, its own `.env`, its own
branch. So when the worker Claude commits, it commits to *that* branch.

| Layer | What it is | Lifetime |
|---|---|---|
| Terminal tab | Your view | Closes with the tab |
| psmux session | Coordination unit | Until `psmux kill-session` |
| psmux window | One worktree, one task | Until `Ctrl+B + &` or session killed |
| psmux pane | A shell (usually Claude) | Until `Ctrl+B + x` or shell exits |
| Worktree on disk | Git working tree | Until `git worktree remove` (use `close-worker.ps1`) |

A worktree exists independently of psmux — psmux just runs a shell inside it.

---

## START — kicking off parallel work

### When this is the right tool

| Use it when | Don't use it when |
|---|---|
| 2+ independent tasks with little file overlap | One task with sprawling cross-cutting changes (single branch on `<base>`) |
| Initial scaffolding from a clear spec | Open-ended exploration you can't scope |
| Iterating on different modules | All work touches the same file/component |
| You want a preview/PR per task | Work needs a single-instance resource (e.g. one backend port) |

### Pre-flight (once)

1. `psmux ls` — confirm psmux is alive.
2. Confirm `gh auth status`, that `workerCmdPath` exists, and that the main repo
   has installed deps at each `nodeModules` mapping (workers junction these — they
   do NOT install).
3. Make sure the tasks you're parallelizing have clear acceptance criteria.

### Per-task dispatch — the plugin does this for you

`/session start <name>` (or `/session start-issues <n>...` for a GitHub issue
backlog) runs `dispatch/psmux-dispatch.ps1`, which performs every step below in
one shot:

1. **Create the worktree** off `origin/<base>`:
   `git worktree add <wt>\<name> -b <branch> origin/<base>`
2. **Copy env files** (from `config.layout`) main → worktree.
3. **Junction `node_modules`** (from `config.layout`) from main — no install, no duplication.
4. **Write `.claude-bootstrap.md`** at the worktree root (the brief, with the
   project's agent-team rules injected — see [build-protocol.md](build-protocol.md)).
5. **Add a psmux window**: `psmux new-window -t <sess> -n <name> -c <wt>\<name>`
6. **Clear `CLAUDECODE`**, then launch the worker with the **boot handshake**
   (auto-accept the bypass-permissions screen, wait for the "bypass permissions
   on" footer), then send the brief instruction + a standalone Enter.

The worker takes over from there: plan → build (with the specialized agents) →
test → commit → push → open a PR → signal `WORKTREE_STATUS: COMPLETE`.

**Why `--dangerously-skip-permissions` is the default for workers:** without it,
each tool use pauses for approval, killing parallel throughput. With it, workers
run unattended; the safety gate moves to **PR review before merge**. Do NOT use
the flag for the main/orchestrator session or anything without a PR review step.

---

## MIDDLE — while everything runs

### Your role
- Attach: `psmux attach -t <sess>`; switch worktrees with `Ctrl+B + 0/1/2/...`
- Split panes (`Ctrl+B + %` / `"`) to add a dev-server or tests pane.
- Scroll back: `Ctrl+B + [`.
- Detach anytime: `Ctrl+B + d` — sessions keep running.

### The orchestrator's role (autonomous, via `/loop`)
Launch it with `dispatch/start-orchestrator.ps1`. From its own detached worktree
window it runs `/session orchestrate poll` every N minutes:

1. `psmux capture-pane` on each worker pane; read the last ~25 lines.
2. Detect state — **working** (no action), **waiting for input** (answer it),
   **stuck** (nudge), **errored** (report/correct), **done** (PR opened → flag
   `READY FOR USER REVIEW`, stop polling that worker).
3. Send nudges via `psmux send-keys -t <sess>:<name> "<msg>" Enter`.
4. Flag green, mergeable PRs in the batch as ready. **It never merges.**
5. After **you** merge a PR, it tears that worker down with `close-worker.ps1`.
6. Self-terminates when no live workers and no open batch PRs remain.

`/loop` is the cron — there are no Windows scheduled tasks or PowerShell sleep loops.

### Things you can do without leaving psmux

| Thing | How |
|---|---|
| Pause a worker | Switch to its window, press `Esc` (interrupt) or `Ctrl+C` |
| Take over typing | Just type in the pane (you share input with the worker — be intentional) |
| Shell next to Claude | `Ctrl+B + %` to split, run `git status` / tests there |
| Dev server alongside | `Ctrl+B + "`, then `server/dev-server.ps1 -Action start -Dir <wt>\<name>` |

### Frontend / preview visibility
If your project deploys previews per PR (e.g. a Vercel preview), that's the
canonical review path — open the preview URL on the PR. For local dev, split a
pane and use `server/dev-server.ps1` (each worktree can use a different port).

### Single-instance backends
If your project has a backend that must run as a single instance (one port),
**serialize** its testing across worktrees: stop the running instance, switch to
the worktree you want to test, start it there, test, stop it, and let the other
workers keep editing files (they edit freely without running the backend).

---

## END — landing the work

### Per worker
When a worker opens its PR (`gh pr create ... --base <base> ... Closes #N`) it
goes quiet. Your turn:
1. Review the preview / diff.
2. Give feedback in its pane (type; it reads and iterates).
3. Iterate until it's right; confirm CI is green.
4. **Merge** — you authorize it ("merge it"); the orchestrator never merges.

### Cleanup after merge — junction-first

Always tear down with the plugin script (it detaches the `node_modules`
junction(s) BEFORE removing the worktree, so the main checkout isn't gutted):

```powershell
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/teardown/close-worker.ps1" -Name <name> -Config "<repo>\.claude\session-plugin.json"
```

The session and other worktree windows keep going. Pattern: spin up windows,
work, merge, tear down, repeat.

### Done for the day
```powershell
psmux ls                       # see what's alive
psmux kill-session -t <sess>   # end the whole session
```
(Or just detach with `Ctrl+B + d` and come back — `<sess>` will still be there.)

---

## Spec vs iteration — when this pattern fits

**Tightly-spec'd initial build → parallel works great.** Clear spec, multiple
independent features that don't overlap files; each parallelizes into its own
worker, PR, and preview.

**Iteration / post-launch polish → be careful.** Smaller, often-overlapping
changes are usually better as **one PR per issue, sequential**, on
`<base>`-derived branches — a single Claude is often faster than orchestrating
parallel workers. Parallel kicks back in when you have several distinct
iterations queued that touch different modules. A useful rhythm: **module by
module** — finish all the work in one module, then move to the next.

## When NOT to use this workflow
- Single one-line fix → just a `<base>`-derived branch, no worktree.
- Global config changes (routing, auth middleware, layout shell) → do serially; they break parallel workers.
- Tightly-coupled changes gated on a single-instance resource → hard to parallelize.
- Other workers are mid-flight on files you'd touch → coordinate first.

---

## Quick reference — daily commands

```powershell
# Status
psmux ls
psmux list-windows -t <sess>

# Attach / detach
psmux attach -t <sess>
Ctrl+B + d

# Switch / split (while attached)
Ctrl+B + 0/1/2/...        # switch window
Ctrl+B + %   /   "        # split left-right / top-bottom
Ctrl+B + arrows           # move between panes
Ctrl+B + z                # zoom pane

# Orchestration (capture + steer — no focus theft)
psmux capture-pane -t <sess>:<name> -p
psmux send-keys -t <sess>:<name> "msg" Enter

# Cleanup
# (prefer close-worker.ps1 for worktree teardown — junction-first)
psmux kill-window -t <sess>:<name>
psmux kill-session -t <sess>
psmux kill-server          # nuclear: end ALL
```


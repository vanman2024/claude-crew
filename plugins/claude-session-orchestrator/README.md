# claude-session-orchestrator

A **project-agnostic parallel-worktree build pipeline** for Claude Code on Windows.
Spawn a crew of Claude workers — each in its own git worktree and its own
[psmux](https://github.com/) window — let a dedicated orchestrator Claude poll
and steer them on Claude Code's native `/loop`, and review the PRs they open.
Everything is driven by one per-project config file. **No per-project script
copies. Single source of truth, many consumers.**

This packages a build pipeline that was iterated to a working state as a
per-project skill, into a distributable plugin. The working implementation is the
spec; this is a faithful, parametrized port.

---

## The model

**Two-Claude model.** The conversational Claude you chat with stays free. A
separate **orchestrator Claude** runs in its own psmux window and its own git
worktree (detached HEAD at `origin/<defaultBranch>`). It polls workers on
`/loop` — never via Windows cron or PowerShell sleep loops.

**Workers.** Each is a Claude Code process running `--dangerously-skip-permissions`
in its own psmux window, cwd = its own git worktree on a feature/fix branch. It
plans, builds, tests, commits, pushes, opens a PR, then idles.

**Build → Verify.** Parallel build phase (many workers), then a sequential verify
phase (you + the conversational Claude in the main checkout). **Merges are always
user-authorized** — the orchestrator never merges.

```
psmux SESSION (= config.psmuxSession)
  ├── WINDOW orchestrator   ← polls, steers, flags PRs READY FOR USER REVIEW, cleans up
  ├── WINDOW f036-international ← worker: plan → build → test → PR
  ├── WINDOW fix-510-...        ← worker
  └── WINDOW fix-511-...        ← worker
```

---

## Requirements

- **Windows** (PowerShell 5.1+ and `pwsh` 7 recommended; long paths enabled)
- **psmux** (the Windows tmux port) on `PATH`
- **git** with `core.longpaths=true`
- **GitHub CLI** (`gh`) authenticated
- **Claude Code** installed; know the full path to `claude.cmd`
  (usually `C:\Users\<you>\AppData\Roaming\npm\claude.cmd`)
- **Node.js** (used by the optional status hooks)

---

## Install

1. Add the `claude-crew` marketplace (once):

   ```
   /plugin marketplace add vanman2024/claude-crew
   ```

2. Install the plugin:

   ```
   /plugin install claude-session-orchestrator@claude-crew
   ```

3. In any project you want to orchestrate, scaffold the config:

   ```
   /session-init
   ```

   This detects sane defaults (repo path, github repo, default branch,
   `claude.cmd`), asks about your layout and optional agent teams, and writes
   `.claude/session-plugin.json`.

Updating the plugin on GitHub means every consuming project picks up the change on
its next plugin update — no script duplication anywhere.

---

## Configuration — `.claude/session-plugin.json`

Every project-specific value lives here. Nothing about any concrete project is
hardcoded in the plugin. See [`examples/`](examples/) for full files.

| Field | Meaning |
|-------|---------|
| `projectName` | Display name |
| `repoPath` | Absolute path to the main checkout |
| `worktreesPath` | Absolute path to the **sibling** worktrees dir (OUTSIDE the repo) |
| `psmuxSession` | psmux session name (one per project) |
| `githubRepo` | `owner/name` for `gh` |
| `defaultBranch` | e.g. `master` or `main` |
| `workerCmdPath` | Full path to the **agent CLI launched in each worker pane** (psmux panes lack the npm PATH, so use the full path). Defaults to Claude's `claude.cmd` — see "Worker CLI" below. |
| `devServer` | `{ port, dir }` for the dev server (optional) |
| `layout` | `root` or `monorepo-split` (see below) |
| `teams` | Optional agent-team mapping (see Phase 2) |

### Worker CLI (`workerCmdPath`)

This plugin **is a Claude Code plugin** — the skills, the `/session` command, the
orchestrator, and your conversational session all run *in Claude Code*. That part
is inherently Claude.

The **workers**, though, are CLI-agnostic. `workerCmdPath` is just the command the
dispatch scripts launch in each psmux pane — the worktree + psmux + brief +
orchestrator scaffold doesn't care what runs there. Today it defaults to Claude
(`claude.cmd`), but the launch step is a single indirection point that could point
at another agent CLI.

**Honest caveat:** the launch is currently *tuned to Claude* — the boot handshake
auto-handles Claude's bypass-permissions accept screen and waits for its "bypass
permissions on" footer, the `--dangerously-skip-permissions` flag is Claude's, and
the pane clears `CLAUDECODE`. Pointing `workerCmdPath` at a different CLI would work
for the worktree/psmux mechanics but would need the handshake generalized per CLI
(a planned enhancement). So: **scaffold is agent-agnostic; the launch is Claude-tuned
today.**

### Layout: `root`

Single app at the repo root.

```json
"layout": {
  "type": "root",
  "envFiles": [".env", ".env.local", ".env.test"],
  "nodeModules": "node_modules",
  "testCmd": "npx tsc --noEmit && pnpm test"
}
```

### Layout: `monorepo-split`

Multiple parts. Each part declares its env files, its `nodeModules` to junction,
an optional `pythonVenv`, and a `testCmd`. Use `<repo>` in a command when it must
reference the **main** repo (e.g. a shared venv python — workers reuse main's
installed deps by absolute path, they do not install).

```json
"layout": {
  "type": "monorepo-split",
  "parts": [
    { "name": "frontend", "path": "frontend", "envFiles": [".env.local", ".env.test"],
      "nodeModules": "frontend/node_modules", "testCmd": "cd frontend && npx tsc --noEmit && pnpm test" },
    { "name": "backend", "path": "backend", "envFiles": [".env"],
      "pythonVenv": ".venv", "testCmd": "& '<repo>\\backend\\.venv\\Scripts\\python.exe' -m pytest" }
  ]
}
```

The same scripts drive both layouts; behavior comes entirely from this config.

---

## Usage

All commands are subcommands of `/session` (it reads your config first):

| Command | What it does |
|---------|-------------|
| `/session list` | Worktrees + psmux windows + health |
| `/session start <name>` | Create worktree, junction deps, dispatch a worker, auto-start a monitor loop |
| `/session start-issues 510 511 512` | **Bulk** — one worker per GitHub issue (branch/window `fix/<n>-<slug>`) |
| `/session resume <name>` | Health-check + repair + re-dispatch |
| `/session finish <name>` | Commit → test → rebase → push → PR (no merge) |
| `/session monitor <name>` | One poll cycle for one worker |
| `/session pull` | PR dashboard, pull merged work, cleanup |
| `/session cleanup` | Remove zombie worktrees + orphan windows |
| `/session server-start\|check\|stop` | Manage a detached dev server |
| `/session orchestrate [dashboard\|dispatch\|poll\|verify\|verify-all\|pull\|cleanup]` | Unified orchestrator loop |

### Launch the autonomous orchestrator

```
powershell.exe -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-orchestrator.ps1" -IntervalMin 5 -Config "<repo>/.claude/session-plugin.json"
```

It spawns a dedicated orchestrator Claude with the no-auto-merge + batch-scoped
brief, runs one immediate poll, then `/loop 5m /session orchestrate poll`. It
flags green PRs as `READY FOR USER REVIEW`, cleans up after **you** merge, and
self-terminates when no workers and no batch PRs remain.

Stop it early: `psmux kill-window -t <session>:orchestrator`.

---

## Hard contracts (non-negotiable, baked in)

1. **No auto-merge.** The orchestrator never runs `gh pr merge`. You authorize merges ("merge it").
2. **Orchestrator doesn't touch the main checkout.** No `git checkout`, no `git pull` there. It lives in its own worktree.
3. **Batch scoping.** It only tracks PRs whose head branch matches an *active* worktree under `worktreesPath/` (excluding its own). Other branches/sessions are out of scope.
4. **Junction-first teardown.** On Windows, `git worktree remove` follows the `node_modules` junction into the main repo and deletes real files. `close-worker.ps1` `rmdir`s the junction(s) **first**.
5. **Self-terminate** when no live workers AND no open batch PRs remain.
6. **`/loop` is the cron.** No Windows scheduled tasks, no PowerShell sleep loops.

---

## Troubleshooting (lessons paid for)

- **Worker can't spawn its agent team / Task tool disabled** — the psmux server inherited `CLAUDECODE=1`. The dispatch scripts clear it (`$env:CLAUDECODE=$null`) in the pane before launch. If you launch manually, do the same.
- **`claude` not found in a pane** — psmux pwsh runs `-NoProfile` (no npm PATH). Always use the full `workerCmdPath`.
- **Worker died at launch / accept dialog** — the bypass-permissions accept screen needs option `2`, and the brief must be sent only after the "bypass permissions on" footer appears. The dispatch scripts poll `capture-pane` for this handshake instead of blind-sleeping.
- **Nudge text sits unsubmitted at `❯`** — Claude swallows Enter while a tool runs. Send a standalone `psmux send-keys ... Enter` after the message; the scripts do this.
- **Main repo's node_modules got gutted** — something ran `git worktree remove` with the junction still attached. Always tear down via `close-worker.ps1`.
- **Locked worktree dir won't delete** — use `pwsh -c "Remove-Item -Recurse -Force <path>"` (long paths enabled); `teardown/nuke-worktrees.ps1` has robocopy/rename fallbacks.
- **Worktrees must live OUTSIDE the repo** — never use the Agent tool's in-repo `isolation: worktree`; it commits gitlinks that corrupt `git status`. Worktrees go in the sibling `worktreesPath`.

---

## Phase 2: Teams (designed-for, forward-looking)

Today each worker is a single Claude Code instance, but the **agent roster a
worker uses is already project-declared** via `config.teams`, and the brief
generator injects those rules into every worker's `.claude-bootstrap.md`:

- Split work by **ROLE / FILE-LANE**, not feature-slice (component-builder owns `components/**`, page-generator owns `app/**/page.tsx`, endpoint-generator owns `backend/api/routes/**`, …).
- **Never** use `general-purpose` for build work when a specialized agent is configured for that lane.
- Launch independent agents in a **single message** so they run concurrently.
- If a needed agent is unavailable, the worker prints `BLOCKED: <agent> unavailable` rather than silently falling back.

Projects without specialized agents simply omit `teams` and get a generic
single-Claude build flow.

The spawn step is a clean indirection: today the dispatch scripts launch
`claude.cmd --dangerously-skip-permissions` reading `.claude-bootstrap.md`. A
future **Claude Teams** primitive (a coordinated team of Claudes per pane) can be
swapped in at exactly that one step without redesigning the worktree + psmux +
brief-delivery scaffold or the orchestrator's pane-I/O polling — those are the
stable contracts. The brief in `.claude-bootstrap.md` is expressible as a
single-Claude prompt today or a team-manifest pointer tomorrow.

---

## How it's organized

```
claude-session-orchestrator/
├── .claude-plugin/plugin.json
├── skills/
│   ├── session/          SKILL.md + reference/   (the orchestrator skill)
│   └── session-init/     SKILL.md                (the scaffold command)
├── scripts/
│   ├── lib/        _session-config.ps1, _session-brief.ps1   (shared, dot-sourced)
│   ├── dispatch/   psmux-dispatch[-issues], start-orchestrator, dispatch-worktree
│   ├── teardown/   close-worker, cleanup/nuke/kill-worktree-agents
│   ├── server/     dev-server
│   ├── status/     check-worktree-health, *-hook.sh, poll-*
│   └── util/       kill-port, force-remove-dir
├── templates/      worktree-hooks.json, ...
├── examples/       session-plugin.{monorepo-split,root}.json
└── tests/          Pester unit + integration tests
```

## Tests

```
cd plugins/claude-session-orchestrator/tests
Invoke-Pester -Path .
```

Unit tests cover config resolution, path/slug derivation, env/node-module mapping,
and brief generation (including team-rule injection). Full end-to-end dispatch
(live psmux + git worktree + Claude launch) is validated manually against a real
project, since it has live side effects.

## License

MIT


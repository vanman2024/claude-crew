# claude-session-orchestrator

A **project-agnostic parallel-worktree build pipeline** for Claude Code on Windows.
Spawn a crew of agent-CLI workers — each in its own git worktree and its own
[psmux](https://github.com/) window — let a dedicated orchestrator Claude poll
and steer them on Claude Code's native `/loop`, and review the PRs they open.
Everything is driven by one per-project config file. **No per-project script
copies. Single source of truth, many consumers.**

> **What's Claude and what isn't.** This is a **Claude Code plugin** — the skills,
> the `/session` command, the orchestrator, and your conversational session all run
> *in* Claude Code. The **workers** are CLI-agnostic: each pane just runs whatever
> `workerCmdPath` points at. It **defaults to Claude** (`claude.cmd`), and the launch
> is currently *Claude-tuned* (boot handshake, `--dangerously-skip-permissions`,
> `CLAUDECODE` clearing). Other agent CLIs (Codex, etc.) work for the
> worktree/psmux/brief mechanics but would need the handshake generalized per CLI —
> a planned enhancement. See [Worker CLI](#worker-cli-workercmdpath) for the full
> story. Short version: **scaffold is agent-agnostic; launch is Claude-tuned today.**

This packages a build pipeline that was iterated to a working state as a
per-project skill, into a distributable plugin. The working implementation is the
spec; this is a faithful, parametrized port.

---

## The model

**Two-Claude model.** The conversational Claude you chat with stays free. A
separate **orchestrator Claude** runs in its own psmux window and its own git
worktree (detached HEAD at `origin/<defaultBranch>`). It polls workers on
`/loop` — never via Windows cron or PowerShell sleep loops.

**Workers.** Each is an **agent CLI** (whatever `workerCmdPath` is — Claude's
`claude.cmd` by default, launched with `--dangerously-skip-permissions`) in its own
psmux window, cwd = its own git worktree on a feature/fix branch. It plans, builds,
tests, commits, pushes, opens a PR, then idles. The orchestrator only talks to the
pane (`capture-pane` / `send-keys`), so it doesn't care which CLI runs there.

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
- **Claude Code** — required to run the plugin itself (skills, `/session`, the orchestrator)
- **A worker agent CLI** — the command each worker pane runs (`workerCmdPath`). Defaults to Claude's `claude.cmd` (usually `C:\Users\<you>\AppData\Roaming\npm\claude.cmd`); see [Worker CLI](#worker-cli-workercmdpath)
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

The **workers**, though, are CLI-agnostic. `workerCmdPath` is the command the
dispatch scripts launch in each psmux pane — the worktree + psmux + brief +
orchestrator scaffold doesn't care what runs there. It defaults to Claude
(`claude.cmd`).

#### `workerCli` — how the worker launch + boot handshake are driven

The launch and the boot handshake are **data-driven** by an optional `workerCli`
profile, so you can run a non-Claude worker without editing any script. It can be:

- **omitted** → the `claude` preset (today's behavior), or
- **a preset name string** → `"claude"`, `"codex"`, or `"generic"`, or
- **an object** that extends a preset / fully specifies the launch:

| Field | Meaning |
|-------|---------|
| `preset` | base preset to extend (`claude` / `codex` / `generic`) |
| `cmd` | launch command (defaults to `workerCmdPath`) |
| `args` | launch args, e.g. `["--dangerously-skip-permissions"]` |
| `clearEnv` | env vars to null in the pane before launch, e.g. `["CLAUDECODE"]` |
| `accept` | `{ "matchAny": [...], "send": "2" }` — first-run accept screen + key to send |
| `ready` | `{ "matchAny": [...] }` — strings that mean the REPL is ready |
| `bootWaitSec` | fixed wait used **only** when there are no accept/ready patterns |

> **Pattern matching:** `accept.matchAny` / `ready.matchAny` are matched against the
> pane text **with all whitespace removed** (so write `"bypasspermissionson"`, not
> `"bypass permissions on"`). This makes matching robust to wrapping/spacing.

**Shipped presets:**
- **`claude`** (default, verified) — `args: --dangerously-skip-permissions`, clears
  `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT`, accepts the bypass screen with `2`, waits for
  the `bypass permissions on` footer.
- **`codex`** (verified) — the OpenAI **Codex** CLI. `args:
  --dangerously-bypass-approvals-and-sandbox --no-alt-screen` (the first is Codex's
  analog of `--dangerously-skip-permissions`; `--no-alt-screen` is **required** so the
  TUI renders inline — alt-screen mode breaks `capture-pane` scrollback in psmux).
  Answers Codex's per-directory *"Do you trust the contents of this directory?"* gate
  with `1` (Yes, continue), and treats the REPL as ready when the `permissions: YOLO
  mode` / `>_ OpenAI Codex` header appears. Set `workerCmdPath` to your `codex.cmd`
  (e.g. `C:\Users\<you>\AppData\Roaming\npm\codex.cmd`) and `"workerCli": "codex"`.
  Codex must already be logged in (`codex login`).
- **`generic`** — no args, no env clearing, **no accept handshake**; just a fixed
  `bootWaitSec` wait then sends the brief. Good for a CLI that boots straight to a
  prompt.

**Other CLIs (Gemini / Qwen / …):** we deliberately do **not** ship presets with
guessed prompt strings for CLIs we can't verify. Wire your CLI with an object,
supplying its *real* startup patterns. Example shape (verify the actual strings for
your CLI — these are placeholders):

```jsonc
"workerCmdPath": "C:\\path\\to\\your-cli.cmd",
"workerCli": {
  "preset": "generic",
  "args": ["--auto-approve"],            // your CLI's "skip approvals" flag
  "clearEnv": [],                         // any env vars that confuse a nested launch
  "accept": { "matchAny": ["trustthisfolder?"], "send": "y" },  // first-run gate, if any
  "ready":  { "matchAny": ["readyprompttoken"] },               // how you know it's up
  "bootWaitSec": 12
}
```

**Honest status:** the **`claude` and `codex` presets are verified** (each captured
from a live boot in a psmux pane). The scaffold (worktree + psmux + brief +
orchestrator pane I/O) is fully agent-agnostic; getting a *new* CLI to boot cleanly is
just a matter of getting its `accept`/`ready` patterns right in `workerCli`. The
orchestrator and the headless `dispatch-worktree.ps1` remain Claude (they run the
Claude-only skill / `claude -p`).

#### Headless build-ahead lane (`dispatch-codex.ps1`)

The `codex` *preset* above runs Codex as an **interactive** psmux worker (a pane you
watch + nudge, with the trust-gate/ready boot handshake). For the **build-ahead** lane
there is also a **headless** dispatcher that skips the pane and the handshake entirely:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/dispatch-codex.ps1" `
  -Name f042-backend -Task "Build X per specs/...md" -Config "<repo>/.claude/session-plugin.json"
```

It provisions the worktree with the **same** `Initialize-WorkerWorktree` the interactive
path uses (worktree + env + `.mcp.json` + brief + junctioned `node_modules`), then runs
`codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --json` in
the **background**, feeding the brief on stdin and logging the JSONL event stream to
`<worktreesPath>\.orchestrator\logs\<name>.jsonl` (final message → `<name>.last.txt`).

This is the **two-lane rhythm**: a build lane (fan out N headless Codex/Claude workers
that each run to a green PR, self-testing in their own worktree — zero strain on your
machine) feeding a verify lane (you pull each green PR into one local `<base>` checkout
and tier the effort: trivial → quick-merge, risky → full local verify). Resolve the
Codex command via `-CodexCmd`, `config.codexCmdPath`, or `codex` on `PATH`. Codex must
be logged in (`codex login`). Add `-Wait` to block and print the result instead of
launching in the background.

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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch/start-orchestrator.ps1" -IntervalMin 5 -Config "<repo>/.claude/session-plugin.json"
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


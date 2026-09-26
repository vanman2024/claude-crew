# Changelog

All notable changes to `crew` (directory: `plugins/claude-session-orchestrator`) are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **One skill per role.** The user's own session, the orchestrator and the reviewer all
  loaded the same `/crew:session` skill, which addressed its reader as the orchestrator. So
  the user's session never knew it was the one meant to relay feedback, bring changes
  local, merge and pull, and ran orchestrator-style sweeps instead. Now:
  - **`/crew:session` is the conductor** (the user's session). It opens with a role check:
    with no `.claude-bootstrap.md` in the working directory it is the conductor and acts as
    one. New subcommands: `status`, `launch`, `relay`, `local`, `merge`, `done`.
  - **`/crew:orchestrate`** (poll, monitor, verify) and **`/crew:review`** (one review cycle)
    are the overseers' skills. Their briefs and `/loop`s call them; their references moved
    with them.
- **The orchestrator no longer tears workers down after a merge.** Its brief and its
  reference told it to run `close-worker.ps1` on merged PRs, contradicting "workers stay
  alive until the user says done". It now reports `MERGED`; teardown is the conductor's
  `done`, on the user's word. `pull` lists landed workers and asks, instead of removing them.

### Added
- **`defaultBranch` is detected** (`"auto"` or absent): from where merged feature PRs actually
  landed (release PRs such as staging → master ignored), else a `staging`/`develop`/`dev`
  branch on origin, else origin's default. `session-init` copied GitHub's default branch, which
  is `master` in a feature → staging → master repo, so worker PRs targeted the wrong branch.
  A pinned `main`/`master` next to a `staging`/`develop` branch now warns.
  `status/resolve-config.ps1` prints what was resolved and why.
- **The conductor watches the terminals.** `status/check-crew-health.ps1` reports every
  expected window (orchestrator, reviewer, each worker) as `running`, `pending` (unsent text
  blocking its input box), `exited` (CLI quit to a shell prompt) or `missing`, with a pane hash
  to spot a stalled loop. `/crew:session launch` starts `/loop 10m /crew:session status`, which
  restarts dead overseers and asks before resuming workers.
- **`/crew:session plan <spec>`: a spec, but no issues yet.** The conductor cuts the spec
  along its own sections into one-worker, one-lane pieces ordered in dependency waves, and
  **invents nothing**. Every requirement and acceptance criterion comes from the spec, with its
  section. Where the spec is silent (a field, an endpoint, missing acceptance), it asks an open
  question, and a piece blocked on one is `needs-decision`. It shows the plan and creates no
  issues until the user says go, then creates them with `--body-file` and dispatches wave 1.
  Protocol: `skills/session/reference/commands-plan.md`.
- **Planned issues carry their spec to the worker.** `psmux-dispatch-issues.ps1` reads
  `Spec:` / `Work type:` header lines (`Get-IssueBriefHints`). Before, every issue-based worker
  was briefed as an ITERATION with no spec, so a new piece of a spec would have been told to
  change existing code only, and never read the spec.
- **`dispatch/send-to-worker.ps1`**: relays a message as one argument, presses Enter
  separately, and verifies it was submitted. A bare `psmux send-keys` with separate words
  lost its spaces and its Enter, leaving `WaitforCIonce1e085andreportback` unsent in a live
  worker's box.

### Added: the project board
- **The conductor keeps the GitHub Projects board in step with the build**, through the
  **GitHub Projects MCP**; issues and PRs stay on the **`gh` CLI**, and `gh project` is never
  used. New config key `githubProject` (`ownerKind`, `owner`, `number`), printed by
  `resolve-config.ps1`; `session-init` finds it with the MCP. The conductor is the board's only
  writer and moves each issue along its Status: **Ready** or **Backlog** when `plan` creates
  it, **In Progress** on dispatch, **In review** when its PR opens (seen on the `status` tick),
  then Deployed/Done on merge (see "Changed" above). It never claims verification. It follows the board README's
  field rules but fills only what the spec or user states; required fields it can't source are
  left empty and listed. An unavailable connector is reported, never replaced by `gh project`.
  Protocol: `skills/session/reference/commands-board.md`. Dogfooded read-only against a real
  board.

### Changed: how the conductor classifies board items (the settled five-field design)
- **Five fields, five questions**, as settled in dev-lifecycle's `issue-creation.md` §2b:
  - **Milestone**: when it ships.
  - **Pillar**: what area. The product's registry, for plumbing and features alike;
    **Unclassified** while undecided.
  - **Dependency order**: sequence.
  - **Phase**: **Foundation** for plumbing, **Develop** for feature-facing work.
  - **One label**: the kind of change (`bug` / `enhancement` / `refactor` / `discovery` /
    `chore`, never `feature` or `foundation`).
- **Status and Deployed are separate.**
  - Status runs **Todo → In Progress → In review → Done**, with **Blocked** while an item
    waits on the user (the board's "Needs you" tab). Waiting on another issue stays
    Backlog.
  - Deployed records **Staging** when merged to staging, then **Production** alongside
    Done. **Staging (verified)** is always the user's call.
- **The conductor classifies by reading each issue; it never copies a label into a field**,
  and it never sets Work type (being retired, dev-lifecycle #33).
- **Trackers for big pieces:** plans of five or more pieces get a `[Tracker]` parent issue
  with real sub-issues (through `gh`) and a board tab filtered to it (through the Projects
  MCP). This is the RedAI #964 pattern.
- The issue header that picks the worker brief is now `Mode: feature|iteration`. Older
  issues that say `Work type:` are still read.
### Fixed (found by dogfooding a real launch in a sandbox psmux session)
- **Every window's brief sat unsent.** Launchers typed the brief and pressed Enter once. The
  first submit after typing is sometimes eaten (Enter and C-m alike), and right after typing
  the input box can briefly draw empty. On a live launch the orchestrator, reviewer and worker
  all sat idle with their brief in the box. This is also what the conductor's watchdog found
  in a real crew (`pending`). New `Send-PaneMessage` waits until the text is visible in the box,
  submits, and repeats until it leaves. All launchers and `send-to-worker.ps1` use it, and the
  overseers' briefs tell them to nudge through `send-to-worker.ps1` too.
- **The orchestrator and reviewer never answered Claude's first-run screens.** They slept 8s
  and typed blind. On a new folder the brief landed on "Do you trust this folder?" with
  "No, exit" highlighted. The worker launcher sent "2" + Enter, but the options aren't
  numbered, so that Enter chose "No, exit" and quit Claude. `Wait-CliReady` (shared by all
  launchers) now answers by navigation: Down until the wanted option is highlighted, then
  Enter. It also handles several screens in a row. The health check reports a window stuck on
  one as `dialog`.
- **Windows loaded whichever crew copy was installed**, which could be months older than the
  conductor's and lack the skills their briefs name. Every Claude launch now passes
  `--plugin-dir` for the copy that launched it (`Get-PluginDirArg`).
- The health check retries an empty `psmux ls` before calling the session missing, so a
  momentary blip can't make the watchdog relaunch overseers that are running. It also ignores
  Claude's idle placeholder hint (`❯ Try "..."`).

### Fixed
- **Dispatch no longer dies mid `npm install` under Windows PowerShell 5.1.** Every
  documented invocation used `powershell.exe` (5.1). There, any PowerShell-side redirect
  of a native command's stderr — `*>`, `2>&1`, even `2>$null` — becomes an ErrorRecord,
  and under `ErrorActionPreference=Stop` npm's harmless `EBADENGINE` warning terminated
  `Initialize-WorkerWorktree` partway through the install: half-installed `node_modules`,
  no psmux window, no worker. The 0.4.1 `-NoProfile` fix did not cover this; it is the
  host, not the profile. Three parts:
  - **All docs and the orchestrator brief now launch scripts with `pwsh`**, not `powershell.exe`.
  - **`_session-config.ps1` refuses to load under 5.1** with a `pwsh` re-run hint, so a
    wrong host fails before any worktree is touched, rather than halfway through.
  - **The per-worktree install redirects inside `cmd`** (`cmd /c "npm install > log 2>&1"`),
    so no stderr ever reaches PowerShell's error stream on any host.
  - Regression tests: the lib is loaded under real `powershell.exe` and must refuse; the
    install line must not use a PS-side redirect; no doc may launch via `powershell.exe`.
- **The orchestrator and reviewer windows now save transcripts.** Their launchers cleared
  `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT` but not `CLAUDE_CODE_CHILD_SESSION`, which they
  inherit when started from a Claude session, so Claude showed "Transcript saving is off"
  and the window could not be resumed after a crash. They now clear it and set
  `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`, matching the worker launch.

## [0.4.2] — 2026-06-23

### Added
- **Workers now mandated to keep a task list the whole build.** The generated brief's
  "Plan first" step gained a hard rule: as soon as the plan is settled, turn it into a
  tracked task list (CLI-correct tool — Claude `TodoWrite`, Codex `update_plan`) and
  maintain it throughout (one task `in_progress` at a time, flip to `completed` when done,
  add tasks as they surface). Workers were drifting / dropping steps on long autonomous
  runs because they did not consistently track work; this makes it non-optional. New
  regression tests assert the mandate and the per-CLI tool name.

## [0.4.1] — 2026-06-20

### Fixed
- **Dispatch no longer dies on the user's PowerShell profile / git stderr ("session
  won't start").** Every documented invocation ran `powershell.exe -File` / `pwsh -File`
  **without `-NoProfile`**, so the interactive profile loaded and a failing
  `Import-Module posh-git` (plus git writing progress to stderr under
  `ErrorActionPreference=Stop`) aborted the worker dispatch every time. Two-part fix:
  - **`-NoProfile`** added to every `powershell.exe`/`pwsh` `-File` invocation across the
    skill docs, reference docs, README, and — critically — the **generated worker brief**
    (workers were told to run `pwsh -File dev-server.ps1`, so they hit it too).
  - **`GIT_REDIRECT_STDERR=2>&1`** set once in `_session-config.ps1` (every script
    dot-sources it first), so git progress goes to stdout and is never treated as a
    terminating error.
  - Regression guards in the test suite: no plugin `.ps1` may invoke `-File` without
    `-NoProfile`, the lib must set `GIT_REDIRECT_STDERR`, and the brief must use
    `pwsh -NoProfile` (121 tests green).

## [0.4.0] — 2026-06-17

### Added
- **Crash recovery — `restore-session.ps1` + `psmux-dispatch.ps1 -Continue`.** After a
  power loss / reboot / crash the psmux **server** dies (so `psmux attach` finds nothing)
  but the git worktrees on disk survive. `restore-session.ps1` rebuilds the psmux session
  and a window per surviving worktree and **resumes each worker's prior conversation**
  rather than starting cold:
  - **Resumes the actual conversation**, CLI-correct and verified from live help:
    `claude --continue` (flag) and `codex resume --last` (subcommand; cwd-filtered so it
    picks that worktree's own session). Both still pass the worker's YOLO/no-alt-screen
    flags. Unknown CLIs launch fresh and re-read `.claude-bootstrap.md`.
  - **`-Continue` is a true resume mode** in `psmux-dispatch.ps1`: requires the worktree
    to already exist, does NOT re-provision (no env copy, dep wiring, or brief overwrite),
    resolves the branch from the worktree's HEAD, and sends a short "you were interrupted,
    keep going" nudge instead of the first-time bootstrap. Run it BEFORE any fresh dispatch
    so the resumed pre-crash session is the most-recent one the CLI reattaches.
  - **Two cases handled automatically:** psmux session still alive (you only closed the
    terminal) → it just prints `psmux attach -t <sess>`; session gone → rebuild. Worktrees
    are discovered via `git worktree list --porcelain` (the `_preview` env is skipped).
  - **`-Idle`** rebuilds + resumes but sends no nudge (leave each worker idle to inspect a
    possibly half-written state first); **`-Name <wt>`** restores a single worktree.
  - Contract-tested in `dispatch-scripts.Tests.ps1` (full suite 118 green).

## [0.3.1] — 2026-06-17

### Fixed
- **Workers no longer kill Claude Code (and the whole crew) when freeing a port.**
  Nothing in the plugin ran a broad kill — but the brief never told workers *how* to
  free a port, so they improvised `taskkill /IM node.exe` / `Stop-Process -Name node`
  / blanket `npx kill-port`. On Windows, Claude Code, the orchestrator, the reviewer,
  and every worktree's `next dev` are all `node.exe`, so a name-based kill takes down
  the running session itself. The generated worker brief now carries a hard
  **"NEVER kill a process by name"** rule (forbidden commands listed) and points at the
  port-scoped path: `dev-server.ps1 -Action stop` / `kill-port.ps1 -Port <port>` (single
  owning PID only). Mirrored in `build-protocol.md` + `server-rules.md`; new regression
  test in `brief-generation.Tests.ps1`.
- **`worktreeDeps=install` no longer poisons the worktree path.** The per-worktree
  `pnpm install` wrote native stdout into `Initialize-WorkerWorktree`'s return pipeline,
  corrupting `$WtPath` and silently breaking psmux window creation downstream. Install
  output is now redirected to `.pnpm-install.log` in the package dir. (Rescued from a
  fix that had been made directly in the disposable plugin cache.)

## [0.3.0] — 2026-06-16

### Added
- **Per-worktree real dependency install (`worktreeDeps` config, default `"junction"`).**
  Worker worktrees previously always **junctioned** `node_modules` from the main checkout —
  fast and low-disk, but a junctioned `node_modules` is shared, so a second `next dev` (one
  per worktree) collides on it. Setting `"worktreeDeps": "install"` makes `Initialize-WorkerWorktree`
  do a **REAL per-worktree install** instead (lockfile-detected: pnpm/yarn/npm; with pnpm it
  hardlinks from the global store, so it's cheap after the first). Any stale junction is detached
  with `rmdir` first (link only — the main checkout is untouched) so the install is independent.
  This is what lets **every worktree run its own dev server / Playwright**. `"junction"` (default)
  preserves the old behavior; unknown values fall back to junction. New helpers
  `Get-WorktreeDepsMode` / `Get-DetectedInstallCmd` in `lib/_session-config.ps1`, covered by
  `tests/config-resolution.Tests.ps1` (+6 tests). Both example templates ship
  `"worktreeDeps": "install"`, and `session-init` documents the key.

## [0.2.7] — 2026-06-13

### Changed
- **Skill docs aligned with the new dispatch + review/merge workflow** (so launching the
  skill actually uses it, not just the scripts):
  - **Review routing** — `SKILL.md` Merge protocol + Critical Rule 11, `commands-orchestrate.md`
    Phase 5, `commands-review.md` Phase 5: a **frontend-only** PR is reviewed on the **Vercel
    preview**; a **backend / full-stack** PR is **checked out locally** so the user can run it on
    3000/8000 (a preview can't exercise backend). Classify by `gh pr diff --name-only` vs team
    `ownsPaths`.
  - **No auto-teardown** (Critical Rule 12, `commands-orchestrate.md` Contract 3 / Phase 5):
    workers stay alive after merge for iteration; `close-worker.ps1` runs only when the user says a
    worker is done.
  - **Dispatch capabilities documented** (Critical Rule 13 + scripts table): `-Mode
    feature|iteration`, `-Spec <path>`, `-WorkerCliName codex`, and scoped-unit-tests-not-full-suite.

## [0.2.6] — 2026-06-13

### Changed
- **Workers run SCOPED unit tests, not the full suite.** The brief's test gate (section 5)
  was the project's *full* test command (whole `pytest` / `tsc` + `pnpm test`), so workers
  burned 15-30 min re-running the entire codebase — redundantly, since GitHub Actions CI
  already runs the full Backend + Frontend suites on every PR (and the full local run can
  hang on integration tests needing live services). `Format-TestSection` now instructs the
  worker to run ONLY the unit tests covering its change (scope the runner to the specific
  test files/modules) plus the typecheck, and explicitly NOT to run the whole suite — CI
  does that. The configured commands remain as the tooling reference.

## [0.2.5] — 2026-06-13

### Fixed
- **CLI-aware agent section so Codex workers don't block on Claude's agents.** The
  `config.teams` agents/skills are Claude Code plugin subagents (`subagent_type` names);
  a Codex worker has no such system and was correctly printing `BLOCKED: <agent>
  unavailable` per the brief's own rule. `Format-TeamsSection` / `New-WorkerBrief` now
  take `-WorkerCli`: for a non-Claude worker the brief keeps the **file-lane / path-
  ownership** discipline but drops the "use these exact `subagent_type` names / BLOCK if
  missing" mandate and tells the worker to build directly (it may use its own native
  subagents). Both dispatchers pass the resolved CLI name through. (Codex does have its
  own subagents + `AGENTS.md`; wiring Codex-native custom agents is a separate, optional
  follow-up.)

## [0.2.4] — 2026-06-13

### Added
- **Spec-driven dispatch with two explicit work types.** Every brief now opens with a
  `## 0. Work type` section: **NEW FEATURE** (build to the spec — the source of truth) or
  **ITERATION** (change existing code; the spec is context/reference, the existing code is
  the baseline; do not rebuild). Both dispatchers (`psmux-dispatch.ps1`, `dispatch-codex.ps1`)
  take `-Spec <repo-relative path>` and `-Mode feature|iteration` and flow them into
  `New-WorkerBrief`. Mode defaults to `iteration` when `-IssueNumber` is set, else `feature`.
  The dispatcher warns if the spec path is not found. This wires a project's existing
  `specs/` tree into the worker bootstrap so workers always get the authoritative context.

## [0.2.3] — 2026-06-13

### Added
- **Headless `codex exec` build-ahead lane (`dispatch/dispatch-codex.ps1`).** Provisions
  a worktree then runs Codex to a green PR in the **background** — no psmux pane, no boot
  handshake (sidesteps the interactive-REPL startup fragility). Uses the verified flags
  `--dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --json`, feeds the
  brief on stdin, captures the final message via `-o`, and logs the JSONL stream to
  `<worktreesPath>\.orchestrator\logs\<name>.{jsonl,log}`. Fan out N to fill a verify
  queue. `-Wait` blocks + prints the result. Codex command resolves via `-CodexCmd`,
  `config.codexCmdPath`, or `codex` on `PATH`.
- **Headless-worker monitor (`status/check-headless-workers.ps1`).** Headless Codex
  workers are background processes, not psmux windows, so `capture-pane` can't see them.
  This reads the per-worker meta files dispatch-codex drops and reports each one's state
  (RUNNING/COMPLETE/BLOCKED/EXITED) + PR URL, so `orchestrate poll` folds them into its
  dashboard and self-terminate check. `-Json` for machine consumption. dispatch-codex now
  writes `<name>.meta.json` (pid + log paths) for it.

### Changed
- **Worktree provisioning extracted to `Initialize-WorkerWorktree`** (in
  `lib/_session-config.ps1`) — the single source of truth for worktree create/reuse, env
  + `.mcp.json` copy, brief write, and `node_modules` junctioning. Both the interactive
  (`psmux-dispatch.ps1`) and headless (`dispatch-codex.ps1`) dispatchers call it, so they
  can no longer drift (the `.mcp.json` copy living in only one path was the cautionary
  case). New `Get-CodexCmd` helper resolves the Codex command.

## [0.2.2] — 2026-06-13

### Added
- **Verified `codex` worker-CLI preset.** Captured from a live boot of the OpenAI
  Codex CLI in a psmux pane: launches `--dangerously-bypass-approvals-and-sandbox
  --no-alt-screen` (`--no-alt-screen` is required so the inline TUI is visible to
  `capture-pane`), auto-answers Codex's per-directory trust gate with `1`, and detects
  readiness from the `permissions: YOLO mode` / `>_ OpenAI Codex` header. Use with
  `"workerCli": "codex"` + `workerCmdPath` → `codex.cmd`. README, session-init, and
  Pester coverage updated.
- **Project `.mcp.json` passthrough to worktrees.** `psmux-dispatch.ps1` now copies the
  project's (usually untracked) `.mcp.json` into each fresh worktree so workers inherit
  the project's MCP servers. stdio servers (shadcn, playwright, …) work immediately;
  HTTP/OAuth servers still need headless auth.

## [0.2.0] — 2026-05-30

### Added
- **Data-driven worker-CLI profiles** (#1). The worker launch + boot handshake are
  no longer hardcoded to Claude — they're resolved from an optional `workerCli`
  config (a preset string or an override object) by `Get-WorkerCliProfile`.
  `psmux-dispatch.ps1` drives `clearEnv` → launch (`cmd` + `args`) → accept/ready
  capture-pane handshake (or a fixed `bootWaitSec`) entirely from the profile.
  - Shipped presets: **`claude`** (verified; the previous behavior, and the default
    when `workerCli` is omitted) and **`generic`** (fixed-wait, no accept handshake).
  - Other CLIs (Codex/Gemini/Qwen) are wired via a `workerCli` object supplying their
    real `args` / `clearEnv` / `accept` / `ready` patterns — no unverified prompt
    strings are shipped. Orchestrator + headless dispatch remain Claude.
  - Pester coverage for profile resolution (now 50 tests).

## [0.1.0] — 2026-05-29

Initial release. A faithful, project-agnostic port of the proven per-project
parallel-worktree build pipeline into a distributable Claude Code plugin.

### Added
- **`session` skill** — full worktree lifecycle + orchestration: `list`, `start`,
  `start-issues`, `resume`, `finish`, `pull`, `cleanup`, `monitor`,
  `server-start/check/stop`, and `orchestrate [dashboard|dispatch|poll|verify|verify-all|pull|cleanup]`.
- **`session-init` skill** — interactive scaffold that detects defaults and writes
  `.claude/session-plugin.json` for the consuming project.
- **Config-driven everything** via `.claude/session-plugin.json`. A shared loader
  (`scripts/lib/_session-config.ps1`) resolves config from `-Config`, `-RepoPath`,
  or by walking up from cwd, and exposes path/layout/team helpers. Supports two
  layouts: `root` and `monorepo-split`.
- **Brief generator** (`scripts/lib/_session-brief.ps1`) that synthesizes each
  worker's `.claude-bootstrap.md`, injecting the project's `teams` agent / file-lane
  rules (or a single-Claude fallback when no teams are declared).
- **Dispatch scripts** (`scripts/dispatch/`): `psmux-dispatch.ps1` (boot-handshake
  worktree dispatch), `psmux-dispatch-issues.ps1` (bulk from GitHub issues),
  `start-orchestrator.ps1` (detached orchestrator worktree + no-auto-merge +
  batch-scoped brief + `/loop`), `dispatch-worktree.ps1` (headless variant).
- **Teardown scripts** (`scripts/teardown/`): `close-worker.ps1` (junction-first),
  `cleanup-worktrees.ps1`, `nuke-worktrees.ps1`, `kill-worktree-agents.ps1`.
- **Server / status / util scripts** (`scripts/server/`, `scripts/status/`,
  `scripts/util/`): `dev-server.ps1`, `check-worktree-health.ps1`, optional status
  hooks (`orchestrator-hook.sh`, `install-worktree-hooks.sh`, `poll-worktrees.sh`,
  `poll-format.js`), `kill-port.ps1`, `force-remove-dir.ps1`.
- **Reference docs** mirroring the source skill, parametrized: `build-protocol.md`,
  `commands-orchestrate.md` (no-auto-merge + batch-scoping contracts), `commands-core.md`,
  `commands-monitor.md`, `commands-pull.md`, `commands-server.md`, `commands-cleanup.md`,
  `server-rules.md`.
- **Example configs** for `monorepo-split` and `root` layouts.
- **Pester tests** for config resolution, slug derivation, env/node-module mapping,
  and brief generation.

### Preserved (hard-won behaviors)
- No auto-merge; orchestrator confined to its own worktree.
- Batch scoping via the active-worktree filter.
- Junction-first teardown (detach `node_modules` junction before `git worktree remove`).
- `CLAUDECODE` cleared in panes so workers can spawn their agent team.
- Boot handshake (accept-screen → option 2 → "bypass permissions on" footer) before sending the brief.
- Bare-path Claude launch + standalone Enter; brief via `.claude-bootstrap.md`.
- Self-terminate; `/loop` as the polling mechanism (no Windows cron / sleep loops).

### Designed for (Phase 2)
- Worker spawn is a single indirection point so a future **Claude Teams** primitive
  can replace `claude.cmd` launch without changing the worktree/psmux/brief scaffold
  or the orchestrator's pane-I/O polling.

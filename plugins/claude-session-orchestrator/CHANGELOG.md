# Changelog

All notable changes to `claude-session-orchestrator` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

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

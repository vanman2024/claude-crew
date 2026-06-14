# Changelog

All notable changes to `claude-session-orchestrator` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

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

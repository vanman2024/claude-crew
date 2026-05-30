# Changelog

All notable changes to `claude-session-orchestrator` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

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

# Tests

Pester v5 unit tests for the shared library that every orchestrator script
dot-sources (`scripts/lib/_session-config.ps1`, `scripts/lib/_session-brief.ps1`).

## Running

From this `tests/` directory:

```powershell
Invoke-Pester -Path .
```

Requires **Pester v5+**. Install/upgrade with:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

The tests derive the library path from `$PSScriptRoot` (`..\scripts\lib\...`),
build fake projects under the system temp dir, and clean up after themselves, so
they are self-contained and run on any machine (no hardcoded user paths).

## What each file covers

- **config-resolution.Tests.ps1** — `Find-SessionConfigPath` (explicit `-Config`,
  `-RepoPath`, and walk-up-from-`-Start` discovery, plus the not-found throws),
  `Get-SessionConfig` (successful parse + `_configPath`, and each validation
  failure: missing required field, missing `layout.type`, bad `layout.type`,
  invalid JSON), and the derived helpers `Get-EnvFileMappings`,
  `Get-NodeModuleMappings`, `Get-TestCommands` (including `<repo>` substitution),
  `Get-WorktreePath`, and `Get-PsmuxTarget` for both `root` and `monorepo-split`
  layouts using the example configs in `../examples`.
- **slug.Tests.ps1** — `ConvertTo-SessionSlug`: lowercasing, non-alphanumeric
  collapse to a single hyphen, leading/trailing trim, max-length truncation with
  no trailing hyphen, and the `"task"` fallback for symbol/whitespace-only input.
- **brief-generation.Tests.ps1** — `Format-TeamsSection` (agent/team/path/skill
  rendering plus the "never `general-purpose`" and "BLOCKED: <agent> unavailable"
  rules when teams are present, and the single-Claude fallback when teams are
  absent or null) and `New-WorkerBrief` (branch, task text, test commands,
  `WORKTREE_STATUS: COMPLETE`/`BLOCKED` sentinels, and the `Closes #N` line
  driven by `-IssueNumber`).

## Out of scope (manual verification)

Full end-to-end dispatch — psmux session/window creation, `git worktree` setup,
env-file copying, `node_modules` junctions, and the actual Claude launch — has
live side effects and is validated manually against a real project rather than in
these unit tests.

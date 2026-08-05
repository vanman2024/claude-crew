# protocol.ps1
#
# Emit the BUILD PROTOCOL for the current session to stdout.
#
# Same protocol a dispatched worker gets in .claude-bootstrap.md — size classes,
# lane roster, data-flow map, test commands, browser verification — but WITHOUT the
# worktree/branch/dispatch parts, because there is no worktree here. The caller is
# already sitting in the repo.
#
# This exists so the protocol is not coupled to the delivery mechanism: worktrees are
# for isolation and parallelism, the protocol is the actual value, and it should apply
# whether you dispatched a worker or are building the feature yourself.
#
# Usage (from the project, or pass -Config):
#   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/build/protocol.ps1"
#   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/build/protocol.ps1" -Task "add X" -Config <path>

param(
    [string]$Task,
    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
. (Join-Path $PSScriptRoot "..\lib\_session-brief.ps1")

$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath
$taskTool = Get-TaskToolName -WorkerCli 'claude'

$out = New-Object System.Text.StringBuilder
function W($s) { [void]$out.AppendLine($s) }

W "# Build protocol — $($cfg.projectName)"
W ""
if ($Task) { W "**Task:** $Task"; W "" }
W "You are building in the MAIN checkout, not a worktree. Everything below applies exactly"
W "as it would to a dispatched worker, except: no branch/worktree ceremony, and the dev"
W "server uses this project's CONFIGURED port (not ``-AutoPort``, which is for worktrees)."
W ""
W "**Create your task list with $taskTool as your FIRST action**, before exploring or"
W "writing code — seeded from the REQUIRED items at your size class below."
W ""
W (Format-TeamsSection -Config $cfg -WorkerCli 'claude')
W ""
W (Format-DataFlowSection -Config $cfg)
W ""
W "## Test before you call it done"
W ""
W (Format-TestSection -Config $cfg)
W ""
W (Format-BrowserVerifySection -Config $cfg)
W ""
W (Format-DocsSection -Config $cfg)
W ""
W "## When you finish"
W ""
W "Report what you did in this shape, then STOP and let the human decide what lands:"
W ""
W '```'
W "LANES:            <which lanes you actually ran>"
W "REQUIRED_SKIPPED: <none | each REQUIRED item at your size you did NOT run + why>"
W "SIZE:             <S | M | L + one line of reasoning>"
W "TESTS:            <what you ran and the result>"
W "OBSERVED:         <what you SAW when you ran it, or 'n/a: not user-visible'>"
W '```'

Write-Output $out.ToString()

# check-crew-health.ps1
#
# The conductor's watchdog: is every terminal of this crew build up and doing its job?
# The orchestrator steers workers; this checks the orchestrator, the reviewer and the
# workers themselves are still there to be steered.
#
# One row per expected window:
#   orchestrator, reviewer - always expected while a build is running
#   one per worker worktree - every active worktree under worktreesPath, minus the
#                             infra ones (orchestrator, reviewer, review-checkout)
# State:
#   missing  - no psmux window (never launched, killed, or the psmux server died)
#   exited   - the window is there but its CLI has quit (bare shell prompt)
#   pending  - text typed into the CLI's input box and never sent; blocks the loop
#   running  - the CLI is up. Whether it is PROGRESSING needs two checks: compare
#              PaneHash with the previous run (unchanged across the loop interval = stalled)
#
# Usage:
#   check-crew-health.ps1 -Config <repo>\.claude\session-plugin.json [-Json]

param(
    [string]$Config,
    [string]$RepoPath,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg  = Get-SessionConfig -Config $Config -RepoPath $RepoPath
$sess = $cfg.psmuxSession
$infra = @("orchestrator", "reviewer", "review-checkout")

# Expected worker names = active worktrees under worktreesPath (their dir leaf).
$wtBase = [IO.Path]::GetFullPath($cfg.worktreesPath).TrimEnd('\')
$workers = @()
foreach ($line in (git -C $cfg.repoPath worktree list --porcelain 2>$null)) {
    if ($line -match '^worktree (.+)$') {
        $p = [IO.Path]::GetFullPath(($Matches[1] -replace '/', '\')).TrimEnd('\')
        if ($p.StartsWith("$wtBase\", [StringComparison]::OrdinalIgnoreCase)) {
            $leaf = Split-Path $p -Leaf
            if ($leaf -notin $infra) { $workers += $leaf }
        }
    }
}

$sessionAlive = [bool](psmux ls 2>$null | Select-String -SimpleMatch "${sess}:")
$windows = if ($sessionAlive) { @(psmux list-windows -t $sess -F '#{window_name}' 2>$null) } else { @() }

$expected = @(
    @{ Name = "orchestrator"; Role = "orchestrator" },
    @{ Name = "reviewer";     Role = "reviewer" }
) + @($workers | ForEach-Object { @{ Name = $_; Role = "worker" } })

$sha = [Security.Cryptography.SHA1]::Create()
$rows = foreach ($e in $expected) {
    if ($e.Name -notin $windows) {
        [pscustomobject]@{ Name = $e.Name; Role = $e.Role; State = "missing"; Detail = "no psmux window"; PaneHash = ""; Tail = "" }
        continue
    }
    $lines = @(psmux capture-pane -t "${sess}:$($e.Name)" -p -S -60 2>$null)
    $verdict = Get-PaneState -Lines $lines
    $text = ($lines -join "`n")
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace("-", "").Substring(0, 12)
    $tail = (@($lines | Where-Object { $_ -and $_.Trim() }) | Select-Object -Last 3) -join " | "
    [pscustomobject]@{ Name = $e.Name; Role = $e.Role; State = $verdict.State; Detail = $verdict.Detail; PaneHash = $hash; Tail = $tail }
}

# Windows nobody expects (e.g. a worker whose worktree was removed) are reported too.
$known = @($expected | ForEach-Object { $_.Name }) + @("pwsh")
$orphans = @($windows | Where-Object { $_ -notin $known })

if ($Json) {
    [pscustomobject]@{ session = $sess; sessionAlive = $sessionAlive; rows = @($rows); orphanWindows = $orphans } | ConvertTo-Json -Depth 4
} else {
    Write-Host "psmux session '$sess': $(if ($sessionAlive) { 'alive' } else { 'NOT RUNNING' })"
    $rows | Format-Table Name, Role, State, Detail, PaneHash -AutoSize | Out-String -Width 200 | Write-Host
    if ($orphans.Count) { Write-Host "Windows with no worktree: $($orphans -join ', ')" }
}

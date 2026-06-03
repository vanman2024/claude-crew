# kill-worktree-agents.ps1
#
# Kill Claude agent processes running inside worker worktree directories
# (never the main checkout). Targeted, lighter-weight cousin of nuke-worktrees:
# it stops the agents holding handles open so worktrees can be removed cleanly.
#
# It first looks for claude.exe (falling back to node.exe whose command line
# mentions both 'claude' and 'worktree'), then kills cmd.exe processes whose
# command line references the project's worktrees path. If nothing matches, it
# reminds you that terminal tabs may need closing by hand.
#
# Project-agnostic: paths come from session-plugin.json. The worktrees path is
# used as the literal substring matched against process command lines.
#
# Usage:
#   kill-worktree-agents.ps1
#   kill-worktree-agents.ps1 -Config C:\proj\.claude\session-plugin.json
#   kill-worktree-agents.ps1 -RepoPath C:\proj

param(
    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

# Kill Claude processes running in worktree directories (not the main one)
$worktreeBase = $cfg.worktreesPath
$mainDir = $cfg.repoPath

$procs = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue
if (-not $procs) {
    # Try node.exe with claude in command line
    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*claude*" -and $_.CommandLine -like "*worktree*" }
}

# Also kill cmd.exe processes whose working directory is in worktrees
$cmdProcs = Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$($cfg.worktreesPath)*" }

$killed = 0
foreach ($p in $cmdProcs) {
    Write-Host "Killing cmd.exe PID $($p.ProcessId): $($p.CommandLine.Substring(0, [Math]::Min(100, $p.CommandLine.Length)))"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    $killed++
}

if ($killed -eq 0) {
    Write-Host "No worktree cmd.exe processes found. You may need to close the terminal tabs manually."
    Write-Host "Look for tabs named 'Claude Code' or worktree names in Windows Terminal."
}

Write-Host "`nKilled $killed processes."


# close-worker.ps1
#
# Tear down a worker after its PR has been merged (or any time you want to
# safely remove a worker worktree + its psmux window).
#
# JUNCTION-FIRST teardown is non-negotiable on Windows. `git worktree remove`
# rm-rf's the worktree dir and FOLLOWS the node_modules junction into the MAIN
# repo, deleting files in the main checkout's node_modules (a session was burned
# re-installing after this in May 2026).
#
# Correct order, for EACH node_modules mapping from config.layout:
#   1. cmd /c rmdir on the junction (removes the LINK only, never recurses).
# Then:
#   2. psmux kill-window (so no process holds files open).
#   3. git worktree remove --force (pwsh Remove-Item fallback).
#   4. git worktree prune.
#
# Project-agnostic: paths/session come from session-plugin.json.
#
# Usage:
#   close-worker.ps1 -Name fix-399-foo
#   close-worker.ps1 -Name fix-510-bar -Config C:\proj\.claude\session-plugin.json
#
# Idempotent: missing junction / window / worktree are skipped with a note.

param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [string]$Config,
    [string]$RepoPath,
    [string]$Session
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

if (-not $Session) { $Session = $cfg.psmuxSession }
$MainRepo = $cfg.repoPath
$WtPath   = Join-Path $cfg.worktreesPath $Name

# Refuse to nuke the orchestrator worktree via this script.
if ($Name -ieq "orchestrator") {
    Write-Error "Refusing to close the orchestrator worktree via close-worker. Use 'psmux kill-window -t ${Session}:orchestrator' + manual cleanup if you really mean to."
    exit 1
}

Write-Host "[close-worker] Closing worker '$Name'"
Write-Host "[close-worker]   worktree: $WtPath"
Write-Host ""

# 1. Detach EVERY node_modules junction FIRST (link only, main checkout untouched).
foreach ($rel in (Get-NodeModuleMappings -Config $cfg)) {
    $junction = Join-Path $WtPath $rel
    if (Test-Path $junction) {
        $item = Get-Item $junction -Force
        $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($isReparse) {
            Write-Host "[close-worker] Detaching '$rel' junction (link only, main checkout untouched)"
            cmd /c rmdir $junction
        } else {
            Write-Warning "[close-worker] $junction is a REAL directory, not a junction. Refusing to remove (would destroy real files). Investigate manually."
            exit 1
        }
    } else {
        Write-Host "[close-worker] No '$rel' junction to detach (already gone or never created)"
    }
}

# 2. Kill the psmux window if it exists.
$windowMatch = (psmux list-windows -t $Session 2>$null | Select-String -SimpleMatch $Name)
if ($windowMatch) {
    Write-Host "[close-worker] Killing psmux window ${Session}:${Name}"
    psmux kill-window -t "${Session}:${Name}" 2>&1 | Out-Null
} else {
    Write-Host "[close-worker] No psmux window to kill"
}

# 3. Remove the worktree (junctions detached, safe).
if (Test-Path $WtPath) {
    Write-Host "[close-worker] git worktree remove --force $WtPath"
    git -C $MainRepo worktree remove --force $WtPath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Test-Path $WtPath)) {
        Write-Warning "[close-worker] git worktree remove left files behind; falling back to pwsh Remove-Item -Recurse -Force"
        try { Remove-Item -Recurse -Force $WtPath -ErrorAction Stop }
        catch { Write-Warning "[close-worker] Remove-Item also failed: $($_.Exception.Message)" }
    }
} else {
    Write-Host "[close-worker] Worktree dir already gone"
}

# 4. Prune stale worktree refs.
Write-Host "[close-worker] git worktree prune"
git -C $MainRepo worktree prune 2>&1 | Out-Null

Write-Host ""
Write-Host "[close-worker] Done. Worker '$Name' closed." -ForegroundColor Green
Write-Host "Note: the local branch ref persists. Run 'git -C $MainRepo branch -D <branch>' to remove it, or let 'git fetch --prune' clean it up."


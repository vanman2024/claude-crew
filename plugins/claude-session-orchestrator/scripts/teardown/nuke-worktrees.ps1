# nuke-worktrees.ps1
#
# Aggressive, last-resort teardown of EVERY worktree under the project's
# worktrees path. Use when cleanup-worktrees leaves dirs STUCK because
# processes still hold handles open inside them.
#
# Phases:
#   1. Kill every process whose command line references the worktrees path
#      (cmd.exe, node.exe, claude.exe explicitly, then a broad sweep), so no
#      handles remain. The orchestrator's own pwsh (this $PID) and any
#      powershell.exe are spared.
#   2. git worktree prune FIRST (before dir deletes) so refs settle.
#   3. Per-dir multi-attempt delete:
#        a. straight Remove-Item -Recurse -Force.
#        b. robocopy-mirror an empty dir over it (clears locked files), delete.
#        c. rename out of the way (_del_<random>) then delete the renamed dir.
#      Survivors are reported.
#
# Project-agnostic: paths come from session-plugin.json. The worktrees path is
# used as the literal substring matched against process command lines.
#
# Usage:
#   nuke-worktrees.ps1
#   nuke-worktrees.ps1 -Config C:\proj\.claude\session-plugin.json
#   nuke-worktrees.ps1 -RepoPath C:\proj

param(
    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

$base = $cfg.worktreesPath
$mainRepo = $cfg.repoPath

# ── Phase 1: Kill ALL processes with handles in worktree dirs ──────────────────
Write-Host "Phase 1: Killing processes in worktree directories..."

# Kill cmd.exe processes launched into worktree dirs
$cmds = Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$($cfg.worktreesPath)*" }
foreach ($p in $cmds) {
    Write-Host "  Kill cmd.exe PID $($p.ProcessId)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}

# Kill node.exe processes running in worktree dirs (next dev servers, etc)
$nodes = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$($cfg.worktreesPath)*" }
foreach ($p in $nodes) {
    Write-Host "  Kill node.exe PID $($p.ProcessId)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}

# Kill claude.exe processes in worktree dirs
$claudes = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$($cfg.worktreesPath)*" }
foreach ($p in $claudes) {
    Write-Host "  Kill claude.exe PID $($p.ProcessId)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}

# Broader sweep: any process whose command line references a worktree path
$all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -like "*$($cfg.worktreesPath)*" -and
        $_.ProcessId -ne $PID -and
        $_.Name -ne "powershell.exe"
    }
foreach ($p in $all) {
    Write-Host "  Kill $($p.Name) PID $($p.ProcessId)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}

# Brief pause for handles to release
Start-Sleep -Milliseconds 500

# ── Phase 2: Prune git worktree references first ──────────────────────────────
Set-Location $mainRepo
git worktree prune 2>&1 | Out-Null

# ── Phase 3: Delete directories ───────────────────────────────────────────────
Write-Host "`nPhase 2: Removing directories..."
$empty = Join-Path $env:TEMP "empty_dir_cleanup"
New-Item -ItemType Directory -Path $empty -Force | Out-Null

$dirs = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue
foreach ($d in $dirs) {
    Write-Host "  $($d.Name)..."

    # Attempt 1: straight delete
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $d.FullName)) { Write-Host "    OK"; continue }

    # Attempt 2: robocopy mirror empty dir (clears locked files), then delete
    robocopy $empty $d.FullName /MIR /R:1 /W:0 /NFL /NDL /NJH /NJS 2>&1 | Out-Null
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $d.FullName)) { Write-Host "    OK (robocopy)"; continue }

    # Attempt 3: rename out of the way, then delete renamed
    $temp = Join-Path $base ("_del_" + (Get-Random))
    try {
        Rename-Item $d.FullName $temp -Force -ErrorAction Stop
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $temp)) {
            Write-Host "    OK (rename+delete)"
        } else {
            # Schedule for delete on reboot as last resort
            Write-Host "    PARTIAL (renamed to $temp, will retry)"
        }
    } catch {
        Write-Host "    STUCK (rename failed: $_)"
    }
}

Remove-Item $empty -Force -ErrorAction SilentlyContinue

# ── Phase 4: Final report ─────────────────────────────────────────────────────
$remaining = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue
if ($remaining) {
    Write-Host "`nREMAINING:"
    $remaining | ForEach-Object { Write-Host "  $($_.Name)" }
} else {
    Write-Host "`nAll clean."
}


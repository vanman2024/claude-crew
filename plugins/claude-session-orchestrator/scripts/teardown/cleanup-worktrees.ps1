# cleanup-worktrees.ps1
#
# Remove ALL worker worktree directories under the project's worktrees path,
# then prune stale git worktree references.
#
# Per-directory Windows cleanup: straight Remove-Item, and if the dir is stuck
# (open handle / locked file), a rename-and-delete fallback that breaks the
# handle association before deleting the renamed copy.
#
# git worktree prune runs AFTER the directory deletions so stale refs whose
# backing dirs are now gone get cleaned up in one pass.
#
# Project-agnostic: paths come from session-plugin.json.
#
# Usage:
#   cleanup-worktrees.ps1
#   cleanup-worktrees.ps1 -Config C:\proj\.claude\session-plugin.json
#   cleanup-worktrees.ps1 -RepoPath C:\proj

param(
    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

$base = $cfg.worktreesPath
$dirs = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue

foreach ($d in $dirs) {
    Write-Host "Removing $($d.Name)..."
    Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $d.FullName) {
        $temp = Join-Path $base ("_del_" + $d.Name)
        Rename-Item $d.FullName $temp -ErrorAction SilentlyContinue
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $temp) {
            Write-Host "  STUCK: $($d.Name) (close terminal tab first)"
        } else {
            Write-Host "  OK (rename+delete)"
        }
    } else {
        Write-Host "  OK"
    }
}

# Prune git worktree references
Set-Location $cfg.repoPath
git worktree prune 2>&1 | Out-Null

Write-Host ""
$remaining = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue
if ($remaining) {
    Write-Host "REMAINING:"
    $remaining | ForEach-Object { Write-Host "  $($_.Name)" }
} else {
    Write-Host "All clean."
}


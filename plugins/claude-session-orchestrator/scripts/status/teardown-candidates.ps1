# teardown-candidates.ps1
#
# REPORT ONLY. Says which worker worktrees are safe to close, and why the rest are not.
# It never removes anything — closing is a human decision (and `close-worker.ps1` is the
# thing that does it). Run it any time the worktrees dir feels heavy.
#
# Classification mirrors Claude Code's own worktree sweep: a worktree is only a candidate
# when it holds NO WORK. Work means any of uncommitted changes, untracked files, or
# unpushed commits — plus, here, an open PR or a live psmux window, because in this system
# either of those means someone is still using it.
#
#   SAFE   - PR merged (or branch gone from the remote), clean tree, nothing unpushed,
#            no live psmux window. Closing loses nothing.
#   HOLD   - has work, or its PR is still open. Reason is printed.
#   ACTIVE - a psmux window is still running for it. Never a candidate.
#
# Usage:
#   teardown-candidates.ps1
#   teardown-candidates.ps1 -Config C:\proj\.claude\session-plugin.json -ShowSize

param(
    [string]$Config,
    [string]$RepoPath,
    [string]$Session,
    # Disk usage is a recursive scan over ~137k files per node_modules — slow enough to
    # be opt-in rather than something every run pays for.
    [switch]$ShowSize
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

if (-not $Session) { $Session = $cfg.psmuxSession }
$MainRepo = $cfg.repoPath
$WtBase   = $cfg.worktreesPath

# Worktrees the orchestrator itself lives in are infrastructure, not workers.
$Reserved = @('orchestrator', 'reviewer', 'docs')

# --- live psmux windows -------------------------------------------------------
$liveWindows = @()
try {
    $wins = psmux list-windows -t $Session 2>$null
    foreach ($line in $wins) {
        # psmux prints e.g. "1: fix-843-foo* (1 panes) [120x30]"
        if ("$line" -match '^\s*\d+:\s*([^\s*]+)') { $liveWindows += $Matches[1] }
    }
} catch { }

# --- registered worktrees -----------------------------------------------------
$registered = @()
foreach ($line in (git -C $MainRepo worktree list --porcelain 2>$null)) {
    if ("$line" -match '^worktree\s+(.+)$') { $registered += ($Matches[1] -replace '/', '\') }
}

$rows = @()
foreach ($wt in $registered) {
    $name = Split-Path $wt -Leaf
    if ($wt -ieq ($MainRepo -replace '/', '\')) { continue }       # the main checkout
    if ($wt -notlike "$WtBase*") { continue }                      # not one of ours
    if ($Reserved -contains $name.ToLower()) { continue }

    $branch = (git -C $wt rev-parse --abbrev-ref HEAD 2>$null)
    $reasons = @()

    # --- does it hold work? (the native sweep's test) ---
    $porcelain = @(git -C $wt status --porcelain 2>$null)
    $dirty = ($porcelain.Count -gt 0)
    if ($dirty) { $reasons += "$($porcelain.Count) uncommitted/untracked file(s)" }

    # Unpushed commits. No upstream at all also counts as unpushed - the work exists
    # only here, so removing the worktree destroys it.
    $hasUpstream = $null -ne (git -C $wt rev-parse --abbrev-ref '@{u}' 2>$null)
    if ($hasUpstream) {
        $ahead = (git -C $wt rev-list --count '@{u}..HEAD' 2>$null)
        if ($ahead -and [int]$ahead -gt 0) { $reasons += "$ahead unpushed commit(s)" }
    } else {
        $anyCommits = (git -C $wt rev-list --count "origin/$($cfg.defaultBranch)..HEAD" 2>$null)
        if ($anyCommits -and [int]$anyCommits -gt 0) { $reasons += "$anyCommits commit(s), never pushed" }
    }

    # --- PR state ---
    $pr = ''
    if ($branch) {
        $json = gh pr list --repo $cfg.githubRepo --head $branch --state all --json number,state --limit 1 2>$null
        if ($json) {
            try {
                $parsed = $json | ConvertFrom-Json
                if ($parsed -and @($parsed).Count -gt 0) {
                    $p = @($parsed)[0]
                    $pr = "#$($p.number) $($p.state)"
                    if ($p.state -ne 'MERGED' -and $p.state -ne 'CLOSED') { $reasons += "PR #$($p.number) still $($p.state)" }
                }
            } catch { }
        }
        if (-not $pr) { $reasons += "no PR found for '$branch'" }
    }

    # --- live window? ---
    $active = $liveWindows -contains $name

    $status = if ($active) { 'ACTIVE' } elseif ($reasons.Count -gt 0) { 'HOLD' } else { 'SAFE' }

    $size = ''
    if ($ShowSize) {
        $m = Get-ChildItem $wt -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        $size = "{0:N1} GB" -f ($m.Sum / 1GB)
    }

    $rows += [pscustomobject]@{
        Status = $status; Name = $name; Branch = $branch; PR = $pr; Size = $size
        Reason = ($reasons -join '; ')
    }
}

# --- report -------------------------------------------------------------------
Write-Host ""
Write-Host "TEARDOWN CANDIDATES - $($cfg.projectName)" -ForegroundColor Cyan
Write-Host ("=" * 60)

if ($rows.Count -eq 0) { Write-Host "No worker worktrees found under $WtBase."; return }

# Grouped lines rather than a table: worktree names and reasons are both long, and a
# table squeezes the Reason column down to "1 ." which is the one thing you need to read.
$order = @{ 'SAFE' = 0; 'HOLD' = 1; 'ACTIVE' = 2 }
$colour = @{ 'SAFE' = 'Green'; 'HOLD' = 'Yellow'; 'ACTIVE' = 'Cyan' }
$blurb = @{
    'SAFE'   = 'closing loses nothing'
    'HOLD'   = 'still holds work, or its PR is open'
    'ACTIVE' = 'a psmux window is running - leave alone'
}

foreach ($status in ($rows.Status | Select-Object -Unique | Sort-Object { $order[$_] })) {
    $group = @($rows | Where-Object { $_.Status -eq $status } | Sort-Object Name)
    Write-Host ""
    Write-Host "$status ($($group.Count)) - $($blurb[$status])" -ForegroundColor $colour[$status]
    foreach ($r in $group) {
        $tail = @($r.PR, $r.Size) | Where-Object { $_ }
        Write-Host ("  {0}" -f $r.Name)
        Write-Host ("      {0}{1}" -f $r.Branch, $(if ($tail) { "   [$($tail -join ' | ')]" } else { '' })) -ForegroundColor DarkGray
        if ($r.Reason) { Write-Host ("      -> {0}" -f $r.Reason) -ForegroundColor DarkYellow }
    }
}

Write-Host ""
$closeScript = (Resolve-Path (Join-Path $PSScriptRoot "..\teardown\close-worker.ps1")).Path
$safe = @($rows | Where-Object { $_.Status -eq 'SAFE' })
if ($safe.Count -eq 0) {
    Write-Host "Nothing is safe to close right now." -ForegroundColor Yellow
} else {
    Write-Host "$($safe.Count) safe to close - each is junction-first and reversible (branches are merged and pushed):" -ForegroundColor Green
    Write-Host ""
    foreach ($r in $safe) {
        Write-Host "  pwsh -NoProfile -File `"$closeScript`" -Name `"$($r.Name)`" -Config `"$($cfg._configPath)`""
    }
}
Write-Host ""
Write-Host "This script never removes anything. Closing is your call." -ForegroundColor DarkGray

# restore-session.ps1
#
# Recover a worktree crew after the psmux SERVER dies (power surge, reboot, crash).
# `psmux attach` only works while the server is alive; after a full shutdown the
# server — and every worker process + dev server — is gone, but the git worktrees
# on disk survive. This rebuilds the psmux session + a window per worktree and
# RESUMES each worker's prior conversation (claude --continue / codex resume --last)
# so work picks up where it stopped instead of starting cold.
#
# Two cases, handled automatically:
#   - psmux session STILL ALIVE (you only closed the terminal) -> nothing to rebuild;
#     it just prints the attach command.
#   - psmux session GONE -> discover worktrees and re-dispatch each in -Continue mode.
#
# Project-agnostic: paths/session come from .claude/session-plugin.json.
#
# Usage:
#   restore-session.ps1
#   restore-session.ps1 -Config C:\proj\.claude\session-plugin.json
#   restore-session.ps1 -Name f036-international   # restore just one worktree
#   restore-session.ps1 -Idle                      # rebuild + resume but DON'T nudge

param(
    [string]$Config,
    [string]$RepoPath,
    [string]$Session,
    [string]$Name,     # restore only this worktree (default: all under worktreesPath)
    [switch]$Idle      # recreate + resume the conversation but send no "keep going" nudge
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")

$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath
if (-not $Session) { $Session = $cfg.psmuxSession }
$RepoRoot = $cfg.repoPath
$WtBase   = $cfg.worktreesPath
$dispatch = Join-Path $PSScriptRoot "psmux-dispatch.ps1"

function Step($m) { Write-Host "[restore] $m" }

if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) {
    Write-Error "psmux not found on PATH. Install/confirm psmux before restoring."; exit 1
}

# --- 1. If the psmux session is still alive, there is nothing to rebuild ----------
$alive = (psmux ls 2>$null | Select-String -SimpleMatch $Session)
if ($alive) {
    Step "psmux session '$Session' is ALIVE - server survived, no rebuild needed."
    Step "Windows:"
    psmux list-windows -t $Session 2>$null | ForEach-Object { Write-Host "  $_" }
    Write-Host "SESSION_ALIVE=$Session"
    Write-Host "Attach with: psmux attach -t $Session"
    exit 0
}
Step "psmux session '$Session' is GONE - rebuilding from the worktrees on disk."

# --- 2. Discover worktrees under worktreesPath (skip main checkout + _preview) ----
$baseFull = try { (Resolve-Path $WtBase -ErrorAction Stop).Path } catch { $WtBase }
$wtNames = @()
$porc = (git -C $RepoRoot worktree list --porcelain 2>$null) -join "`n"
foreach ($line in ($porc -split "`n")) {
    if ($line -like "worktree *") {
        $p = $line.Substring(9).Trim()                      # after "worktree "
        $full = try { (Resolve-Path $p -ErrorAction Stop).Path } catch { $p }
        if ($full -like "$baseFull*") {
            $leaf = Split-Path $full -Leaf
            if ($leaf -ne '_preview') { $wtNames += $leaf }  # _preview is the review env, not a worker
        }
    }
}
$wtNames = @($wtNames | Select-Object -Unique)
if ($Name) { $wtNames = @($wtNames | Where-Object { $_ -eq $Name }) }

if ($wtNames.Count -eq 0) {
    Step "No worker worktrees found under $WtBase to restore."
    Write-Host "RESTORED=0"
    exit 0
}
Step "Worktrees to restore: $($wtNames -join ', ')"

# --- 3. Re-dispatch each in -Continue mode ---------------------------------------
# psmux-dispatch -Continue ensures the session + window, relaunches the worker with
# its resume flag (claude --continue / codex resume --last), and nudges it to keep
# going. We do this BEFORE any fresh dispatch so the resumed (pre-crash) session is
# the most-recent one its CLI picks up.
$restored = 0
foreach ($n in $wtNames) {
    Step "Restoring '$n'..."
    $dispatchArgs = @('-NoProfile', '-File', $dispatch, '-Name', $n, '-Continue', '-Config', $cfg._configPath, '-Session', $Session)
    if ($Idle) { $dispatchArgs += '-NoNudge' }
    pwsh @dispatchArgs
    if ($LASTEXITCODE -eq 0) { $restored++ } else { Step "WARN: restore of '$n' failed (exit $LASTEXITCODE)" }
}

Write-Host "RESTORED=$restored of $($wtNames.Count)"
Write-Host "SESSION=$Session"
Write-Host "Attach with: psmux attach -t $Session"

# check-headless-workers.ps1
#
# Monitor for the HEADLESS build-ahead lane (dispatch-codex.ps1). Headless workers
# are background processes, NOT psmux windows — so `psmux capture-pane` can't see
# them. This scans the orchestrator log dir for the per-worker meta files dropped by
# dispatch-codex.ps1 and reports each one's state, so `orchestrate poll` can fold
# headless workers into its dashboard + self-terminate check alongside the
# interactive (psmux) workers.
#
# State is derived from:
#   - the worker's PID (alive? best-effort via Get-Process)
#   - the final message file (<name>.last.txt, written by codex -o on completion)
#   - the WORKTREE_STATUS: COMPLETE / BLOCKED sentinels (from the brief) + the PR URL,
#     searched in the final message then the raw --json event stream.
#
# Usage:
#   check-headless-workers.ps1 -Config <repo>\.claude\session-plugin.json
#   check-headless-workers.ps1 -Config ... -Json      # machine-readable for the orchestrator
#   check-headless-workers.ps1 -LogsDir <worktrees>\.orchestrator\logs

param(
    [string]$Config,
    [string]$RepoPath,
    [string]$LogsDir,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")

if (-not $LogsDir) {
    $cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath
    $LogsDir = Join-Path $cfg.worktreesPath ".orchestrator\logs"
}

$results = @()
if (Test-Path $LogsDir) {
    $metas = @(Get-ChildItem -Path $LogsDir -Filter *.meta.json -ErrorAction SilentlyContinue)
    foreach ($m in $metas) {
        try {
            $meta = Get-Content $m.FullName -Raw | ConvertFrom-Json

            $pidVal     = if ($meta.PSObject.Properties.Name -contains 'pid')      { $meta.pid }      else { 0 }
            $name       = if ($meta.PSObject.Properties.Name -contains 'name')     { $meta.name }     else { $m.BaseName -replace '\.meta$', '' }
            $cli        = if ($meta.PSObject.Properties.Name -contains 'cli')      { $meta.cli }      else { 'codex' }
            $branch     = if ($meta.PSObject.Properties.Name -contains 'branch')   { $meta.branch }   else { '' }
            $lastFile   = if ($meta.PSObject.Properties.Name -contains 'last')     { $meta.last }     else { '' }
            $streamFile = if ($meta.PSObject.Properties.Name -contains 'stream')   { $meta.stream }   else { '' }
            $logFile    = if ($meta.PSObject.Properties.Name -contains 'log')      { $meta.log }      else { '' }

            $alive = $false
            if ($pidVal) { $alive = [bool](Get-Process -Id $pidVal -ErrorAction SilentlyContinue) }

            $lastText = ""
            if ($lastFile -and (Test-Path $lastFile)) { $lastText = (Get-Content $lastFile -Raw -ErrorAction SilentlyContinue) }
            $hasLast = -not [string]::IsNullOrWhiteSpace($lastText)

            # Search the final message first, then the raw event stream, for sentinels + PR.
            $searchText = $lastText
            if ($streamFile -and (Test-Path $streamFile)) {
                $searchText += "`n" + (Get-Content $streamFile -Raw -ErrorAction SilentlyContinue)
            }

            $pr = ""
            $prMatch = [regex]::Match($searchText, 'https://github\.com/[^\s"'']+/pull/\d+')
            if ($prMatch.Success) { $pr = $prMatch.Value }

            # State precedence: explicit sentinel > alive > finished-no-sentinel > gone.
            if     ($searchText -match 'WORKTREE_STATUS:\s*COMPLETE') { $state = "COMPLETE" }
            elseif ($searchText -match 'WORKTREE_STATUS:\s*BLOCKED')  { $state = "BLOCKED" }
            elseif ($alive)                                           { $state = "RUNNING" }
            elseif ($hasLast)                                         { $state = "DONE?" }   # finished, no sentinel - eyeball it
            else                                                      { $state = "EXITED" }  # gone, no result - likely errored, see log

            $results += [pscustomobject]@{
                Name = $name; CLI = $cli; State = $state; PR = $pr; Branch = $branch
                PID = $pidVal; Alive = $alive; Last = $lastFile; Stream = $streamFile; Log = $logFile
            }
        } catch {
            Write-Warning "Skipping unreadable meta '$($m.Name)': $($_.Exception.Message)"
            continue
        }
    }
}

if ($Json) {
    # Always emit a JSON array (even for 0 / 1 workers) so the orchestrator can parse uniformly.
    return (ConvertTo-Json @($results) -Depth 5)
}

if ($results.Count -eq 0) {
    Write-Host "No headless workers found in $LogsDir"
    return
}

$results | Sort-Object State, Name | Format-Table Name, CLI, State, PR, Branch, PID -AutoSize

$running  = @($results | Where-Object { $_.State -eq 'RUNNING' }).Count
$complete = @($results | Where-Object { $_.State -eq 'COMPLETE' }).Count
$blocked  = @($results | Where-Object { $_.State -eq 'BLOCKED' }).Count
Write-Host ""
Write-Host "Headless workers: $($results.Count) total - $running running, $complete complete, $blocked blocked."
if ($running -eq 0) { Write-Host "No headless workers still running (relevant to the orchestrator self-terminate check)." }

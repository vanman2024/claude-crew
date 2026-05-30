# psmux-dispatch-issues.ps1
#
# BULK wrapper around psmux-dispatch.ps1. Pass one or more GitHub issue numbers;
# this fetches each issue, builds a brief from its body (with the project's
# agent-team rules injected via New-WorkerBrief), and dispatches a worktree
# worker per issue. Each runs in its own psmux window with
# --dangerously-skip-permissions.
#
# Project-agnostic: repo / session / paths come from .claude/session-plugin.json.
#
# Usage:
#   psmux-dispatch-issues.ps1 510 511 512
#   psmux-dispatch-issues.ps1 -Issues 510,511,512
#   psmux-dispatch-issues.ps1 510 511 -Config C:\proj\.claude\session-plugin.json
#
# Branch + window names: fix/<issue#>-<slug-from-title>
# Briefs are written to $env:TEMP\session-bulk-dispatch\brief-<n>.md
# Attach: psmux attach -t <session>

param(
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [int[]]$Issues,

    [string]$Config,
    [string]$RepoPath,
    [string]$Session,
    [string]$BaseRef,
    [string]$Repo
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
. (Join-Path $ScriptDir "..\lib\_session-config.ps1")
. (Join-Path $ScriptDir "..\lib\_session-brief.ps1")

$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath
if (-not $Session) { $Session = $cfg.psmuxSession }
if (-not $BaseRef) { $BaseRef = "origin/$($cfg.defaultBranch)" }
if (-not $Repo)    { $Repo    = $cfg.githubRepo }

$DispatchScript = Join-Path $ScriptDir "psmux-dispatch.ps1"
if (-not (Test-Path $DispatchScript)) {
    Write-Error "psmux-dispatch.ps1 not found at $DispatchScript"; exit 1
}

$results = @()
$briefDir = Join-Path $env:TEMP "session-bulk-dispatch"
if (-not (Test-Path $briefDir)) { New-Item -ItemType Directory -Path $briefDir -Force | Out-Null }

foreach ($n in $Issues) {
    Write-Host ""
    Write-Host "===== Issue #$n =====" -ForegroundColor Cyan

    $issueJson = gh issue view $n --repo $Repo --json number,title,body,labels,state 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to fetch issue #$n -- skipping"
        $results += [pscustomobject]@{ Issue = $n; Status = "fetch-failed"; Target = $null }
        continue
    }

    try {
        $issue = $issueJson | ConvertFrom-Json
    } catch {
        Write-Warning "Failed to parse issue #$n JSON -- skipping"
        $results += [pscustomobject]@{ Issue = $n; Status = "parse-failed"; Target = $null }
        continue
    }

    if ($issue.state -ne "OPEN") {
        Write-Warning "Issue #$n is $($issue.state) -- skipping"
        $results += [pscustomobject]@{ Issue = $n; Status = "skipped-$($issue.state.ToLower())"; Target = $null }
        continue
    }

    $slug   = ConvertTo-SessionSlug $issue.title
    $name   = "fix-$n-$slug"
    $branch = "fix/$n-$slug"
    $labels = ($issue.labels | ForEach-Object { $_.name }) -join ", "

    $url = "https://github.com/$Repo/issues/$n"
    $task = @"
**Issue:** $($issue.title)
**URL:** $url
**Labels:** $labels

$($issue.body)
"@

    $brief = New-WorkerBrief -Config $cfg -Name $name -Branch $branch -Task $task -IssueNumber $n -Title $issue.title
    $briefFile = Join-Path $briefDir "brief-$n.md"
    Set-Content -Path $briefFile -Value $brief -Encoding UTF8

    Write-Host "Dispatching: $name" -ForegroundColor Yellow
    Write-Host "  Branch:    $branch"
    Write-Host "  Brief:     $briefFile"

    & $DispatchScript -Name $name -BootstrapFile $briefFile -Branch $branch -Session $Session -BaseRef $BaseRef -Config $cfg._configPath

    if ($LASTEXITCODE -eq 0) {
        $results += [pscustomobject]@{ Issue = $n; Status = "dispatched"; Target = "${Session}:$name" }
    } else {
        $results += [pscustomobject]@{ Issue = $n; Status = "dispatch-failed"; Target = $null }
    }
}

Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize
Write-Host ""
Write-Host "Attach: psmux attach -t $Session" -ForegroundColor Green
Write-Host "Watch:  psmux list-windows -t $Session"


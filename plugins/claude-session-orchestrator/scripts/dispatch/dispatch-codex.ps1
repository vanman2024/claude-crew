# dispatch-codex.ps1
#
# HEADLESS Codex dispatch — the build-ahead lane. Provision a worker worktree
# (shared with the interactive psmux-dispatch via Initialize-WorkerWorktree),
# then run `codex exec` to completion in the BACKGROUND, logging to
# <worktreesPath>\.orchestrator\logs\<name>.{jsonl,log}. Fan out N of these to
# fill a queue of green PRs while you verify sequentially in one local env.
# No psmux pane, no boot handshake (so it sidesteps the interactive-REPL startup
# fragility); the worker just runs to a PR and exits.
#
# `codex exec` interface (verified via `codex exec --help`):
#   --dangerously-bypass-approvals-and-sandbox  skip all prompts, no sandbox (headless)
#   --skip-git-repo-check                       run with our worktree layout
#   --json                                      JSONL events on stdout (the log stream)
#   -C <dir>                                    working root = the worktree
#   -o <file>                                   write the final agent message to a file
#   prompt via stdin (`-`)                      robust for long / multi-line briefs
# Codex must already be logged in (`codex login`).
#
# Usage:
#   dispatch-codex.ps1 -Name f042-backend -Task "Build X per specs/...md"
#   dispatch-codex.ps1 -Name fix-510-foo  -BootstrapFile brief.md -Branch fix/510-foo
#   dispatch-codex.ps1 -Name f042 -Task "..." -Wait          # block + print the result
#   dispatch-codex.ps1 -Name f042 -Task "..." -CodexCmd C:\Users\me\AppData\Roaming\npm\codex.cmd

param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    # Brief source (one of): inline markdown, a file, or a -Task to auto-generate
    # a brief (with the project's agent-team + data-flow rules injected).
    [string]$Bootstrap,
    [string]$BootstrapFile,
    [string]$Task,
    [string]$Title,
    [int]$IssueNumber,

    # Work type + spec, fed into the brief. -Mode feature|iteration (default: iteration
    # when -IssueNumber is set, else feature). -Spec = repo-relative path to the spec.
    [ValidateSet('feature', 'iteration')][string]$Mode,
    [string]$Spec,

    # Config resolution (see _session-config.ps1)
    [string]$Config,
    [string]$RepoPath,

    # Overrides (default to config values)
    [string]$BaseRef,
    [string]$Branch,

    # Codex CLI command (else config.codexCmdPath, else PATH). Optional model override.
    [string]$CodexCmd,
    [string]$Model,

    # Skip dependency wiring (faster when reusing a warm worktree)
    [switch]$SkipDeps,

    # Block until codex finishes and print the result (default: launch + return).
    [switch]$Wait
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
. (Join-Path $PSScriptRoot "..\lib\_session-brief.ps1")

$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

$RepoRoot = $cfg.repoPath
if (-not $Branch)  { $Branch  = "feature/$Name" }
if (-not $BaseRef) { $BaseRef = "origin/$($cfg.defaultBranch)" }

$codex = Get-CodexCmd -Config $cfg -CodexCmd $CodexCmd

function Step($msg) { Write-Host "[dispatch-codex] $msg" }

# --- 0. Resolve the brief -----------------------------------------------------
if ($BootstrapFile) {
    if (-not (Test-Path $BootstrapFile)) { Write-Error "BootstrapFile not found: $BootstrapFile"; exit 1 }
    $bootstrapContent = Get-Content $BootstrapFile -Raw
} elseif ($Bootstrap) {
    $bootstrapContent = $Bootstrap
} elseif ($Task) {
    $briefArgs = @{ Config = $cfg; Name = $Name; Branch = $Branch; Task = $Task }
    if ($Title) { $briefArgs.Title = $Title }
    if ($PSBoundParameters.ContainsKey('IssueNumber') -and $IssueNumber) { $briefArgs.IssueNumber = $IssueNumber }
    if ($Mode) { $briefArgs.Mode = $Mode }
    if ($Spec) {
        $briefArgs.Spec = $Spec
        if (-not (Test-Path (Join-Path $RepoRoot $Spec))) { Step "WARN: spec '$Spec' not found under $RepoRoot (worker is still told to read it)" }
    }
    $bootstrapContent = New-WorkerBrief @briefArgs
} else {
    Write-Error "Provide -Task <desc>, -Bootstrap <text>, or -BootstrapFile <path>"; exit 1
}

# --- 1. Provision the worktree (shared with psmux-dispatch) -------------------
$WtPath = Initialize-WorkerWorktree -Config $cfg -Name $Name -Branch $Branch -BaseRef $BaseRef `
    -BootstrapContent $bootstrapContent -SkipDeps:$SkipDeps -LogTag "dispatch-codex"

# --- 2. Log files -------------------------------------------------------------
$logDir = Join-Path $cfg.worktreesPath ".orchestrator\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$streamFile = Join-Path $logDir "$Name.jsonl"        # codex --json event stream
$logFile    = Join-Path $logDir "$Name.log"          # stderr
$lastFile   = Join-Path $logDir "$Name.last.txt"     # codex -o final message
$promptFile = Join-Path $logDir "$Name.prompt.txt"   # stdin prompt
foreach ($f in @($streamFile, $lastFile)) { if (Test-Path $f) { Remove-Item $f -Force } }

# The headless worker is pointed at the brief we just wrote and told to run to a PR.
# (Mirrors the psmux path's "read .claude-bootstrap.md and follow it" message.)
$prompt = @"
Read .claude-bootstrap.md in this directory ($WtPath) and follow it EXACTLY.
You are an autonomous HEADLESS worker — no human is watching this run. Plan first,
then build straight through to a green PR. Do NOT stop to ask for permission or
approval. When the PR is open and tests pass, print the WORKTREE_STATUS: COMPLETE
block from the brief. If you hit a blocker you cannot resolve, print WORKTREE_STATUS:
BLOCKED with the reason and stop.
"@
Set-Content -Path $promptFile -Value $prompt -Encoding UTF8

# --- 3. Build codex exec args -------------------------------------------------
$codexArgs = @(
    'exec',
    '--dangerously-bypass-approvals-and-sandbox',
    '--skip-git-repo-check',
    '--json',
    '-C', $WtPath,
    '-o', $lastFile
)
if ($Model) { $codexArgs += @('-m', $Model) }
$codexArgs += '-'   # read the prompt from stdin

# Codex must not inherit Claude's nested-session markers.
$env:CLAUDECODE = $null
$env:CLAUDE_CODE_ENTRYPOINT = $null

Step "Launching codex exec (headless) for '$Name'"
Step "  worktree: $WtPath"
Step "  stream:   $streamFile"
Step "  result:   $lastFile"

$spArgs = @{
    FilePath               = $codex
    ArgumentList           = $codexArgs
    WorkingDirectory       = $WtPath
    RedirectStandardInput  = $promptFile
    RedirectStandardOutput = $streamFile
    RedirectStandardError  = $logFile
    NoNewWindow            = $true
    PassThru               = $true
}
if ($Wait) { $spArgs.Wait = $true }

$proc = Start-Process @spArgs

# Drop a meta file so the headless-worker monitor (status/check-headless-workers.ps1)
# can find this run, check liveness by PID, and locate its stream/result logs.
$metaFile = Join-Path $logDir "$Name.meta.json"
@{
    name      = $Name
    cli       = "codex"
    pid       = $proc.Id
    branch    = $Branch
    worktree  = $WtPath
    stream    = $streamFile
    last      = $lastFile
    log       = $logFile
    startedAt = (Get-Date -Format o)
} | ConvertTo-Json | Set-Content -Path $metaFile -Encoding UTF8

if ($Wait) {
    $exitCode = $proc.ExitCode
    Write-Host "EXIT_CODE=$exitCode"
    Write-Host "STREAM=$streamFile"
    Write-Host "LOG=$logFile"
    if (Test-Path $lastFile) {
        Write-Host "---RESULT---"
        Write-Host (Get-Content $lastFile -Raw)
    }
    exit $exitCode
} else {
    Write-Host "DISPATCHED_HEADLESS=codex"
    Write-Host "NAME=$Name"
    Write-Host "PID=$($proc.Id)"
    Write-Host "WORKTREE=$WtPath"
    Write-Host "BRANCH=$Branch"
    Write-Host "STREAM=$streamFile"
    Write-Host "RESULT=$lastFile"
    Write-Host "LOG=$logFile"
    Write-Host "Monitor with:  Get-Content '$streamFile' -Wait -Tail 20    (final message lands in $lastFile)"
}

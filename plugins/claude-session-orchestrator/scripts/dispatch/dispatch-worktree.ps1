param(
    [Parameter(Mandatory=$true)]
    [string]$Name,

    [Parameter(Mandatory=$true)]
    [string]$Prompt,

    [switch]$Continue,

    [string]$Config,
    [string]$RepoPath
)

# Dispatch a claude -p task to a worktree WITHOUT cd'ing
# Uses Start-Process -WorkingDirectory so the process STARTS in the worktree
# Output is written to a log file that the orchestrator can read

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

$wtBase = $cfg.worktreesPath
$wtPath = Join-Path $wtBase $Name
$logDir = Join-Path $wtBase ".orchestrator\logs"
$logFile = Join-Path $logDir "$Name.log"
$streamFile = Join-Path $logDir "$Name.jsonl"

# Validate worktree exists
if (-not (Test-Path $wtPath)) {
    Write-Error "Worktree not found: $wtPath"
    exit 1
}

# Ensure log directory exists
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Clear previous log
if (Test-Path $streamFile) { Remove-Item $streamFile -Force }

# Build the project's test step from config test commands. Each is rendered as
# "name: cmd". If the project declares none, fall back to a generic instruction.
$testCmds = @(Get-TestCommands -Config $cfg)
if ($testCmds.Count -gt 0) {
    $testStepLines = $testCmds | ForEach-Object { "       - $($_.name): $($_.cmd)" }
    $testStep = "Run this project's tests and fix all failures:`n" + ($testStepLines -join "`n")
} else {
    $testStep = "run this project's tests and fix all failures"
}

# Prepend mandatory planning phase to every prompt
$planPrefix = @"
MANDATORY PROTOCOL — You MUST follow these phases in order:

PHASE 1 — PLAN (do NOT write any code yet):
  a) Read CLAUDE.md for project rules
  b) Read ALL referenced files in the prompt
  c) Run: git branch --show-current && pwd (confirm you are in the correct worktree)
  d) List EVERY file you will create or modify and describe what changes you will make
  e) Identify potential conflicts or risks
  f) Only proceed to Phase 2 after completing the full plan

PHASE 2 — BUILD (execute the plan):
  a) Implement changes one file at a time
  b) After each file, verify it compiles / typechecks
  c) DO NOT delete any files unless explicitly told to

PHASE 3 — TEST (ALL must pass before proceeding):
  a) $testStep
  b) Fix ALL failures before proceeding. Do NOT skip tests. Do NOT commit with failures.

PHASE 4 — COMMIT + PUSH:
  a) git add the specific files you changed (never git add -A)
  b) Commit with a descriptive message
  c) Push to the current branch

Now here is your task:

"@

# Build claude argument STRING (not array — Start-Process joins arrays without quoting)
# The prompt MUST be quoted as a single argument to avoid word-splitting
$fullPrompt = $planPrefix + $Prompt
# Feed the prompt via STDIN, not the command line. Windows truncates long /
# multi-line -ArgumentList strings at the first newline, which silently cut the
# prompt down to its first line. Writing to a file + RedirectStandardInput is
# robust for prompts of any size.
$promptFile = Join-Path $logDir "$Name.prompt.txt"
Set-Content -Path $promptFile -Value $fullPrompt -Encoding UTF8

$argString = "-p --output-format stream-json --verbose --dangerously-skip-permissions"
if ($Continue) {
    $argString += " --continue"
}

# Remove CLAUDECODE env var so nested session is allowed
# Setting to $null removes it from current process env; child inherits clean env
$env:CLAUDECODE = $null

# Start claude NATIVELY in the worktree directory — no cd. Prompt arrives on stdin.
# -WorkingDirectory sets the process's starting directory at the OS level
$process = Start-Process -FilePath $cfg.workerCmdPath `
    -ArgumentList $argString `
    -WorkingDirectory $wtPath `
    -NoNewWindow `
    -Wait `
    -RedirectStandardInput $promptFile `
    -RedirectStandardOutput $streamFile `
    -RedirectStandardError $logFile `
    -PassThru

# Report result
$exitCode = $process.ExitCode
Write-Host "EXIT_CODE=$exitCode"
Write-Host "LOG=$logFile"
Write-Host "STREAM=$streamFile"

# Extract final result from stream
if (Test-Path $streamFile) {
    $lastLine = Get-Content $streamFile -Tail 1
    try {
        $result = $lastLine | ConvertFrom-Json
        if ($result.type -eq "result") {
            Write-Host "STATUS=completed"
            Write-Host "---RESULT---"
            Write-Host $result.result
        } else {
            Write-Host "STATUS=unknown"
        }
    } catch {
        Write-Host "STATUS=parse_error"
    }
}

exit $exitCode



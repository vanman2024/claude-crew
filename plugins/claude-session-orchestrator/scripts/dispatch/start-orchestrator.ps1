# start-orchestrator.ps1
#
# Spawns a dedicated Orchestrator Claude in its own psmux window, running from
# its own git worktree at <worktreesPath>\orchestrator (detached HEAD at
# origin/<defaultBranch> — never modified, never committed to). The worktree
# exists so the orchestrator Claude has:
#   - the project's .claude/ tree available (so /session resolves)
#   - a stable file context that does NOT swap when you git checkout in main
#
# The orchestrator is autonomous (no human watching the pane), so it runs with
# --dangerously-skip-permissions. The no-auto-merge contract is enforced by its
# brief (.claude-bootstrap.md), not by permissions.
#
# Project-agnostic: all paths/session/branch/repo come from session-plugin.json.
#
# Usage:
#   start-orchestrator.ps1                       # default 5m poll interval
#   start-orchestrator.ps1 -IntervalMin 3
#   start-orchestrator.ps1 -Config C:\proj\.claude\session-plugin.json
#
# Stop: psmux kill-window -t <session>:orchestrator
# Or it self-terminates when no workers remain and no open PRs from the batch
# are still awaiting review.

param(
    [string]$Config,
    [string]$RepoPath,
    [string]$Session,
    [string]$Window      = "orchestrator",
    [int]   $IntervalMin = 5,
    # By default, also spawn the Reviewer Claude (the overseer that verifies PRs as
    # they go green). Pass -NoReviewer to launch the orchestrator alone.
    [switch]$NoReviewer
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

if (-not $Session) { $Session = $cfg.psmuxSession }
$ClaudeCmd            = $cfg.workerCmdPath
$MainRepo             = $cfg.repoPath
$WtBase               = $cfg.worktreesPath
$DefaultBranch        = $cfg.defaultBranch
$OrchestratorWorktree = Join-Path $WtBase "orchestrator"
# Resolve the teardown script (sibling folder) so the brief can reference it by absolute path.
$CloseWorkerScript    = (Join-Path $PSScriptRoot "..\teardown\close-worker.ps1")
if (Test-Path $CloseWorkerScript) { $CloseWorkerScript = (Resolve-Path $CloseWorkerScript).Path }

if (-not (Test-Path $ClaudeCmd))                            { Write-Error "claude.cmd not found at $ClaudeCmd (config.workerCmdPath)"; exit 1 }
if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) { Write-Error "psmux not on PATH"; exit 1 }
if (-not (Test-Path $MainRepo))                             { Write-Error "Main repo not found at $MainRepo (config.repoPath)"; exit 1 }

# 1. Ensure the orchestrator worktree exists, detached at origin/<defaultBranch>.
if (-not (Test-Path $OrchestratorWorktree)) {
    Write-Host "[start-orchestrator] Creating worktree at $OrchestratorWorktree (detached at origin/$DefaultBranch)"
    git -C $MainRepo fetch origin $DefaultBranch | Out-Null
    git -C $MainRepo worktree add --detach $OrchestratorWorktree "origin/$DefaultBranch"
    if ($LASTEXITCODE -ne 0) { Write-Error "git worktree add failed"; exit 1 }
} else {
    Write-Host "[start-orchestrator] Reusing existing worktree at $OrchestratorWorktree"
}

# 2. Ensure psmux session.
$sessionExists = (psmux ls 2>$null | Select-String -SimpleMatch $Session)
if (-not $sessionExists) {
    Write-Host "[start-orchestrator] Creating psmux session '$Session'"
    psmux new -s $Session -d
}

# 3. Don't double-spawn the window.
$existing = (psmux list-windows -t $Session 2>$null | Select-String -SimpleMatch $Window)
if ($existing) {
    Write-Host "[start-orchestrator] Window '$Window' already exists in '$Session' -- leaving it."
    Write-Host "  Attach: psmux attach -t $Session"
    Write-Host "  Kill:   psmux kill-window -t ${Session}:$Window"
    exit 0
}

# 4. Write the brief into the worktree as .claude-bootstrap.md.
$wtBaseFwd = ($WtBase -replace '\\', '/')
$mainFwd   = ($MainRepo -replace '\\', '/')
$orchFwd   = ($OrchestratorWorktree -replace '\\', '/')

$briefPath = Join-Path $OrchestratorWorktree ".claude-bootstrap.md"
$brief = @"
You are the **Orchestrator Claude** for the $($cfg.projectName) parallel-build pipeline.

Your cwd is **$OrchestratorWorktree** — a git worktree detached at origin/$DefaultBranch. NOT the main repo. The user's git checkouts in the main repo do not affect this dir. You have full access to the project's .claude/ tree from this checkout.

BATCH SCOPING (critical — read before the contract):

"This batch" = PRs whose head branch matches an ACTIVE git worktree in ``$wtBaseFwd/`` (excluding the infra worktrees: your own ``orchestrator`` and the reviewer's ``reviewer`` + ``review-checkout``).

To identify your batch on every poll:

1. ``git -C $mainFwd worktree list --porcelain`` -> all active worktrees and their branches. Parse each ``branch refs/heads/<name>`` line.
2. **Skip** the infra worktrees: your own at ``$orchFwd``, plus ``$wtBaseFwd/reviewer`` and ``$wtBaseFwd/review-checkout`` (the reviewer is a sibling overseer, not a worker).
3. ``gh pr list --repo $($cfg.githubRepo) --state open --json number,title,headRefName,statusCheckRollup,mergeable`` -> all open PRs.
4. **Filter:** keep only PRs whose ``headRefName`` matches one of the active worktree branches from step 1.

PRs whose worktrees were already torn down are OUTSIDE your scope. PRs from previous sessions, the user's own work, and any branch without a live worktree in ``$wtBaseFwd/`` are NOT in your batch. Do NOT report them, do NOT consider merging them, do NOT include them in your status.

CONTRACT (do not violate):

1. Every $IntervalMin minutes, poll the worker panes.
2. ``psmux list-windows -t $Session`` to see live workers. Skip the infra windows: yourself (``$Window``) and ``reviewer``.
3. For each worker: ``psmux capture-pane -t ${Session}:<worker> -p`` and analyze state.
4. ``psmux send-keys -t ${Session}:<worker> "<nudge>" Enter`` to steer stuck workers.
5. ``gh pr list --repo $($cfg.githubRepo) --state open --json number,title,headRefName,statusCheckRollup,mergeable`` for PR status, then **filter to the batch** (see BATCH SCOPING) — ignore PRs whose branch is not in an active worktree.
6. When a worker reports ``WORKTREE_STATUS: COMPLETE`` and its PR is open with green CI: report it as ``READY FOR USER REVIEW``. Do NOT merge.
7. When a worker reports ``WORKTREE_STATUS: BLOCKED``: report the reason and stop nudging that worker.
8. When a PR is observed merged (by the user) and its worker window still exists: run the teardown script
   ``powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$CloseWorkerScript" -Name <worker> -Config "$($cfg._configPath)"``
   which detaches the node_modules junction(s) FIRST, kills the window, then removes the worktree.
9. **Self-terminate** the loop when: no live worker windows AND no open PRs from this batch remain. Print a summary, exit the loop, exit Claude.

HARD RULES:

- NEVER run ``gh pr merge``. The user authorizes all merges via their conversational Claude.
- NEVER run ``git checkout`` against the main repo at $MainRepo.
- NEVER run ``git pull origin $DefaultBranch`` in the main repo.
- NEVER modify or commit in this orchestrator worktree.
- Read-only git operations are fine: ``git -C <abs-path> fetch``, ``git -C <abs-path> status``.
- Report compactly. One line per worker per poll unless something changed.

FIRST ACTION — run one immediate poll right now so you have a current picture of workers + PRs before the loop's first interval:

``/session orchestrate poll``

THEN start the recurring loop:

``/loop ${IntervalMin}m /session orchestrate poll``
"@

Set-Content -Path $briefPath -Value $brief -Encoding UTF8
Write-Host "[start-orchestrator] Wrote brief to $briefPath"

# 5. Create the psmux window with cwd = the orchestrator worktree.
Write-Host "[start-orchestrator] Creating window '$Window' cwd=$OrchestratorWorktree"
psmux new-window -t $Session -n $Window -c $OrchestratorWorktree

$target = "${Session}:${Window}"

# 6. Clear inherited CLAUDECODE so this Claude can spawn sub-agents if needed.
psmux send-keys -t $target '$env:CLAUDECODE=$null; $env:CLAUDE_CODE_ENTRYPOINT=$null'
psmux send-keys -t $target Enter

# 7. Launch Claude (bare-path launch + standalone Enter, the proven pattern).
psmux send-keys -t $target "$ClaudeCmd --dangerously-skip-permissions"
psmux send-keys -t $target Enter

# 8. Wait for Claude to boot before sending the brief instruction.
Start-Sleep -Seconds 8

# 9. Send the short instruction (relative path — cwd is the worktree).
psmux send-keys -t $target "Read .claude-bootstrap.md and follow it exactly."
psmux send-keys -t $target Enter

Write-Host ""
Write-Host "[start-orchestrator] Launched in $target" -ForegroundColor Green
Write-Host "  Worktree:  $OrchestratorWorktree"
Write-Host "  Brief:     $briefPath"
Write-Host "  Attach:    psmux attach -t $Session"
Write-Host "  Read pane: psmux capture-pane -t $target -p"
Write-Host "  Kill:      psmux kill-window -t $target"
Write-Host ""
Write-Host "Contract: NO auto-merge. Orchestrator reports PRs as READY FOR USER REVIEW." -ForegroundColor Yellow
Write-Host "You authorize merges by telling your conversational Claude 'merge it'."

# 10. Also spawn the Reviewer Claude (the overseer) unless opted out. It verifies
#     each green PR (tests + /code-review) one at a time and produces an ordered,
#     verified merge queue — so the orchestrator's "READY FOR USER REVIEW" PRs are
#     actually proven before you merge them.
if (-not $NoReviewer) {
    $reviewerScript = (Join-Path $PSScriptRoot "start-reviewer.ps1")
    if (Test-Path $reviewerScript) {
        Write-Host ""
        Write-Host "[start-orchestrator] Spawning the Reviewer (overseer) too — use -NoReviewer to skip." -ForegroundColor Cyan
        $reviewerArgs = @{ Session = $Session; IntervalMin = $IntervalMin }
        if ($Config)   { $reviewerArgs.Config   = $Config }
        if ($RepoPath) { $reviewerArgs.RepoPath = $RepoPath }
        & $reviewerScript @reviewerArgs
    } else {
        Write-Host "[start-orchestrator] WARN: start-reviewer.ps1 not found next to this script; skipping reviewer." -ForegroundColor Yellow
    }
} else {
    Write-Host "[start-orchestrator] -NoReviewer set — reviewer NOT launched. Start it later with /session review-start." -ForegroundColor DarkGray
}



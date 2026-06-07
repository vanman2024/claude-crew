# start-reviewer.ps1
#
# Spawns a dedicated Reviewer Claude in its own psmux window — the "overseer" that
# verifies worker PRs one at a time as they go green, so nothing is merged blind.
#
# It has TWO worktrees (both under <worktreesPath>, both project-agnostic):
#   - HOME      <wt>\reviewer        detached at origin/<defaultBranch>. The Claude's
#                                    stable cwd: holds .claude-bootstrap.md and the
#                                    project's .claude/ tree (so /session resolves).
#                                    NEVER checked out, NEVER committed to.
#   - CHECKOUT  <wt>\review-checkout  where it actually checks out each PR branch,
#                                    runs the project's tests, and runs /code-review
#                                    on the diff. node_modules is junctioned ONCE from
#                                    the main checkout (no install, shared across the
#                                    branch checkouts it cycles through).
#
# The reviewer is autonomous (no human watching the pane), so it runs with
# --dangerously-skip-permissions. Its CONTRACT (no-merge, never touch main, verify
# in its OWN checkout worktree, one PR at a time, ordered by file-overlap) is
# enforced by its brief (.claude-bootstrap.md) — see reference/commands-review.md.
#
# Project-agnostic: all paths/session/branch/repo come from session-plugin.json.
#
# Usage:
#   start-reviewer.ps1                       # default 5m review interval
#   start-reviewer.ps1 -IntervalMin 3
#   start-reviewer.ps1 -Config C:\proj\.claude\session-plugin.json
#
# Stop: psmux kill-window -t <session>:reviewer
# Or it self-terminates when no workers remain and no open batch PRs await review.

param(
    [string]$Config,
    [string]$RepoPath,
    [string]$Session,
    [string]$Window      = "reviewer",
    [int]   $IntervalMin = 5
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

if (-not $Session) { $Session = $cfg.psmuxSession }
$ClaudeCmd        = $cfg.workerCmdPath
$MainRepo         = $cfg.repoPath
$WtBase           = $cfg.worktreesPath
$DefaultBranch    = $cfg.defaultBranch
$ReviewerHome     = Join-Path $WtBase "reviewer"
$ReviewCheckout   = Join-Path $WtBase "review-checkout"

# Resolve the interval from config.review.intervalMin if present (param overrides only when passed).
if (-not $PSBoundParameters.ContainsKey('IntervalMin') -and
    ($cfg.PSObject.Properties.Name -contains 'review') -and $cfg.review -and
    ($cfg.review.PSObject.Properties.Name -contains 'intervalMin') -and $cfg.review.intervalMin) {
    $IntervalMin = [int]$cfg.review.intervalMin
}

if (-not (Test-Path $ClaudeCmd))                            { Write-Error "claude.cmd not found at $ClaudeCmd (config.workerCmdPath)"; exit 1 }
if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) { Write-Error "psmux not on PATH"; exit 1 }
if (-not (Test-Path $MainRepo))                             { Write-Error "Main repo not found at $MainRepo (config.repoPath)"; exit 1 }

# 1. Ensure the reviewer HOME worktree exists, detached at origin/<defaultBranch>.
git -C $MainRepo fetch origin $DefaultBranch | Out-Null
if (-not (Test-Path $ReviewerHome)) {
    Write-Host "[start-reviewer] Creating home worktree at $ReviewerHome (detached at origin/$DefaultBranch)"
    git -C $MainRepo worktree add --detach $ReviewerHome "origin/$DefaultBranch"
    if ($LASTEXITCODE -ne 0) { Write-Error "git worktree add (home) failed"; exit 1 }
} else {
    Write-Host "[start-reviewer] Reusing existing home worktree at $ReviewerHome"
}

# 2. Ensure the CHECKOUT worktree exists (detached at origin/<defaultBranch> to start).
if (-not (Test-Path $ReviewCheckout)) {
    Write-Host "[start-reviewer] Creating checkout worktree at $ReviewCheckout (detached at origin/$DefaultBranch)"
    git -C $MainRepo worktree add --detach $ReviewCheckout "origin/$DefaultBranch"
    if ($LASTEXITCODE -ne 0) { Write-Error "git worktree add (checkout) failed"; exit 1 }
} else {
    Write-Host "[start-reviewer] Reusing existing checkout worktree at $ReviewCheckout"
}

# 3. Junction node_modules into the CHECKOUT worktree (once; shared across branch checkouts).
foreach ($rel in (Get-NodeModuleMappings -Config $cfg)) {
    $coNm   = Join-Path $ReviewCheckout $rel
    $mainNm = Join-Path $MainRepo $rel
    if (-not (Test-Path $mainNm)) {
        Write-Host "[start-reviewer] WARN: main checkout has no '$rel' - install deps in the main repo first"
    } elseif (Test-Path $coNm) {
        Write-Host "[start-reviewer] '$rel' already present in checkout worktree - leaving as-is"
    } else {
        $coNmParent = Split-Path $coNm -Parent
        if (-not (Test-Path $coNmParent)) { New-Item -ItemType Directory -Path $coNmParent -Force | Out-Null }
        Write-Host "[start-reviewer] Junctioning '$rel' into checkout worktree (no install)"
        New-Item -ItemType Junction -Path $coNm -Target $mainNm | Out-Null
    }
}

# 4. Ensure psmux session.
$sessionExists = (psmux ls 2>$null | Select-String -SimpleMatch $Session)
if (-not $sessionExists) {
    Write-Host "[start-reviewer] Creating psmux session '$Session'"
    psmux new -s $Session -d
}

# 5. Don't double-spawn the window.
$existing = (psmux list-windows -t $Session 2>$null | Select-String -SimpleMatch $Window)
if ($existing) {
    Write-Host "[start-reviewer] Window '$Window' already exists in '$Session' -- leaving it."
    Write-Host "  Attach: psmux attach -t $Session"
    Write-Host "  Kill:   psmux kill-window -t ${Session}:$Window"
    exit 0
}

# 6. Write the brief into the home worktree as .claude-bootstrap.md.
$wtBaseFwd   = ($WtBase -replace '\\', '/')
$mainFwd     = ($MainRepo -replace '\\', '/')
$homeFwd     = ($ReviewerHome -replace '\\', '/')
$checkoutFwd = ($ReviewCheckout -replace '\\', '/')

# Render the project's test commands as a bullet list for the brief.
$testCmds = Get-TestCommands -Config $cfg
if ($testCmds -and $testCmds.Count -gt 0) {
    $testLines = ($testCmds | ForEach-Object { "   - $($_.name): ``$($_.cmd)``" }) -join "`n"
} else {
    $testLines = "   - (no config.layout test commands declared — run the project's typecheck/test commands and fix nothing yourself)"
}

$briefPath = Join-Path $ReviewerHome ".claude-bootstrap.md"
$brief = @"
You are the **Reviewer Claude** (the overseer) for the $($cfg.projectName) parallel-build pipeline.

Your cwd is **$ReviewerHome** — a git worktree detached at origin/$DefaultBranch. This is your STABLE HOME: never check out branches here, never commit here. You have the project's .claude/ tree from this checkout, so /session resolves.

Your job: as worker PRs go green, verify them ONE AT A TIME in your dedicated checkout worktree so nothing is ever merged blind. You do NOT merge — you produce an ORDERED, VERIFIED queue and label each PR, then the user merges.

YOUR CHECKOUT WORKTREE (this is where you actually test code):

``$checkoutFwd`` — a separate worktree with node_modules already junctioned from the main checkout. Check out each PR head HERE in DETACHED mode (``git -C $checkoutFwd fetch origin <branch>`` then ``git -C $checkoutFwd checkout --detach FETCH_HEAD``), run tests HERE, then move to the next PR. Use ``--detach`` because the worker still holds that branch in its own worktree, and git refuses to check out the same branch in two worktrees. NEVER check out PR branches in the main repo at $MainRepo.

BATCH SCOPING (which PRs are yours):

"This batch" = open PRs whose head branch matches an ACTIVE git worktree in ``$wtBaseFwd/``, EXCLUDING your own (``$homeFwd``, ``$checkoutFwd``) and the orchestrator's (``$wtBaseFwd/orchestrator``).

On every review cycle:
1. ``git -C $mainFwd worktree list --porcelain`` -> active worktrees + their branches.
2. Skip ``reviewer``, ``review-checkout``, ``orchestrator`` worktrees.
3. ``gh pr list --repo $($cfg.githubRepo) --state open --json number,title,headRefName,statusCheckRollup,mergeable`` -> open PRs.
4. Keep only PRs whose ``headRefName`` matches an active worker worktree branch.

THE REVIEW GATE (a PR is READY-VERIFIED only if BOTH pass):
A. The project's tests pass when run against the PR branch in your checkout worktree:
$testLines
B. ``/code-review`` against the checked-out PR head (it reviews the changes vs $DefaultBranch) finds no blocking (correctness/security) issues.

REVIEW CYCLE (this is what ``/session review`` does — see reference/commands-review.md for the full protocol):
1. Compute the batch (above). Consider only PRs with green CI that you have not already marked READY-VERIFIED.
2. ORDER them: PRs that share no files merge in any order; PRs that touch the same path must be sequenced (verify the lower PR number first). Use ``gh pr view <n> --json files`` to find overlap.
3. Take the FIRST un-verified PR in that order. In the checkout worktree:
   a. ``git -C $checkoutFwd fetch origin <branch>`` ; ``git -C $checkoutFwd checkout --detach FETCH_HEAD`` (detached — the worker holds the branch; same branch can't be checked out in two worktrees)
   b. Run the test commands above (cd into the checkout worktree / its parts). Fix NOTHING yourself.
   c. Run ``/code-review`` against the checked-out PR head (reviews changes vs $DefaultBranch; use ``gh pr diff <n>`` for the raw diff if needed).
4. VERDICT:
   - PASS (tests green AND no blocking findings) -> label/comment the PR ``READY-VERIFIED`` and add it to the ordered queue (note its position and any sequencing dependency).
   - FAIL -> post the findings as a PR review comment (``gh pr comment <n>`` / ``gh pr review <n> --request-changes``) AND, if the worker window is still live, ``psmux send-keys -t ${Session}:<worker> "<short fix instruction>" Enter``. Do not re-verify until the worker pushes a new commit.
5. Move to the next PR. One PR per pass keeps it sequential and legible.
6. Report the queue (see OUTPUT).

OUTPUT each cycle:
``````
REVIEW QUEUE (verified, in merge order)
  1. #26 feature/f008-quiz     tests PASS  review PASS   READY-VERIFIED  (disjoint)
  2. #25 feature/f021-referral tests PASS  review PASS   READY-VERIFIED  (after #26: both touch lib/db.ts)
Awaiting fixes:
  #31 feature/f045-progress    review CHANGES-REQUESTED -> nudged worker
Not yet verified: #33 (CI still running)
``````

HARD RULES (do not violate):
- NEVER run ``gh pr merge``. You produce the verified ordered queue; the user authorizes every merge.
- NEVER run ``git checkout`` / ``git pull`` / commit against the main repo at $MainRepo.
- ONLY check out branches in ``$checkoutFwd``. Never in your home or a worker's worktree.
- Do NOT fix the code yourself. If a PR fails, send it back to the worker (comment + nudge). You review; workers fix.
- Verify ONE PR at a time, in overlap order. Re-verify a PR only after a new commit is pushed.
- Self-terminate the loop when there are no live worker windows AND no open batch PRs left to verify. Print the final queue, exit the loop, exit Claude.

FIRST ACTION — run one immediate review cycle now so you have a current picture:

``/session review``

THEN start the recurring loop:

``/loop ${IntervalMin}m /session review``
"@

Set-Content -Path $briefPath -Value $brief -Encoding UTF8
Write-Host "[start-reviewer] Wrote brief to $briefPath"

# 7. Create the psmux window with cwd = the reviewer home worktree.
Write-Host "[start-reviewer] Creating window '$Window' cwd=$ReviewerHome"
psmux new-window -t $Session -n $Window -c $ReviewerHome

$target = "${Session}:${Window}"

# 8. Clear inherited CLAUDECODE so this Claude can spawn sub-agents (the /code-review skill).
psmux send-keys -t $target '$env:CLAUDECODE=$null; $env:CLAUDE_CODE_ENTRYPOINT=$null'
psmux send-keys -t $target Enter

# 9. Launch Claude (bare-path launch + standalone Enter, the proven pattern).
psmux send-keys -t $target "$ClaudeCmd --dangerously-skip-permissions"
psmux send-keys -t $target Enter

# 10. Wait for Claude to boot before sending the brief instruction.
Start-Sleep -Seconds 8

# 11. Send the short instruction (relative path — cwd is the home worktree).
psmux send-keys -t $target "Read .claude-bootstrap.md and follow it exactly."
psmux send-keys -t $target Enter

Write-Host ""
Write-Host "[start-reviewer] Launched in $target" -ForegroundColor Green
Write-Host "  Home:       $ReviewerHome"
Write-Host "  Checkout:   $ReviewCheckout"
Write-Host "  Brief:      $briefPath"
Write-Host "  Attach:     psmux attach -t $Session"
Write-Host "  Read pane:  psmux capture-pane -t $target -p"
Write-Host "  Kill:       psmux kill-window -t $target"
Write-Host ""
Write-Host "Contract: NO auto-merge. Reviewer verifies PRs and produces an ordered READY-VERIFIED queue." -ForegroundColor Yellow
Write-Host "You authorize merges by telling your conversational Claude 'merge it'."

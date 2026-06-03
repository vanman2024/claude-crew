# _session-brief.ps1
#
# Brief generators. The worker brief is written to <worktree>/.claude-bootstrap.md
# and is the ONLY thing the worker is told to read on launch. It must be
# self-contained: project rules pointer, the task, the agent-team / file-lane
# rules synthesized from config.teams, the test commands from config.layout,
# and the commit/push/PR contract.
#
# Dot-source AFTER _session-config.ps1:
#     . (Join-Path $PSScriptRoot "_session-config.ps1")
#     . (Join-Path $PSScriptRoot "_session-brief.ps1")

Set-StrictMode -Version Latest

# Render the agent-team / file-lane section from config.teams. Returns '' when no
# teams are declared (project falls back to a generic single-Claude build flow).
function Format-TeamsSection {
    param([Parameter(Mandatory)]$Config)

    if (-not ($Config.PSObject.Properties.Name -contains "teams") -or $null -eq $Config.teams) {
        return @"
## Build approach: single-Claude

This project has not declared specialized agent teams. Build the task yourself,
in layer order, testing as you go. Use the Explore agent to read the codebase
first. You may still launch independent sub-agents for genuinely parallel,
non-overlapping work, but there is no required agent roster.
"@
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("## MANDATORY: use the SPECIALIZED agents for this project — NEVER ``general-purpose`` for build work")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Split work by ROLE / FILE-LANE, not by feature-slice. Each lane below owns disjoint paths so parallel agents do not collide. Launch the independent agents in a SINGLE message so they run concurrently, then run an API-contract verification pass (frontend fetch types == route types == backend models; no drift, no ``any``, no dead endpoints).")
    [void]$sb.AppendLine("")

    foreach ($teamName in $Config.teams.PSObject.Properties.Name) {
        $team = $Config.teams.$teamName
        [void]$sb.AppendLine("### Team: $teamName")
        if (($team.PSObject.Properties.Name -contains "ownsPaths") -and $team.ownsPaths) {
            [void]$sb.AppendLine("- **Owns paths:** $((($team.ownsPaths) -join ', '))")
        }
        if (($team.PSObject.Properties.Name -contains "agents") -and $team.agents) {
            [void]$sb.AppendLine("- **Agents (use these exact ``subagent_type`` names):**")
            foreach ($a in $team.agents) { [void]$sb.AppendLine("    - ``$a``") }
        }
        if (($team.PSObject.Properties.Name -contains "skills") -and $team.skills) {
            $bt = [char]96
            $skillList = ($team.skills | ForEach-Object { "$bt$_$bt" }) -join ', '
            [void]$sb.AppendLine("- **Skills:** $skillList")
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("**Hard rules (non-negotiable):**")
    [void]$sb.AppendLine("- Do NOT use ``general-purpose`` for build work when a specialized agent is configured for that lane.")
    [void]$sb.AppendLine("- Launch independent agents in a SINGLE message so they run concurrently.")
    [void]$sb.AppendLine("- If a needed specialized agent is NOT available in this environment, print ``BLOCKED: <agent> unavailable`` and stop — do NOT silently fall back to ``general-purpose``.")
    return $sb.ToString()
}

# Render the test-command block from config.layout.
function Format-TestSection {
    param([Parameter(Mandatory)]$Config)
    $cmds = Get-TestCommands -Config $Config
    if (-not $cmds -or $cmds.Count -eq 0) {
        return "Run whatever test/typecheck commands this project uses, and fix ALL failures before committing."
    }
    $lines = @()
    foreach ($c in $cmds) {
        $lines += "- **$($c.name):** ``$($c.cmd)``"
    }
    return ($lines -join "`n")
}

# Build the full worker brief markdown.
#   -Task is the freeform body (issue body, spec pointer, feature description).
function New-WorkerBrief {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Task,
        [int]$IssueNumber,
        [string]$Title
    )

    $teams = Format-TeamsSection -Config $Config
    $tests = Format-TestSection -Config $Config
    $base  = $Config.defaultBranch
    $repo  = $Config.githubRepo

    $closes = ""
    if ($PSBoundParameters.ContainsKey('IssueNumber') -and $IssueNumber) {
        $closes = " Closes #$IssueNumber"
    }
    $titleLine = if ($Title) { "**Task:** $Title`n" } else { "" }

    return @"
# Worktree brief: $Name

You are a worker in an isolated git worktree on branch ``$Branch`` for project **$($Config.projectName)**. An orchestrator is watching this psmux pane and will steer you. You are autonomous and running with --dangerously-skip-permissions: plan first, then build straight through to a PR. Do not stop to ask for permission or approval.

$titleLine

## 1. Orient
1. Read ``CLAUDE.md`` (and any ``*/CLAUDE.md``) for project rules.
2. Confirm location: ``git branch --show-current`` should print ``$Branch`` and ``pwd`` should be this worktree.
3. Explore the relevant code before writing anything (use the Explore agent or read files directly).

## 2. The task

$Task

## 3. Plan first (do NOT write code yet)
List every file you will create or modify and what each change does. Identify conflicts/risks. Stay focused on THIS task; if you find unrelated bugs, log them as separate GitHub issues — do not pivot.

$teams

## 4. Test before commit — fix ALL failures
$tests

Do NOT create a PR with failing tests or type errors.

## 5. Commit, push, PR
Use plain inline commit messages (no temp file, no backticks). Then:

``````
git add <the files you changed>
git commit -m "<type>($Name): <descriptive summary>"
git push -u origin $Branch
gh pr create --repo $repo --base $base --head $Branch --title "<type>($Name): <descriptive summary>" --body "<summary>.$closes"
``````

## 6. Signal completion
When the PR is open and tests pass, output EXACTLY:

``````
WORKTREE_STATUS: COMPLETE
PR: <url>
TESTS_PASSED: <yes/no + one-line details>
``````

If you hit a blocker you cannot resolve, output:

``````
WORKTREE_STATUS: BLOCKED
REASON: <one-line reason>
``````

Rules: no unsolicited doc files; no em dashes in user-facing strings; standard inline ``git commit -m`` only.
"@
}

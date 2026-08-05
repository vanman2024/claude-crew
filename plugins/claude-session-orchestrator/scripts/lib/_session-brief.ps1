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

# CLI-aware task-list tool name. Claude Code's `TodoWrite` was REPLACED by the
# TaskCreate/TaskUpdate task tools, so naming TodoWrite makes the worker burn its first
# turn discovering the tool does not exist and re-planning (observed live on #843).
# Codex uses its own plan tool. -Plain drops the markdown for plain-text nudges.
function Get-TaskToolName {
    param([string]$WorkerCli = 'claude', [switch]$Plain)

    switch ($WorkerCli) {
        'codex'  { if ($Plain) { 'update_plan' }        else { 'your plan tool (`update_plan`)' } }
        'claude' { if ($Plain) { 'TaskCreate/TaskUpdate' } else { 'the `TaskCreate` / `TaskUpdate` task tools' } }
        default  { if ($Plain) { 'your task-list tool' }   else { 'your task/todo-list tool' } }
    }
}

# Task size classes, smallest first. The whole roster is unconditional without this:
# a one-line fix would pull every design skill, the full agent fan-out, contract tests,
# browser verification and a post-PR review. Ceremony has to scale with blast radius.
$script:SizeOrder = @{ 'S' = 0; 'M' = 1; 'L' = 2 }

# Is $Entry required for a task of size $Size? `required: true` means always (S+);
# `requiredFrom: "M"` means required only once the task is at least that size.
function Test-RosterRequired {
    param($Entry, [string]$Size = 'S')
    if (-not $Entry.requiredFrom) { return $false }
    return ($script:SizeOrder[$Size] -ge $script:SizeOrder[$Entry.requiredFrom])
}

# Normalize one config.teams roster entry (an agent or a skill) to a single shape.
# A project may declare either form, and BOTH stay supported forever:
#   "nextjs-frontend:component-builder-agent"                          (bare name)
#   { "name": "...", "owns": "...", "when": "...", "phase": "after",
#     "required": true | "requiredFrom": "M" }                         (annotated)
# The bare form is what existing projects already have on disk, so it must keep
# rendering exactly as before - only the annotated form gets the extra columns.
# NOTHING here is project-specific: the plugin renders whatever the project declares.
function ConvertTo-RosterEntry {
    param($Entry, [ValidateSet('agent', 'skill')][string]$Kind)

    # Default phase by kind: agents build, skills inform the build beforehand. A lane
    # that reviews/validates (testing, review) overrides with an explicit phase, which
    # is why agents carry `phase` too - a security scanner is not a build step.
    $defaultPhase = if ($Kind -eq 'agent') { 'build' } else { 'before' }
    $e = [pscustomobject]@{ name = ''; kind = $Kind; owns = $null; when = $null; requiredFrom = $null; phase = $defaultPhase }
    if ($Entry -is [string]) { $e.name = $Entry; return $e }

    $props = $Entry.PSObject.Properties.Name
    if ($props -contains 'name')  { $e.name  = [string]$Entry.name }
    if ($props -contains 'owns')  { $e.owns  = [string]$Entry.owns }
    if ($props -contains 'when')  { $e.when  = [string]$Entry.when }
    if ($props -contains 'phase') { $e.phase = [string]$Entry.phase }
    # `required: true` = required at every size. `requiredFrom: "M"` = only from M up.
    # requiredFrom wins when both are set.
    if (($props -contains 'required') -and [bool]$Entry.required) { $e.requiredFrom = 'S' }
    if (($props -contains 'requiredFrom') -and $Entry.requiredFrom) {
        $rf = ([string]$Entry.requiredFrom).ToUpper()
        if ($script:SizeOrder.ContainsKey($rf)) { $e.requiredFrom = $rf }
    }
    return $e
}

# One roster line: (Tool) `name` — owns `path` — REQUIRED — when.
# Annotations are appended only when the project declared them, so a bare-string
# roster still renders as a plain backticked name and old briefs do not change.
# -ShowTool prefixes the tool to use; only needed where a phase mixes agents+skills.
function Format-RosterLine {
    param([Parameter(Mandatory)]$Entry, [switch]$ShowTool)

    $bt = [char]96
    $line = ''
    if ($ShowTool) { $line += if ($Entry.kind -eq 'agent') { '(Task) ' } else { '(Skill) ' } }
    $line += "$bt$($Entry.name)$bt"
    if ($Entry.owns) { $line += " — owns $bt$($Entry.owns)$bt" }
    if ($Entry.requiredFrom -eq 'S') { $line += " — **REQUIRED**" }
    elseif ($Entry.requiredFrom)     { $line += " — **REQUIRED for $($Entry.requiredFrom)+**" }
    if ($Entry.when) { $line += " — $($Entry.when)" }
    return $line
}

# Render the agent-team / file-lane section from config.teams. Returns '' when no
# teams are declared (project falls back to a generic single-Claude build flow).
function Format-TeamsSection {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$WorkerCli = 'claude'
    )

    # The config.teams agents/skills are Claude Code plugin subagents (subagent_type
    # names). A non-Claude worker (e.g. Codex) has no such system, so for it we keep the
    # file-lane discipline but drop the "use these exact agents / BLOCKED if missing"
    # mandate - otherwise the worker correctly blocks on agents it can never have.
    $isClaude = ($WorkerCli -eq 'claude')

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
    if ($isClaude) {
        [void]$sb.AppendLine("## MANDATORY: use the SPECIALIZED agents + skills for this project — NEVER ``general-purpose`` for build work")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Split work by ROLE / FILE-LANE, not by feature-slice. Each lane below owns disjoint paths so parallel agents do not collide.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("#### FIRST: size this task (S / M / L) — the protocol scales with it")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Ceremony must match blast radius. Running the whole roster on a one-line fix wastes an hour; skipping it on a cross-lane change ships a broken seam. State your size call in your plan with one line of reasoning, then follow that row:")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("- **S** — ONE lane, no new surface, no contract change (bug fix, null check, copy, refactor inside a file). Build it YOURSELF: no agent fan-out. Scoped unit tests + typecheck, then the pre-PR review, then the PR. SKIP everything marked M+ or L.")
        [void]$sb.AppendLine("- **M** — touches 2+ lanes, or changes an API contract, or adds an endpoint/route. Full lane fan-out, the seam agent, contract test, and browser verification.")
        [void]$sb.AppendLine("- **L** — new user-visible surface, or a new data model / migration. Everything in M, plus the design skills and an end-to-end pass on the new flow.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Lane span is OBJECTIVE, not a judgement call: if the change spans two lanes it is at least M, whatever it feels like. When genuinely torn between two sizes, pick the larger one.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("**Seed your task list ($(Get-TaskToolName -WorkerCli $WorkerCli)) with ONE entry per REQUIRED item at YOUR size, in every lane this task touches** — before you build. A REQUIRED item you judge not to apply must be named in your plan with a one-line reason; do NOT silently skip it. This is how the orchestrator sees which lanes you actually ran.")
    } else {
        [void]$sb.AppendLine("## Work by ROLE / FILE-LANE (path ownership)")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Split work by ROLE / FILE-LANE, not by feature-slice. Each lane below owns disjoint paths - stay inside the lane(s) this task belongs to so parallel workers do not collide. After building, run an API-contract check (frontend fetch types == route types == backend models; no drift, no dead endpoints).")
    }
    [void]$sb.AppendLine("")

    foreach ($teamName in $Config.teams.PSObject.Properties.Name) {
        $team = $Config.teams.$teamName
        $lane = "### Lane: $teamName"
        if (($team.PSObject.Properties.Name -contains "ownsPaths") -and $team.ownsPaths) {
            $lane += " — owns " + ((($team.ownsPaths) | ForEach-Object { '`' + $_ + '`' }) -join ', ')
        }
        [void]$sb.AppendLine($lane)
        if ($isClaude) {
            $roster = @()
            if (($team.PSObject.Properties.Name -contains "agents") -and $team.agents) {
                $roster += @($team.agents | ForEach-Object { ConvertTo-RosterEntry $_ -Kind 'agent' })
            }
            if (($team.PSObject.Properties.Name -contains "skills") -and $team.skills) {
                $roster += @($team.skills | ForEach-Object { ConvertTo-RosterEntry $_ -Kind 'skill' })
            }
            # Group by PHASE, not by kind, so the lane reads as an ORDER: what to consult
            # before writing code, what to build with, what to validate after. A review or
            # testing lane is mostly 'after' - including its agents - so the after-phase
            # can mix agents and skills and marks the tool per line.
            $pre    = @($roster | Where-Object { $_.phase -eq 'before' })
            $build  = @($roster | Where-Object { $_.phase -eq 'build' })
            $post   = @($roster | Where-Object { $_.phase -eq 'after' })
            # 'post-pr' is its own phase because some reviewers operate on the PR itself
            # (gh pr diff / gh pr view) and cannot run until the PR exists - lumping them
            # into 'after' would tell the worker to run them before it has opened one.
            $postPr = @($roster | Where-Object { $_.phase -eq 'post-pr' })

            # Number the phases that this lane ACTUALLY has, so a lane with only agents
            # reads "1. BUILD" rather than a lone "2." with no 1 or 3 around it.
            $step = 0
            if ($pre.Count -gt 0) {
                $step++
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("**$step. BEFORE writing code — invoke via the Skill tool:**")
                foreach ($s in $pre) { [void]$sb.AppendLine("    - " + (Format-RosterLine $s)) }
            }
            if ($build.Count -gt 0) {
                $step++
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("**$step. BUILD — launch these in a SINGLE message (Task tool), using these exact ``subagent_type`` names:**")
                foreach ($a in $build) { [void]$sb.AppendLine("    - " + (Format-RosterLine $a)) }
            }
            if ($post.Count -gt 0) {
                $step++
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("**$step. AFTER the build — validate BEFORE opening the PR:**")
                foreach ($s in $post) { [void]$sb.AppendLine("    - " + (Format-RosterLine $s -ShowTool)) }
            }
            if ($postPr.Count -gt 0) {
                $step++
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("**$step. AFTER the PR is open — these review the PR itself:**")
                foreach ($s in $postPr) { [void]$sb.AppendLine("    - " + (Format-RosterLine $s -ShowTool)) }
                [void]$sb.AppendLine("    Address anything they flag with high confidence, push the fix, and note it in the PR before signalling COMPLETE.")
            }
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("**Hard rules (non-negotiable):**")
    if ($isClaude) {
        [void]$sb.AppendLine("- Do NOT use ``general-purpose`` for build work when a specialized agent is configured for that lane.")
        [void]$sb.AppendLine("- Launch independent agents in a SINGLE message so they run concurrently.")
        [void]$sb.AppendLine("- Skills are INSTRUCTIONS, not an inventory: actually invoke each one via the Skill tool at the phase it is listed under.")
        [void]$sb.AppendLine("- When a task touches MORE THAN ONE lane, the agent that owns the seam between them (the route / proxy / contract layer) is REQUIRED — building the two lanes and leaving them unconnected is an incomplete task.")
        [void]$sb.AppendLine("- If a needed specialized agent is NOT available in this environment, print ``BLOCKED: <agent> unavailable`` and stop — do NOT silently fall back to ``general-purpose``.")
    } else {
        [void]$sb.AppendLine("- Respect the path ownership above: only edit files in the lane(s) this task belongs to; do not touch another lane's paths.")
        [void]$sb.AppendLine("- Build directly with your own capabilities. The ``subagent_type`` names and skills used in Claude briefs are Claude-specific and are NOT available to you - do NOT wait for them or print BLOCKED about a missing Claude agent.")
        [void]$sb.AppendLine("- You MAY use your own native subagents (e.g. explorer / worker) for parallel exploration, but it is not required.")
    }
    return $sb.ToString()
}

# Render the data-flow map section. A project MAY declare config.dataFlow as the
# canonical map (a string, or an object with entities/flows/notes). When declared,
# it is injected into EVERY worker brief as a shared contract so parallel lanes do
# not each invent their own version of the same entity. When absent, the worker is
# told to produce a quick map itself before planning.
function Format-DataFlowSection {
    param([Parameter(Mandatory)]$Config)

    $rails = @"
**Rails (non-negotiable):** generate code that strictly follows this map. Do NOT
introduce new entities, state, or flows unless THIS task explicitly requires them.
REUSE existing entities/types/services — never create a second version of something
that already exists (no ``OrderV2`` beside ``Order``, no parallel ``UserData`` beside
``User``). If the task genuinely needs a new entity or flow, name it in your plan and
say why BEFORE writing it.
"@

    if (-not ($Config.PSObject.Properties.Name -contains "dataFlow") -or $null -eq $Config.dataFlow) {
        return @"
Before you plan, write a 60-second data-flow map for THIS task — not a giant
architecture doc. Ground it in entities that ALREADY exist in the codebase (you
explored in step 1). Capture four things:
- **Entities** — the main objects this task touches (reuse existing ones by name).
- **Source** — where the data comes from (request, queue, DB, external API).
- **Destination** — where it goes (DB table, response, event, notification).
- **Transforms** — what changes at each hop.

Example shape: ``user creates order -> order triggers payment -> payment updates DB -> notification sends receipt``.

$rails
"@
    }

    $df = $Config.dataFlow
    $body = New-Object System.Text.StringBuilder
    [void]$body.AppendLine("This project declares a CANONICAL data-flow map. It is the shared contract for")
    [void]$body.AppendLine("every lane — all agents build against THESE entities and flows, not invented ones:")
    [void]$body.AppendLine("")

    if ($df -is [string]) {
        [void]$body.AppendLine($df)
    } else {
        if (($df.PSObject.Properties.Name -contains "entities") -and $df.entities) {
            [void]$body.AppendLine("**Entities:** $((($df.entities) -join ', '))")
        }
        if (($df.PSObject.Properties.Name -contains "flows") -and $df.flows) {
            [void]$body.AppendLine("**Flows:**")
            foreach ($f in $df.flows) { [void]$body.AppendLine("- $f") }
        }
        if (($df.PSObject.Properties.Name -contains "notes") -and $df.notes) {
            [void]$body.AppendLine("")
            [void]$body.AppendLine([string]$df.notes)
        }
    }
    [void]$body.AppendLine("")
    [void]$body.AppendLine($rails)
    return $body.ToString()
}

# Render the test-command block from config.layout. Workers run ONLY the unit tests that
# cover their change + the typecheck; the FULL Backend/Frontend suites run in GitHub Actions
# CI on the PR (running them locally is slow, redundant, and can hang on integration tests).
function Format-TestSection {
    param([Parameter(Mandatory)]$Config)
    $cmds = Get-TestCommands -Config $Config

    $guidance = @"
**Run ONLY the unit tests that cover your change - NOT the full test suite.** The full
Backend and Frontend suites run in GitHub Actions CI on every PR, so running them locally is
slow, redundant, and can hang on integration tests that need live services. Your LOCAL gate
is: the relevant UNIT tests for the files you changed (scope the runner to those specific
test files/modules) PLUS the typecheck. Do NOT run the whole suite to prove it - CI does that.
"@

    if (-not $cmds -or @($cmds).Count -eq 0) {
        return $guidance + "`n`nUse this project's test runner + typecheck, SCOPED to your change. Do NOT open a PR with failing unit tests or type errors."
    }

    $lines = @()
    foreach ($c in $cmds) {
        $lines += "- **$($c.name)** tooling (SCOPE the test run to your change - pass the specific test path/pattern, do NOT run it whole): ``$($c.cmd)``"
    }
    return $guidance + "`n`nProject test tooling:`n" + ($lines -join "`n") + "`n`nDo NOT open a PR with failing unit tests or type errors. A scoped green run + typecheck is enough; the full Backend/Frontend suites run in CI on the PR."
}

# Render the work-type + spec section (section 0 of every brief). There are exactly
# TWO work types: 'feature' (a new build, spec is the source of truth) and 'iteration'
# (a change to existing code, spec is context/reference). -Spec is an OPTIONAL
# repo-relative path to the authoritative spec for this work.
function Format-WorkTypeSection {
    param(
        [Parameter(Mandatory)][ValidateSet('feature', 'iteration')][string]$Mode,
        [string]$Spec
    )
    if ($Mode -eq 'feature') {
        if ($Spec) {
            return @"
## 0. Work type: NEW FEATURE - build to the spec (READ THIS FIRST)
This is a NEW FEATURE. Its spec is the SOURCE OF TRUTH: read ``$Spec`` IN FULL before you
plan, and build to it. Every change must trace back to the spec. If the spec is unclear,
incomplete, or conflicts with the codebase, say so in your plan BEFORE building - do not
invent behavior the spec does not describe.
"@
        }
        return @"
## 0. Work type: NEW FEATURE - needs a spec (READ THIS FIRST)
This is a NEW FEATURE but no spec path was provided. New features should be spec-driven.
If a spec exists for this area, find and read it (look under ``specs/``). If none exists,
write a SHORT spec first (problem, entities/data-flow, surfaces, acceptance criteria),
put it in your plan, and confirm direction before building straight through.
"@
    }
    if ($Spec) {
        return @"
## 0. Work type: ITERATION - change existing code (READ THIS FIRST)
This is an ITERATION on an existing feature, NOT a new build. Make ONLY the change this
task/issue describes; do not rebuild or re-architect. Read ``$Spec`` for CONTEXT on how the
feature is meant to work, but treat it as REFERENCE - the existing code is the baseline.
Explore the current implementation first, then make the focused change.
"@
    }
    return @"
## 0. Work type: ITERATION - change existing code (READ THIS FIRST)
This is an ITERATION on an existing feature, NOT a new build. Make ONLY the change this
task/issue describes; do not rebuild or re-architect. Explore the current implementation
first (and any relevant ``specs/`` or ``docs/`` for this feature), then make the focused change.
"@
}

# Build the full worker brief markdown.
#   -Task is the freeform body (issue body, spec pointer, feature description).
#   -Mode is 'feature' or 'iteration' (defaults: 'iteration' when -IssueNumber is set,
#   else 'feature'). -Spec is an optional repo-relative path to the authoritative spec.
# Render the "actually run it and look at it" step. A green unit suite proves nothing
# about a user-visible change: the #1 observed failure is a worker that builds both
# lanes, passes every scoped test, and opens a PR without ever loading the page - so a
# silent API failure rendering mock data ships looking green.
#
# The plugin does NOT hardcode a browser tool. A project declares `config.browserVerify`
# and the brief renders THAT tool's own recipe; projects that declare nothing get the
# generic mandate with no invented commands.
#   "browserVerify": {
#     "tool": "/browse", "required": true,
#     "recipe": ["$B goto {url}", "$B network", ...]     // {url} = the frontend URL
#   }
function Format-BrowserVerifySection {
    param([Parameter(Mandatory)]$Config)

    $bv = $null
    if (($Config.PSObject.Properties.Name -contains 'browserVerify') -and $Config.browserVerify) { $bv = $Config.browserVerify }

    $tool = 'a real browser'
    if ($bv -and ($bv.PSObject.Properties.Name -contains 'tool') -and $bv.tool) { $tool = [string]$bv.tool }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("### MANDATORY for any user-visible change: RUN IT and LOOK AT IT")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("A green unit suite and a clean typecheck do NOT prove a user-visible change works. If your task touches a page, a component, or an endpoint a page calls, you MUST start the throwaway servers above, open the affected surface in $tool, and confirm the REAL values render. ""The tests pass"" is not evidence; an observation is.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Watch specifically for the failure that unit tests cannot see: the API call fails and the page silently renders placeholder / mock / fallback data anyway. That looks identical to success in a screenshot - it is only visible in the NETWORK log.")

    # Two shapes, because browser tools come in two shapes. `recipe` is shell lines
    # (a CLI like browse) and renders code-fenced; `steps` is an ordered prose list
    # (a tool/MCP-driven flow, where code-fencing tool names would be misleading).
    # A project may declare either or both.
    if ($bv -and ($bv.PSObject.Properties.Name -contains 'steps') -and $bv.steps) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Do this, in order ({url} = the frontend URL the dev-server printed):")
        $n = 0
        foreach ($s in $bv.steps) { $n++; [void]$sb.AppendLine("$n. $([string]$s)") }
    }
    if ($bv -and ($bv.PSObject.Properties.Name -contains 'recipe') -and $bv.recipe) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Use this project's browser tool ({url} = the frontend URL the dev-server printed):")
        [void]$sb.AppendLine('``````')
        foreach ($line in $bv.recipe) { [void]$sb.AppendLine([string]$line) }
        [void]$sb.AppendLine('``````')
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Then record what you saw in the PR body and in your completion signal — the concrete observed value (""active users showed 1,284, matching the DB count""), not ""verified working"".")
    return $sb.ToString()
}

# Render the docs obligation. Docs are PROJECT-SHAPED: one repo keeps ADRs under
# docs/adr, another has a single README, a greenfield repo has nothing at all. So the
# key docs come from `config.docs.keyDocs` and nothing is hardcoded.
#
# The undeclared case matters most. A worker with no declared docs must NOT invent a
# documentation tree - inventing docs/architecture/ in a repo that never had one is
# noise a human then has to delete. It should infer structure from the code, and only
# update docs that ALREADY exist.
function Format-DocsSection {
    param([Parameter(Mandatory)]$Config)

    $docs = $null
    if (($Config.PSObject.Properties.Name -contains 'docs') -and $Config.docs) { $docs = $Config.docs }

    $keyDocs = @()
    if ($docs -and ($docs.PSObject.Properties.Name -contains 'keyDocs') -and $docs.keyDocs) { $keyDocs = @($docs.keyDocs) }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("## Docs: keep them TRUE, do not grow them")
    [void]$sb.AppendLine("")

    if ($keyDocs.Count -gt 0) {
        [void]$sb.AppendLine("This project declares these as its key docs:")
        foreach ($d in $keyDocs) { [void]$sb.AppendLine("- ``$d``") }
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("If your change makes any statement in them WRONG — a renamed endpoint, a changed contract, a removed flag, a new required env var — fix that statement in the same PR. A doc that describes the old behaviour is worse than no doc, because it is believed.")
    } else {
        [void]$sb.AppendLine("This project declares no key docs. So: **update docs that already exist and are made wrong by your change, and create NOTHING new.** Do not scaffold a docs tree, do not add architecture write-ups, do not leave a summary markdown file behind. If you believe something genuinely needs documenting, say so in one line in the PR body and let a human decide.")
    }

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Read before you write: infer the project's conventions from the code and the docs that exist, not from what a typical project would have.")
    return $sb.ToString()
}

function New-WorkerBrief {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Task,
        [int]$IssueNumber,
        [string]$Title,
        [ValidateSet('feature', 'iteration')][string]$Mode,
        [string]$Spec,
        [string]$WorkerCli = 'claude'
    )

    $teams    = Format-TeamsSection -Config $Config -WorkerCli $WorkerCli
    $dataflow = Format-DataFlowSection -Config $Config
    $tests    = Format-TestSection -Config $Config
    $browserVerify = Format-BrowserVerifySection -Config $Config
    $docsSection   = Format-DocsSection -Config $Config
    $base  = $Config.defaultBranch
    $repo  = $Config.githubRepo

    $closes = ""
    if ($PSBoundParameters.ContainsKey('IssueNumber') -and $IssueNumber) {
        $closes = " Closes #$IssueNumber"
    }
    $titleLine = if ($Title) { "**Task:** $Title`n" } else { "" }

    # Exactly two work types. Default: an issue-backed brief is an iteration; a plain
    # task brief is a new feature. Caller can override with -Mode.
    if (-not $Mode) {
        $Mode = if ($PSBoundParameters.ContainsKey('IssueNumber') -and $IssueNumber) { 'iteration' } else { 'feature' }
    }
    $workType = Format-WorkTypeSection -Mode $Mode -Spec $Spec

    # CLI-aware task-list tool name — see Get-TaskToolName for why this is not hardcoded.
    $taskTool = Get-TaskToolName -WorkerCli $WorkerCli

    return @"
# Worktree brief: $Name

You are a worker in an isolated git worktree on branch ``$Branch`` for project **$($Config.projectName)**. An orchestrator is watching this psmux pane and will steer you. You are autonomous and running with --dangerously-skip-permissions: plan first, then build straight through to a PR. Do not stop to ask for permission or approval.

$titleLine

$workType

## 1. Orient (create your task list FIRST)
1. **Before anything else, create your task list with $taskTool — this is your FIRST action.** Do NOT defer it until "the plan is settled." Seed it now with the high-level steps and refine as you learn: orient + explore, map the data flow, settle the plan, build (per lane), test, open the PR. Exploration is WORK — track it with a task ``in_progress``; do NOT run a long grep/read phase with no list "because no code is written yet" (that is the #1 way workers drift).
2. Read ``CLAUDE.md`` (and any ``*/CLAUDE.md``) for project rules.
3. Confirm location: ``git branch --show-current`` should print ``$Branch`` and ``pwd`` should be this worktree.
4. Explore the relevant code before writing anything (use the Explore agent or read files directly) — with the explore task ``in_progress``.

## VERIFY the API before you build it - NEVER from memory
Before writing code against ANY framework / library / SDK / external service (Mastra, CATS, Multilead/Skylead, Unipile, Twilio, Supabase, Vercel AI SDK, shadcn, etc.), CONSULT its authoritative reference FIRST - its MCP docs server, its skill, or its installed docs (``node_modules/<pkg>/dist/docs``, or a ``.claude/skills/<name>``). Your training knowledge of these APIs is almost certainly STALE. Do NOT guess signatures, option names, import paths, or types.
- Look it up, THEN build to the verified API. One guessed call (e.g. passing a plain object where a ``RequestContext`` instance is required) compiles clean but breaks at runtime and is not caught until integration - which wastes the whole parallel run.
- If the needed reference is NOT available in this environment (the MCP server is not connected, the skill is not installed, the docs are not in ``node_modules``): do NOT improvise or build it how you think it should work. Output ``BLOCKED: need <reference> to build <what>`` and STOP - report back to the orchestrator and ask for that reference. Wait for it; do not proceed on a guess.

## 2. The task

$Task

## 3. Map the data flow (before you plan)
Structure comes first, speed second. Pin down how data moves through this task BEFORE writing code, so you (and every parallel lane) build against ONE set of entities instead of each inventing your own.

$dataflow

## 4. Plan first (do NOT write code yet)
List every file you will create or modify and what each change does. Each change must trace back to an entity/flow in the data-flow map above. Identify conflicts/risks. Stay focused on THIS task; if you find unrelated bugs, log them as separate GitHub issues — do not pivot.

### MANDATORY: keep the task list current the WHOLE build (this is how you stay on track)
You already created the seed list in step 1. As the plan firms, REFINE it into concrete per-file build steps — one item per step. Then maintain it the entire build:
- Exactly ONE task ``in_progress`` at a time; flip it to ``completed`` the instant it's done.
- Add new tasks as they surface (a missing dependency, a follow-up, a test to write) instead of holding them in your head.
- Re-read the list whenever you finish a step to pick the next one.
There is NO phase without a current task list — exploration and planning included. "I haven't written code yet" is NOT a reason to skip it. On a long autonomous run the task list is the only thing that keeps you from dropping steps or drifting.

$teams

## MANDATORY: Dev server + ports — NEVER kill a process by name
Claude Code itself, the orchestrator, the reviewer, and EVERY other worktree's dev server ALL run as ``node.exe``. A name-based or blanket kill therefore takes down the whole crew **and your own session** — this is the #1 way a worker accidentally kills everything.

- FORBIDDEN — never run any of these (they kill Claude Code): ``taskkill /IM node.exe``, ``taskkill /F /IM node``, ``Get-Process node | Stop-Process``, ``Stop-Process -Name node``, ``killall node``, ``pkill node``, or a blanket ``npx kill-port`` sweep across ports.

### To run the app: start THROWAWAY servers on free ports
Pick the case that matches YOUR task. In both, servers bind auto-picked FREE ports ABOVE the main ones (3001+/8001+), never the main 3000/8000, and MUST be stopped before the PR.

**Case A — frontend-only change (API contract unchanged):** share the main checkout's running backend (``http://localhost:8000``). Do NOT start your own backend. Start only a throwaway frontend with ``-AutoPort``:
``````
# read the AUTO_PORT / URL it prints — that is the URL you open in the browser
pwsh -NoProfile -File "`${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start -AutoPort -Dir "<this worktree>" -Config "<repo>/.claude/session-plugin.json"
# tear down when done (pass the SAME port it printed):
pwsh -NoProfile -File "`${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action stop -Port <fe port> -Dir "<this worktree>" -Config "<repo>/.claude/session-plugin.json"
``````

**Case B — your task CHANGES the backend:** the shared :8000 is the MAIN checkout's OLD code and can't serve your new endpoints/content, and you can't bind :8000. Run THIS branch's backend on its own free port, then point the frontend at it. The backend runner reuses the main venv and runs WITHOUT --reload (one process; --reload spawns children that crash/pile up):
``````
# 1. start the branch backend on a free port (8001, 8002, ...) — read its PORT
pwsh -NoProfile -File "`${CLAUDE_PLUGIN_ROOT}/scripts/server/backend-server.ps1" -Action start -AutoPort -Dir "<this worktree>" -Config "<repo>/.claude/session-plugin.json"
# 2. start the frontend pointed at YOUR backend (NOT shared :8000) via a runtime env override
pwsh -NoProfile -File "`${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action start -AutoPort -ApiUrl http://localhost:<be port> -Dir "<this worktree>" -Config "<repo>/.claude/session-plugin.json"
# ... now OPEN the frontend URL and verify (see the mandatory verification step below) ...
# 3. tear DOWN BOTH (backend first), passing the ports they printed:
pwsh -NoProfile -File "`${CLAUDE_PLUGIN_ROOT}/scripts/server/backend-server.ps1" -Action stop -Port <be port> -Dir "<this worktree>" -Config "<repo>/.claude/session-plugin.json"
pwsh -NoProfile -File "`${CLAUDE_PLUGIN_ROOT}/scripts/server/dev-server.ps1" -Action stop -Port <fe port> -Dir "<this worktree>" -Config "<repo>/.claude/session-plugin.json"
``````

$browserVerify
**Hard rules for throwaway servers (this is how the machine stays alive):**
- **Always STOP every server you start, before the PR.** Orphaned ``next``/``uvicorn`` processes pile up and will fry the box. Never leave one running "to be safe".
- **Leave a way back in.** Teardown is non-negotiable, but a human still has to review this. In the PR body, paste the EXACT start commands (with this worktree's path) so a reviewer can bring the same surface up in one step. Verified-then-torn-down with no relaunch instructions is not reviewable.
- **One of each, max.** Don't start a second frontend/backend "because the first didn't respond" — check ``-Action status`` first, read the log it points to, then reuse or stop+restart the SAME one.
- **Never use ``--reload`` or ``python main.py``.** ``--reload`` spawns a child that re-imports the app (crashes on Windows) and respawns endlessly; ``python main.py`` hard-binds :8000. The backend-server script already runs the safe single-process form — use it, don't hand-roll uvicorn.
- **Never persist a port or URL.** They are runtime flags ONLY. Do NOT write them into ``.env``, ``package.json``, ``next.config.*``, ``vercel.json``, or any committed file, and do NOT change the configured 3000/8000. A changed port/URL in a PR breaks everyone.
- Without ``-AutoPort`` the scripts bind the CONFIGURED port — use that ONLY in the main checkout, never in a worktree.
- If ONE specific port is stuck, free ONLY that single PID — never a sweep:
``````
pwsh -NoProfile -File "`${CLAUDE_PLUGIN_ROOT}/scripts/util/kill-port.ps1" -Port <port>
``````
- Touch ONLY your own worktree's server. NEVER "kill all servers" or kill by process name — if a port you need is held by another worktree, report it to the orchestrator; do not kill across worktrees.

## 5. Test before commit — run SCOPED unit tests (the full suite runs in CI)
$tests

## 6. Commit, push, PR
Use plain inline commit messages (no temp file, no backticks). Then:

``````
git add <the files you changed>
git commit -m "<type>($Name): <descriptive summary>"
git push -u origin $Branch
gh pr create --repo $repo --base $base --head $Branch --title "<type>($Name): <descriptive summary>" --body "<summary>.$closes"
``````

$docsSection
## 7. Signal completion
When the PR is open and tests pass, output EXACTLY:

``````
WORKTREE_STATUS: COMPLETE
PR: <url>
LANES: <which lanes you actually ran, e.g. frontend, backend, routing, testing, review>
REQUIRED_SKIPPED: <none | each REQUIRED agent/skill you did NOT run + why>
TESTS_PASSED: <yes/no + one-line details>
OBSERVED: <what you SAW when you ran it — the concrete value/behaviour, or "n/a: not user-visible">
``````

If you hit a blocker you cannot resolve, output:

``````
WORKTREE_STATUS: BLOCKED
REASON: <one-line reason>
``````

Rules: no unsolicited doc files; no em dashes in user-facing strings; standard inline ``git commit -m`` only.
"@
}

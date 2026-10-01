# check-worker-skills.ps1
#
# Did each worker actually RUN the skill its brief gave it? Read from the worker's Claude
# transcripts, not from its own report: the mechanicjobs page workers all signalled
# COMPLETE and 0 of 11 had invoked dev-lifecycle:page-web.
#
# Per worker:
#   Required - the skill in its brief ("## 0. Your skill: `/x`" in .claude-bootstrap.md),
#              plus anything passed with -Required
#   Missing  - required skills with no invocation in the transcript
#   Skills   - every Skill tool call and typed /slash command, with counts, in first-use order
#   Agents   - every Task/Agent subagent_type, with counts
#
# A required skill counts as run when its full name matches, or its bare name does
# ("page-web" matches "dev-lifecycle:page-web"). Codex workers have no Claude transcript
# and report NoTranscript.
#
# Usage:
#   check-worker-skills.ps1 -Config <repo>\.claude\session-plugin.json [-Name <worker>] [-Required a,b] [-Json]

param(
    [string]$Config,
    [string]$RepoPath,
    [string]$Name,
    [string[]]$Required = @(),
    # Where Claude Code keeps transcripts (default ~/.claude/projects).
    [string]$ProjectsDir,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

$wtBase   = [IO.Path]::GetFullPath($cfg.worktreesPath).TrimEnd('\')
$projects = if ($ProjectsDir) { $ProjectsDir } else { Join-Path $HOME ".claude\projects" }
$infra    = @("orchestrator", "reviewer", "review-checkout")

function Get-BriefSkill([string]$WorktreePath) {
    $brief = Join-Path $WorktreePath ".claude-bootstrap.md"
    if (-not (Test-Path $brief)) { return $null }
    foreach ($line in (Get-Content $brief -TotalCount 40)) {
        if ($line -match '^## 0\. Your skill: `/?([^`]+)`') { return $Matches[1] }
    }
    return $null
}

function Test-SkillRan([string]$Want, $Seen) {
    $bare = ($Want -split ':')[-1]
    foreach ($s in $Seen) {
        if ($s -eq $Want -or (($s -split ':')[-1]) -eq $bare) { return $true }
    }
    return $false
}

$workers = @()
foreach ($line in (git -C $cfg.repoPath worktree list --porcelain 2>$null)) {
    if ($line -match '^worktree (.+)$') {
        $p = [IO.Path]::GetFullPath(($Matches[1] -replace '/', '\')).TrimEnd('\')
        if ($p.StartsWith("$wtBase\", [StringComparison]::OrdinalIgnoreCase)) {
            $leaf = Split-Path $p -Leaf
            if ($infra -contains $leaf) { continue }
            if ($Name -and $leaf -ne $Name) { continue }
            $workers += [pscustomobject]@{ Name = $leaf; Path = $p }
        }
    }
}

$rows = foreach ($w in $workers) {
    # Claude Code keys a project's transcripts by its path with every non-alphanumeric
    # character turned into '-'.
    $slug = $w.Path -replace '[^A-Za-z0-9]', '-'
    $dir  = Join-Path $projects $slug

    $skills = [ordered]@{}
    $agents = [ordered]@{}
    $hasTranscript = Test-Path $dir
    if ($hasTranscript) {
        foreach ($f in (Get-ChildItem $dir -Filter *.jsonl -File | Sort-Object LastWriteTime)) {
            foreach ($raw in [IO.File]::ReadLines($f.FullName)) {
                $isTool = $raw.Contains('"tool_use"')
                $isCmd  = $raw.Contains('<command-name>')
                if (-not ($isTool -or $isCmd)) { continue }
                try { $ev = $raw | ConvertFrom-Json } catch { continue }
                if (-not ($ev.PSObject.Properties.Name -contains 'message') -or -not $ev.message) { continue }
                if (-not ($ev.message.PSObject.Properties.Name -contains 'content')) { continue }
                $content = $ev.message.content
                if ($isCmd -and $ev.type -eq 'user') {
                    $text = if ($content -is [string]) { $content } else { ($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n" }
                    foreach ($m in [regex]::Matches([string]$text, '<command-name>/?([^<\s]+)</command-name>')) {
                        $k = $m.Groups[1].Value; $skills[$k] = 1 + [int]$skills[$k]
                    }
                }
                if ($isTool -and $content -and -not ($content -is [string])) {
                    foreach ($c in $content) {
                        if (-not ($c.PSObject.Properties.Name -contains 'type') -or $c.type -ne 'tool_use') { continue }
                        $in = if ($c.PSObject.Properties.Name -contains 'input') { $c.input } else { $null }
                        if ($c.name -eq 'Skill' -and $in -and ($in.PSObject.Properties.Name -contains 'skill') -and $in.skill) {
                            $k = ([string]$in.skill) -replace '^/', ''; $skills[$k] = 1 + [int]$skills[$k]
                        } elseif ($c.name -in @('Task', 'Agent')) {
                            $k = if ($in -and ($in.PSObject.Properties.Name -contains 'subagent_type') -and $in.subagent_type) { [string]$in.subagent_type } else { 'general-purpose' }
                            $agents[$k] = 1 + [int]$agents[$k]
                        }
                    }
                }
            }
        }
    }

    $req = @()
    $briefSkill = Get-BriefSkill $w.Path
    if ($briefSkill) { $req += $briefSkill }
    $req += @($Required | Where-Object { $_ })
    $req = @($req | ForEach-Object { $_ -replace '^/', '' } | Select-Object -Unique)
    $missing = @($req | Where-Object { -not (Test-SkillRan $_ $skills.Keys) })

    [pscustomobject]@{
        Name         = $w.Name
        NoTranscript = -not $hasTranscript
        Required     = $req
        Missing      = $missing
        Skills       = @($skills.Keys | ForEach-Object { "$_ x$($skills[$_])" })
        Agents       = @($agents.Keys | ForEach-Object { "$_ x$($agents[$_])" })
    }
}

if ($Json) { @($rows) | ConvertTo-Json -Depth 4; return }

foreach ($r in $rows) {
    $state = if ($r.NoTranscript) { 'NO TRANSCRIPT' } elseif ($r.Missing.Count) { 'MISSING: ' + ($r.Missing -join ', ') } elseif ($r.Required.Count) { 'ok' } else { 'no required skill' }
    Write-Host ("== {0}  [{1}]" -f $r.Name, $state)
    Write-Host ("   required: " + $(if ($r.Required.Count) { $r.Required -join ', ' } else { '(none)' }))
    Write-Host ("   skills  : " + $(if ($r.Skills.Count) { $r.Skills -join ', ' } else { '(none)' }))
    Write-Host ("   agents  : " + $(if ($r.Agents.Count) { $r.Agents -join ', ' } else { '(none)' }))
}

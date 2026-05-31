# _session-config.ps1
#
# Shared config loader + path helpers for claude-session-orchestrator.
# Dot-source this from every script:
#
#     . (Join-Path $PSScriptRoot "_session-config.ps1")
#     $cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath
#
# Every project-specific value (repo path, worktrees path, psmux session,
# github repo, default branch, claude.cmd path, layout, teams) lives in the
# consuming project's `.claude/session-plugin.json`. NOTHING about RedAI /
# StaffHive / any concrete project is hardcoded here. See examples/.

Set-StrictMode -Version Latest

# --- Locate the config file ---------------------------------------------------
# Search order:
#   1. Explicit -Config path (if provided)
#   2. <RepoPath>\.claude\session-plugin.json (if -RepoPath provided)
#   3. Walk UP from the start dir (default: current location) looking for
#      .claude\session-plugin.json
function Find-SessionConfigPath {
    param(
        [string]$Config,
        [string]$RepoPath,
        [string]$Start
    )

    if ($Config) {
        if (Test-Path $Config) { return (Resolve-Path $Config).Path }
        throw "Config file not found at -Config path: $Config"
    }

    if ($RepoPath) {
        $candidate = Join-Path $RepoPath ".claude\session-plugin.json"
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        throw "No .claude\session-plugin.json under -RepoPath: $RepoPath"
    }

    if (-not $Start) { $Start = (Get-Location).Path }
    $dir = (Resolve-Path $Start).Path
    while ($dir) {
        $candidate = Join-Path $dir ".claude\session-plugin.json"
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }   # reached the drive root
        $dir = $parent
    }

    throw "Could not find .claude\session-plugin.json. Pass -Config <path>, pass -RepoPath <repo>, or run from inside a project that has been initialized with /session-init."
}

# --- Load + validate ----------------------------------------------------------
function Get-SessionConfig {
    param(
        [string]$Config,
        [string]$RepoPath,
        [string]$Start
    )

    $path = Find-SessionConfigPath -Config $Config -RepoPath $RepoPath -Start $Start

    try {
        $cfg = Get-Content $path -Raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse $path as JSON: $($_.Exception.Message)"
    }

    # Required scalar fields
    $required = @("projectName", "repoPath", "worktreesPath", "psmuxSession", "githubRepo", "defaultBranch", "workerCmdPath", "layout")
    foreach ($key in $required) {
        if (-not ($cfg.PSObject.Properties.Name -contains $key) -or $null -eq $cfg.$key) {
            throw "session-plugin.json is missing required field '$key' (config: $path)"
        }
    }
    if (-not ($cfg.layout.PSObject.Properties.Name -contains "type")) {
        throw "session-plugin.json layout is missing 'type' (expected 'root' or 'monorepo-split')"
    }
    if ($cfg.layout.type -notin @("root", "monorepo-split")) {
        throw "session-plugin.json layout.type must be 'root' or 'monorepo-split', got '$($cfg.layout.type)'"
    }

    # Stash the resolved config path so callers can report it.
    $cfg | Add-Member -NotePropertyName "_configPath" -NotePropertyValue $path -Force
    return $cfg
}

# --- Derived helpers ----------------------------------------------------------

# Repo-relative paths of env files to copy main -> worktree.
function Get-EnvFileMappings {
    param([Parameter(Mandatory)]$Config)
    $rels = @()
    if ($Config.layout.type -eq "root") {
        if ($Config.layout.PSObject.Properties.Name -contains "envFiles") {
            foreach ($f in $Config.layout.envFiles) { $rels += $f }
        }
    } else {
        foreach ($part in $Config.layout.parts) {
            if ($part.PSObject.Properties.Name -contains "envFiles") {
                foreach ($f in $part.envFiles) {
                    $rels += (Join-Path $part.path $f)
                }
            }
        }
    }
    # Normalize to backslash, dedupe
    return ($rels | ForEach-Object { $_ -replace '/', '\' } | Select-Object -Unique)
}

# Repo-relative dirs to JUNCTION from main -> worktree (node_modules etc).
function Get-NodeModuleMappings {
    param([Parameter(Mandatory)]$Config)
    $rels = @()
    if ($Config.layout.type -eq "root") {
        if (($Config.layout.PSObject.Properties.Name -contains "nodeModules") -and $Config.layout.nodeModules) {
            $rels += $Config.layout.nodeModules
        }
    } else {
        foreach ($part in $Config.layout.parts) {
            if (($part.PSObject.Properties.Name -contains "nodeModules") -and $part.nodeModules) {
                $rels += $part.nodeModules
            }
        }
    }
    return ($rels | ForEach-Object { $_ -replace '/', '\' } | Select-Object -Unique)
}

# Test commands the worker should run, with <repo> resolved to the MAIN repo
# (workers reuse main's installed deps / venv by absolute path; see psmux-dispatch).
# Returns an array of [pscustomobject]@{ name; cmd }.
function Get-TestCommands {
    param([Parameter(Mandatory)]$Config)
    $cmds = @()
    $repo = $Config.repoPath
    if ($Config.layout.type -eq "root") {
        if (($Config.layout.PSObject.Properties.Name -contains "testCmd") -and $Config.layout.testCmd) {
            $cmds += [pscustomobject]@{ name = $Config.projectName; cmd = ($Config.layout.testCmd -replace '<repo>', $repo) }
        }
    } else {
        foreach ($part in $Config.layout.parts) {
            if (($part.PSObject.Properties.Name -contains "testCmd") -and $part.testCmd) {
                $cmds += [pscustomobject]@{ name = $part.name; cmd = ($part.testCmd -replace '<repo>', $repo) }
            }
        }
    }
    return $cmds
}

# Absolute worktree path for a worker name.
function Get-WorktreePath {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name)
    return (Join-Path $Config.worktreesPath $Name)
}

# psmux target string "session:window".
function Get-PsmuxTarget {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name)
    return "$($Config.psmuxSession):$Name"
}

# Kebab-case slug from arbitrary text (issue titles etc).
function ConvertTo-SessionSlug {
    param([Parameter(Mandatory)][string]$Text, [int]$MaxLength = 40)
    $s = $Text.ToLower()
    $s = $s -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).TrimEnd('-') }
    if (-not $s) { $s = "task" }
    return $s
}

# --- Worker-CLI profiles ------------------------------------------------------
# The worker dispatch is data-driven: a profile tells psmux-dispatch how to launch
# the agent CLI in the pane and how to detect that it is ready.
#
#   name           : label
#   cmd            : launch command (falls back to config.workerCmdPath)
#   args           : launch args (string[])
#   clearEnv       : env vars to null in the pane before launch (string[])
#   acceptMatchAny : substrings that signal a first-run accept screen (matched
#                    against the pane text with ALL whitespace removed)
#   acceptSend     : key/string to send when an accept pattern matches
#   readyMatchAny  : substrings (whitespace-removed) that signal the REPL is ready
#   bootWaitSec    : fixed wait when there are NO accept/ready patterns
#
# Only 'claude' is verified (proven in the live e2e). 'generic' does a fixed-wait
# launch with no accept handshake. For other CLIs (Codex/Gemini/Qwen), supply a
# custom object in config.workerCli with that CLI's REAL patterns — we do not ship
# unverified prompt strings.
function Get-WorkerCliPreset {
    param([string]$Name)
    switch ($Name) {
        'claude' {
            [pscustomobject]@{
                name = 'claude'; cmd = $null
                args = @('--dangerously-skip-permissions')
                clearEnv = @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT')
                acceptMatchAny = @('Yes,Iaccept', 'No,exit'); acceptSend = '2'
                readyMatchAny = @('bypasspermissionson'); bootWaitSec = 12
            }
        }
        'generic' {
            [pscustomobject]@{
                name = 'generic'; cmd = $null
                args = @(); clearEnv = @()
                acceptMatchAny = @(); acceptSend = ''
                readyMatchAny = @(); bootWaitSec = 10
            }
        }
        default { $null }
    }
}

# Resolve the effective worker-CLI profile from config.workerCli, which may be:
#   - absent          -> 'claude' preset
#   - a string        -> that preset name
#   - an object       -> { preset?, cmd?, args?, clearEnv?, bootWaitSec?,
#                          accept{matchAny?,send?}, ready{matchAny?} } extending a preset
# cmd falls back to config.workerCmdPath.
function Get-WorkerCliProfile {
    param([Parameter(Mandatory)]$Config)

    $wc = $null
    if ($Config.PSObject.Properties.Name -contains 'workerCli') { $wc = $Config.workerCli }

    $presetName = 'claude'
    $override = $null
    if ($null -eq $wc) {
        $presetName = 'claude'
    } elseif ($wc -is [string]) {
        $presetName = $wc
    } else {
        if (($wc.PSObject.Properties.Name -contains 'preset') -and $wc.preset) { $presetName = $wc.preset }
        $override = $wc
    }

    $profile = Get-WorkerCliPreset $presetName
    if ($null -eq $profile) {
        throw "Unknown workerCli preset '$presetName' (known: claude, generic). For another CLI, use a workerCli OBJECT with explicit fields (cmd/args/clearEnv/accept/ready/bootWaitSec)."
    }

    if ($override) {
        if (($override.PSObject.Properties.Name -contains 'cmd') -and $override.cmd) { $profile.cmd = $override.cmd }
        if ($override.PSObject.Properties.Name -contains 'args') { $profile.args = @($override.args) }
        if ($override.PSObject.Properties.Name -contains 'clearEnv') { $profile.clearEnv = @($override.clearEnv) }
        if (($override.PSObject.Properties.Name -contains 'bootWaitSec') -and $override.bootWaitSec) { $profile.bootWaitSec = [int]$override.bootWaitSec }
        if ($override.PSObject.Properties.Name -contains 'accept') {
            $acc = $override.accept
            if ($acc -and ($acc.PSObject.Properties.Name -contains 'matchAny')) { $profile.acceptMatchAny = @($acc.matchAny) }
            if ($acc -and ($acc.PSObject.Properties.Name -contains 'send'))     { $profile.acceptSend = $acc.send }
        }
        if ($override.PSObject.Properties.Name -contains 'ready') {
            $rdy = $override.ready
            if ($rdy -and ($rdy.PSObject.Properties.Name -contains 'matchAny')) { $profile.readyMatchAny = @($rdy.matchAny) }
        }
    }

    if (-not $profile.cmd) { $profile.cmd = $Config.workerCmdPath }
    if (-not $profile.cmd) { throw "workerCli profile has no command: set config.workerCmdPath or workerCli.cmd" }

    return $profile
}


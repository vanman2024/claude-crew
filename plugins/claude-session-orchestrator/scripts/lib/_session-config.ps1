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


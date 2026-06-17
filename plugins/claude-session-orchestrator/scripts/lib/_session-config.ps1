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

# How worker worktrees get their node_modules. Config key `worktreeDeps`:
#   "junction" (default) - share the main checkout's node_modules via a junction
#                          (fast, low-disk; fine for build/test-only workers, but a
#                          second `next dev` collides on the shared dir).
#   "install"            - REAL per-worktree install (with pnpm, hardlinks from the
#                          global store, so cheap after the first). Needed when each
#                          worktree runs its own dev server / Playwright.
# Returns the lowercased mode string; unknown/absent values fall back to "junction".
function Get-WorktreeDepsMode {
    param([Parameter(Mandatory)]$Config)
    if (($Config.PSObject.Properties.Name -contains "worktreeDeps") -and $Config.worktreeDeps) {
        $mode = "$($Config.worktreeDeps)".ToLower()
        if ($mode -eq "install") { return "install" }
    }
    return "junction"
}

# Detect the install command from the lockfile present in $Dir (the dir holding
# package.json). Mirrors preview-server.ps1's Get-DetectedInstall.
function Get-DetectedInstallCmd {
    param([Parameter(Mandatory)][string]$Dir)
    if (Test-Path (Join-Path $Dir "pnpm-lock.yaml"))    { return "pnpm install" }
    if (Test-Path (Join-Path $Dir "yarn.lock"))         { return "yarn install" }
    if (Test-Path (Join-Path $Dir "package-lock.json")) { return "npm install" }
    return "pnpm install"
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

# --- Worktree provisioning (shared by ALL dispatchers) ------------------------
# Create/reuse a worker worktree, copy env files + .mcp.json from the main
# checkout, write the brief to .claude-bootstrap.md, and JUNCTION node_modules
# dirs (unless -SkipDeps). Both the interactive dispatcher (psmux-dispatch.ps1)
# and the headless one (dispatch-codex.ps1) call this so they provision
# IDENTICALLY and cannot drift (the .mcp.json copy was once added to only one).
# Returns the absolute worktree path.
function Initialize-WorkerWorktree {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Branch,
        [string]$BaseRef,
        [string]$BootstrapContent,
        [switch]$SkipDeps,
        [string]$LogTag = "worktree"
    )

    $RepoRoot = $Config.repoPath
    $WtPath   = Join-Path $Config.worktreesPath $Name
    if (-not $BaseRef) { $BaseRef = "origin/$($Config.defaultBranch)" }
    function _wtstep($m) { Write-Host "[$LogTag] $m" }

    # 1. Create or reuse the worktree off the base ref.
    if (Test-Path $WtPath) {
        _wtstep "Worktree already exists at $WtPath - reusing"
    } else {
        _wtstep "Fetching origin/$($Config.defaultBranch)"
        git -C $RepoRoot fetch origin $Config.defaultBranch *>&1 | Out-Null
        _wtstep "Creating worktree $WtPath on branch $Branch off $BaseRef"
        # NB: pipe git's output to Out-Null. Native stdout would otherwise leak into
        # this function's return pipeline and $WtPath would come back as an array
        # (git chatter + the path), poisoning every caller (e.g. codex ArgumentList).
        git -C $RepoRoot worktree add $WtPath -b $Branch $BaseRef *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            _wtstep "branch may already exist - retrying without -b"
            git -C $RepoRoot worktree add $WtPath $Branch *>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for $WtPath" }
        }
    }

    # 2. Copy env files (from config.layout) main -> worktree.
    foreach ($rel in (Get-EnvFileMappings -Config $Config)) {
        $src = Join-Path $RepoRoot $rel
        $dst = Join-Path $WtPath $rel
        if ((Test-Path $src) -and -not (Test-Path $dst)) {
            $dstDir = Split-Path $dst -Parent
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item $src $dst -Force
            _wtstep "Copied $rel -> worktree"
        }
    }

    # 3. Copy project .mcp.json (usually untracked, so NOT in the worktree checkout)
    # so the worker inherits the project's MCP servers. stdio servers (shadcn,
    # playwright, ...) work immediately; HTTP/OAuth servers still need headless auth.
    $mcpSrc = Join-Path $RepoRoot ".mcp.json"
    $mcpDst = Join-Path $WtPath ".mcp.json"
    if ((Test-Path $mcpSrc) -and -not (Test-Path $mcpDst)) {
        Copy-Item $mcpSrc $mcpDst -Force
        _wtstep "Copied .mcp.json -> worktree (project MCP servers)"
    }

    # 4. Write the brief to .claude-bootstrap.md (the ONLY file the worker is told to read).
    if ($BootstrapContent) {
        $bootstrapPath = Join-Path $WtPath ".claude-bootstrap.md"
        Set-Content -Path $bootstrapPath -Value $BootstrapContent -Encoding UTF8
        _wtstep "Wrote .claude-bootstrap.md"
    }

    # 5. Provision node_modules per the `worktreeDeps` config (default: "junction").
    #    "install" gives each worktree a REAL, independent node_modules so it can run
    #    its own dev server / Playwright; "junction" shares the main checkout's.
    $depsMode = Get-WorktreeDepsMode -Config $Config
    if (-not $SkipDeps) {
        foreach ($rel in (Get-NodeModuleMappings -Config $Config)) {
            $wtNm   = Join-Path $WtPath $rel
            $mainNm = Join-Path $RepoRoot $rel
            if ($depsMode -eq "install") {
                $pkgDir = Split-Path $wtNm -Parent   # dir holding package.json/lockfile
                if (-not (Test-Path (Join-Path $pkgDir "package.json"))) {
                    _wtstep "WARN: no package.json in '$pkgDir' - skipping install for '$rel'"
                    continue
                }
                # Detach any stale junction first so the install is REAL + independent
                # (rmdir removes the link, NOT the main checkout it points at).
                if (Test-Path $wtNm) {
                    $item = Get-Item $wtNm -Force
                    if ($item.LinkType) {
                        _wtstep "Detaching stale '$rel' junction before install"
                        cmd /c "rmdir `"$wtNm`"" | Out-Null
                    }
                }
                if (Test-Path $wtNm) {
                    _wtstep "'$rel' already installed in worktree - leaving as-is"
                } else {
                    $install = Get-DetectedInstallCmd -Dir $pkgDir
                    _wtstep "Installing '$rel' (real per-worktree, not junction): $install"
                    Push-Location $pkgDir
                    try {
                        # Redirect ALL install output to a log file. Otherwise the native
                        # stdout flows into this function's return pipeline and poisons
                        # $WtPath, silently breaking psmux window creation downstream.
                        cmd /c $install *> (Join-Path $pkgDir '.pnpm-install.log')
                        if ($LASTEXITCODE -ne 0) { throw "worktree dep install failed in '$pkgDir' ($install) - see .pnpm-install.log" }
                    } finally { Pop-Location }
                }
            } else {
                # junction mode (default, backward-compatible)
                if (-not (Test-Path $mainNm)) {
                    _wtstep "WARN: main checkout has no '$rel' - install deps in the main repo first, then re-dispatch"
                } elseif (Test-Path $wtNm) {
                    _wtstep "'$rel' already present in worktree - leaving as-is"
                } else {
                    $wtNmParent = Split-Path $wtNm -Parent
                    if (-not (Test-Path $wtNmParent)) { New-Item -ItemType Directory -Path $wtNmParent -Force | Out-Null }
                    _wtstep "Junctioning '$rel' from main checkout (no install)"
                    New-Item -ItemType Junction -Path $wtNm -Target $mainNm | Out-Null
                }
            }
        }
    }

    return $WtPath
}

# Resolve the Codex CLI command for headless dispatch (dispatch-codex.ps1).
# Order: explicit -CodexCmd, then config.codexCmdPath, then PATH (codex.cmd / codex).
# config.workerCmdPath is NOT used as a fallback: in a mixed session it points at
# the interactive worker (often claude.cmd), not Codex.
function Get-CodexCmd {
    param($Config, [string]$CodexCmd)

    if ($CodexCmd) {
        if (Test-Path $CodexCmd) { return $CodexCmd }
        throw "Codex CLI not found at -CodexCmd path: $CodexCmd"
    }
    if ($Config -and ($Config.PSObject.Properties.Name -contains 'codexCmdPath') -and $Config.codexCmdPath) {
        if (Test-Path $Config.codexCmdPath) { return $Config.codexCmdPath }
        throw "config.codexCmdPath does not exist: $($Config.codexCmdPath)"
    }
    foreach ($name in @('codex.cmd', 'codex')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    throw "Codex CLI not found. Pass -CodexCmd <path>, set config.codexCmdPath, or put 'codex' on PATH (npm i -g @openai/codex)."
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
# 'claude' and 'codex' are verified (captured from a live boot). 'generic' does a
# fixed-wait launch with no accept handshake. For other CLIs (Gemini/Qwen/…), supply
# a custom object in config.workerCli with that CLI's REAL patterns — we do not ship
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
        'codex' {
            # OpenAI Codex CLI. --dangerously-bypass-approvals-and-sandbox is the
            # analog of Claude's --dangerously-skip-permissions; --no-alt-screen is
            # REQUIRED so the TUI renders inline (alt-screen mode breaks capture-pane
            # scrollback in psmux/tmux). Each fresh worktree is a new path, so Codex
            # shows its per-directory "trust this directory" gate — answered with '1'
            # (Yes, continue). Ready when the REPL header / YOLO-mode line appears.
            [pscustomobject]@{
                name = 'codex'; cmd = $null
                args = @('--dangerously-bypass-approvals-and-sandbox', '--no-alt-screen')
                clearEnv = @()
                acceptMatchAny = @('Doyoutrustthecontents', 'Yes,continue'); acceptSend = '1'
                readyMatchAny = @('permissions:YOLOmode', '>_OpenAICodex'); bootWaitSec = 15
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
#   - a string        -> that preset name ('claude' | 'codex' | 'generic')
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
        throw "Unknown workerCli preset '$presetName' (known: claude, codex, generic). For another CLI, use a workerCli OBJECT with explicit fields (cmd/args/clearEnv/accept/ready/bootWaitSec)."
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


# preview-server.ps1
#
# ONE persistent "preview environment" that cycles PR branches for live human
# review. The LOCAL analog of the Vercel preview (Merge protocol) — for backend /
# full-stack PRs a Vercel preview can't exercise. Project-agnostic: every path /
# session / port comes from the consuming project's .claude/session-plugin.json
# (previewServer block; see Get-PreviewServerConfig in _session-config.ps1).
#
# Design (why this exists, vs. worker worktrees):
#   - WORKER worktrees junction node_modules from the main repo and never install,
#     so a second `next dev` against them would collide with the main repo's cache.
#   - The preview worktree gets REAL installs (pnpm + a python .venv) ONCE, so its
#     dev servers run safely ALONGSIDE the main repo's on DERIVED ports.
#   - Servers run as named psmux windows (preview-fe / preview-be) — persistent
#     across CLI calls, inspectable via capture-pane, killable by name. No daemon.
#   - NEVER binds the main devServer port. Frontend = devServer.port + portOffset,
#     backend = backendBasePort (default 8000) + portOffset.
#
# Actions:
#   start  <PR# | branch>  Ensure the preview worktree + real deps exist (install
#                          only if missing), checkout the branch, boot fe + be.
#   switch <PR# | branch>  Checkout the new branch in the SAME worktree; leave the
#                          servers running so they hot-reload. The iteration loop.
#   stop                   Kill the preview psmux windows + free the derived ports.
#   status                 Which branch is loaded + whether the servers are up.
#
# Usage:
#   preview-server.ps1 -Action start  -Ref 607  -Config C:\proj\.claude\session-plugin.json
#   preview-server.ps1 -Action switch -Ref fix/stripe-webhook
#   preview-server.ps1 -Action stop
#   preview-server.ps1 -Action status

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("start", "switch", "stop", "status")]
    [string]$Action,

    # PR number (resolved to its head branch via gh) or a branch name. Required
    # for start/switch; ignored for stop/status.
    [Parameter(Position = 0)]
    [string]$Ref,

    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath
$pv  = Get-PreviewServerConfig -Config $cfg

$Repo    = $cfg.repoPath
$Session = $cfg.psmuxSession
$WtPath  = $pv.worktreePath
$FeWin   = "preview-fe"
$BeWin   = "preview-be"
$KillPort = (Join-Path $PSScriptRoot "..\util\kill-port.ps1")

function Step($msg) { Write-Host "[preview] $msg" }

# --- helpers -----------------------------------------------------------------

# Resolve a PR number to its head branch (via gh); pass a branch name through.
function Resolve-PreviewBranch {
    param([Parameter(Mandatory)][string]$Ref)
    if ($Ref -match '^\d+$') {
        $branch = (gh pr view $Ref --repo $cfg.githubRepo --json headRefName -q .headRefName 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $branch) {
            throw "Could not resolve PR #$Ref via gh (repo $($cfg.githubRepo)). Pass a branch name instead."
        }
        return $branch.Trim()
    }
    return $Ref
}

# Run a command line in a directory and throw on a non-zero exit. cmd /c handles
# Windows .cmd shims (pnpm/npx/...) transparently.
function Invoke-InDir {
    param([string]$Dir, [string]$CommandLine)
    Push-Location $Dir
    try {
        cmd /c $CommandLine
        if ($LASTEXITCODE -ne 0) { throw "command failed (exit $LASTEXITCODE): $CommandLine" }
    } finally { Pop-Location }
}

# Detect the frontend install command from the lockfile present in $Dir.
function Get-DetectedInstall {
    param([string]$Dir)
    if (Test-Path (Join-Path $Dir "pnpm-lock.yaml"))     { return "pnpm install" }
    if (Test-Path (Join-Path $Dir "yarn.lock"))          { return "yarn install" }
    if (Test-Path (Join-Path $Dir "package-lock.json"))  { return "npm install" }
    return "pnpm install"
}

function Test-PsmuxSession { return [bool](psmux ls 2>$null | Select-String -SimpleMatch $Session) }
function Test-PsmuxWindow {
    param([string]$Win)
    return [bool](psmux list-windows -t $Session 2>$null | Select-String -SimpleMatch $Win)
}

# HTTP probe; returns the status code (int) or $null if nothing answers.
function Get-HttpStatus {
    param([int]$Port)
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        return [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode.value__ }
        return $null
    }
}

# Create the preview worktree once (detached at origin/<defaultBranch>) + copy env
# files so the servers have them. Subsequent branch moves go through Switch-Branch.
function Initialize-PreviewWorktree {
    if (Test-Path $WtPath) { Step "Preview worktree exists at $WtPath"; return }
    Step "Fetching origin/$($cfg.defaultBranch)"
    git -C $Repo fetch origin $cfg.defaultBranch *>&1 | Out-Null
    Step "Creating preview worktree $WtPath (detached at origin/$($cfg.defaultBranch))"
    git -C $Repo worktree add --detach $WtPath "origin/$($cfg.defaultBranch)" *>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed for $WtPath" }

    foreach ($rel in (Get-EnvFileMappings -Config $cfg)) {
        $src = Join-Path $Repo $rel
        $dst = Join-Path $WtPath $rel
        if ((Test-Path $src) -and -not (Test-Path $dst)) {
            $dstDir = Split-Path $dst -Parent
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item $src $dst -Force
            Step "Copied $rel -> preview worktree"
        }
    }
    $mcpSrc = Join-Path $Repo ".mcp.json"
    $mcpDst = Join-Path $WtPath ".mcp.json"
    if ((Test-Path $mcpSrc) -and -not (Test-Path $mcpDst)) { Copy-Item $mcpSrc $mcpDst -Force }
}

# Move the preview worktree to <branch>. Prefer a real local branch (so the user
# can commit/push fixes); fall back to detached origin/<branch> if that branch is
# already checked out in another worktree (git forbids two checkouts of one branch).
function Switch-Branch {
    param([Parameter(Mandatory)][string]$Branch)
    Step "Fetching origin/$Branch"
    git -C $WtPath fetch origin $Branch *>&1 | Out-Null
    git -C $WtPath checkout -B $Branch --track "origin/$Branch" *>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        git -C $WtPath checkout --detach "origin/$Branch" *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to checkout $Branch in the preview worktree" }
        Step "NOTE: checked out origin/$Branch DETACHED (the branch is checked out elsewhere)"
    }
}

# Install deps ONCE into the preview worktree: a REAL frontend install (not a
# junction) + a python venv. Skipped when already present.
function Initialize-PreviewDeps {
    if ($pv.frontendDir) {
        $feFull = Join-Path $WtPath $pv.frontendDir
        $nm     = Join-Path $feFull "node_modules"
        # A leftover junction (e.g. created by a worker run) must be detached so we
        # get a REAL, independent install — rmdir removes the link, not the target.
        if (Test-Path $nm) {
            $item = Get-Item $nm -Force
            if ($item.LinkType) { Step "Detaching stale node_modules junction"; cmd /c "rmdir `"$nm`"" | Out-Null }
        }
        if (-not (Test-Path $nm)) {
            $install = if ($pv.frontendInstallCmd) { $pv.frontendInstallCmd } else { Get-DetectedInstall $feFull }
            Step "Installing frontend deps (real, not junction): $install"
            Invoke-InDir -Dir $feFull -CommandLine $install
        } else {
            Step "Frontend node_modules present - skipping install"
        }
    }
    if ($pv.hasBackend) {
        $beFull   = Join-Path $WtPath $pv.backendDir
        $venvName = if ($pv.backendVenv) { $pv.backendVenv } else { ".venv" }
        $venvPath = Join-Path $beFull $venvName
        if (-not (Test-Path $venvPath)) {
            Step "Creating backend venv: $venvPath"
            Invoke-InDir -Dir $beFull -CommandLine "python -m venv `"$venvName`""
            $pip = Join-Path $venvPath "Scripts\pip.exe"
            $install = $pv.backendInstallCmd
            if (-not $install) {
                if (Test-Path (Join-Path $beFull "requirements.txt")) {
                    $install = "`"$pip`" install -r requirements.txt"
                } elseif ((Test-Path (Join-Path $beFull "pyproject.toml")) -or (Test-Path (Join-Path $beFull "setup.py"))) {
                    $install = "`"$pip`" install -e ."
                }
            }
            if ($install) { Step "Installing backend deps: $install"; Invoke-InDir -Dir $beFull -CommandLine $install }
            else { Step "WARN: no requirements.txt / pyproject.toml in $beFull and no previewServer.backend.installCmd - venv left empty" }
        } else {
            Step "Backend venv present - skipping install"
        }
    }
}

# Boot a dev server as a named psmux window rooted at $Dir, running $DevCmd.
function Start-PreviewWindow {
    param([string]$Win, [string]$Dir, [string]$DevCmd, [int]$Port)
    & $KillPort -Port $Port | Out-Null
    if (Test-PsmuxWindow $Win) { psmux kill-window -t "${Session}:${Win}" 2>$null }
    Step "Booting $Win in $Dir -> port $Port ($DevCmd)"
    psmux new-window -t $Session -n $Win -c $Dir
    # Send the command, then Enter separately (the call-operator form fractures
    # through send-keys; this mirrors psmux-dispatch.ps1's launch).
    psmux send-keys -t "${Session}:${Win}" $DevCmd
    Start-Sleep -Milliseconds 600
    psmux send-keys -t "${Session}:${Win}" Enter
}

function Get-LoadedBranch {
    if (-not (Test-Path $WtPath)) { return $null }
    $b = (git -C $WtPath rev-parse --abbrev-ref HEAD 2>$null)
    if ($b) { $b = $b.Trim() }
    if (-not $b -or $b -eq "HEAD") {
        $sha = (git -C $WtPath rev-parse --short HEAD 2>$null)
        if ($sha) { return "(detached) $($sha.Trim())" }
        return $null
    }
    return $b
}

# ============================================================
# ACTION: stop
# ============================================================
if ($Action -eq "stop") {
    foreach ($w in @($FeWin, $BeWin)) {
        if (Test-PsmuxWindow $w) { Step "Killing window $w"; psmux kill-window -t "${Session}:${w}" 2>$null }
    }
    & $KillPort -Port $pv.frontendPort | Out-Null
    if ($pv.hasBackend) { & $KillPort -Port $pv.backendPort | Out-Null }
    Write-Host "PREVIEW_STOPPED"
    Write-Host "FRONTEND_PORT=$($pv.frontendPort)"
    if ($pv.hasBackend) { Write-Host "BACKEND_PORT=$($pv.backendPort)" }
    exit 0
}

# ============================================================
# ACTION: status
# ============================================================
if ($Action -eq "status") {
    if (-not (Test-Path $WtPath)) {
        Write-Host "PREVIEW_NOT_INITIALIZED"
        Write-Host "WORKTREE=$WtPath"
        exit 0
    }
    $branch = Get-LoadedBranch
    $feUp = Test-PsmuxWindow $FeWin
    $feHttp = Get-HttpStatus $pv.frontendPort
    Write-Host "PREVIEW_STATUS"
    Write-Host "WORKTREE=$WtPath"
    Write-Host "BRANCH=$branch"
    Write-Host "FRONTEND_PORT=$($pv.frontendPort)"
    Write-Host "FRONTEND_WINDOW=$(if ($feUp) { 'up' } else { 'down' })"
    Write-Host "FRONTEND_HTTP=$(if ($null -ne $feHttp) { $feHttp } else { 'no-response' })"
    Write-Host "FRONTEND_URL=http://localhost:$($pv.frontendPort)"
    if ($pv.hasBackend) {
        $beUp = Test-PsmuxWindow $BeWin
        $beHttp = Get-HttpStatus $pv.backendPort
        Write-Host "BACKEND_PORT=$($pv.backendPort)"
        Write-Host "BACKEND_WINDOW=$(if ($beUp) { 'up' } else { 'down' })"
        Write-Host "BACKEND_HTTP=$(if ($null -ne $beHttp) { $beHttp } else { 'no-response' })"
        Write-Host "BACKEND_URL=http://localhost:$($pv.backendPort)"
    }
    exit 0
}

# start / switch both need a ref + psmux
if (-not $Ref) { Write-Error "Action '$Action' requires -Ref <PR# | branch>"; exit 1 }
if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) {
    Write-Error "psmux not found on PATH. Install/confirm psmux before running the preview env."; exit 1
}
$branch = Resolve-PreviewBranch -Ref $Ref
Step "Target branch: $branch"

# ============================================================
# ACTION: switch  (servers stay up; just move the branch)
# ============================================================
if ($Action -eq "switch") {
    if (-not (Test-Path $WtPath)) {
        Write-Error "Preview env not initialized. Run: preview-server.ps1 -Action start -Ref $Ref"; exit 1
    }
    Switch-Branch -Branch $branch
    $feUp = Test-PsmuxWindow $FeWin
    Write-Host "PREVIEW_SWITCHED"
    Write-Host "BRANCH=$(Get-LoadedBranch)"
    Write-Host "FRONTEND_PORT=$($pv.frontendPort)"
    Write-Host "FRONTEND_WINDOW=$(if ($feUp) { 'up' } else { 'down (run -Action start)' })"
    if ($pv.hasBackend) { Write-Host "BACKEND_PORT=$($pv.backendPort)" }
    Step "Servers left running - they should hot-reload onto $branch"
    exit 0
}

# ============================================================
# ACTION: start
# ============================================================
Initialize-PreviewWorktree
Switch-Branch -Branch $branch
Initialize-PreviewDeps

if (-not (Test-PsmuxSession)) { Step "Creating detached psmux session '$Session'"; psmux new -s $Session -d }

# Frontend
$feFull = if ($pv.frontendDir) { Join-Path $WtPath $pv.frontendDir } else { $WtPath }
Start-PreviewWindow -Win $FeWin -Dir $feFull -DevCmd $pv.frontendDevCmd -Port $pv.frontendPort

# Backend (only if a dev command is resolvable)
$beBooted = $false
if ($pv.hasBackend) {
    if ($pv.backendDevCmd) {
        $beFull = Join-Path $WtPath $pv.backendDir
        Start-PreviewWindow -Win $BeWin -Dir $beFull -DevCmd $pv.backendDevCmd -Port $pv.backendPort
        $beBooted = $true
    } else {
        Step "NOTE: backend present but previewServer.backend.devCmd is not set - booting frontend only. Set it (use {port}) to serve the backend."
    }
}

# Poll the frontend for readiness (max ~60s), like dev-server.ps1.
Step "Waiting for the frontend on port $($pv.frontendPort)..."
$ready = $false
Start-Sleep -Seconds 3
for ($i = 0; $i -lt 20; $i++) {
    $code = Get-HttpStatus $pv.frontendPort
    if ($null -ne $code -and $code -ge 200 -and $code -lt 400) { $ready = $true; break }
    Start-Sleep -Seconds 3
}

if ($ready) { Write-Host "PREVIEW_STARTED" } else { Write-Host "PREVIEW_STARTED_FRONTEND_NOT_READY" }
Write-Host "BRANCH=$(Get-LoadedBranch)"
Write-Host "WORKTREE=$WtPath"
Write-Host "FRONTEND_PORT=$($pv.frontendPort)"
Write-Host "FRONTEND_URL=http://localhost:$($pv.frontendPort)"
Write-Host "FRONTEND_WINDOW=${Session}:${FeWin}"
if ($beBooted) {
    Write-Host "BACKEND_PORT=$($pv.backendPort)"
    Write-Host "BACKEND_URL=http://localhost:$($pv.backendPort)"
    Write-Host "BACKEND_WINDOW=${Session}:${BeWin}"
}
Write-Host "ATTACH=psmux attach -t $Session"
if (-not $ready) {
    Step "Frontend did not answer yet - inspect: psmux capture-pane -t ${Session}:${FeWin} -p"
    exit 0
}
exit 0

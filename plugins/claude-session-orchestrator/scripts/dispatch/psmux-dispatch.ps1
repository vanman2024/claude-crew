# psmux-dispatch.ps1
#
# Full worktree dispatch using psmux (the Windows tmux port). Project-agnostic:
# every path / session / branch comes from the consuming project's
# .claude/session-plugin.json (see _session-config.ps1). Nothing is hardcoded.
#
# End to end:
#   1. Create a git worktree off origin/<defaultBranch> (or reuse a healthy one)
#   2. Copy env files (from config.layout) main -> worktree
#   3. JUNCTION node_modules dirs (from config.layout) from main (no install, no dup)
#   4. Write .claude-bootstrap.md at the worktree root with the brief
#   5. Ensure the psmux session, add a window for this worktree
#   6. Launch claude.cmd --dangerously-skip-permissions with the boot handshake
#   7. Send the bootstrap message so the worker starts
#
# This is the INTERACTIVE dispatch (attachable pane you can watch + send-keys to).
# For headless one-shot runs use dispatch-worktree.ps1 instead.
#
# Usage:
#   psmux-dispatch.ps1 -Name f036-international -Task "Build the international flow per specs/.../spec.md"
#   psmux-dispatch.ps1 -Name fix-510-foo -BootstrapFile path\to\brief.md -Branch fix/510-foo
#   psmux-dispatch.ps1 -Name f036 -Bootstrap "<brief md>" -Config C:\proj\.claude\session-plugin.json

param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    # Brief source (one of): inline markdown, a file, or a -Task to auto-generate
    # a brief (with the project's agent-team rules injected).
    [string]$Bootstrap,
    [string]$BootstrapFile,
    [string]$Task,
    [string]$Title,
    [int]$IssueNumber,

    # Config resolution (see _session-config.ps1)
    [string]$Config,
    [string]$RepoPath,

    # Overrides (default to config values)
    [string]$Session,
    [string]$BaseRef,
    [string]$Branch,

    # Skip dependency wiring (faster when reusing a warm worktree)
    [switch]$SkipDeps,

    # Seconds budget for the boot handshake before sending the brief anyway
    [int]$ClaudeBootWaitSec = 12
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
. (Join-Path $PSScriptRoot "..\lib\_session-brief.ps1")

$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

$RepoRoot  = $cfg.repoPath
$WtBase    = $cfg.worktreesPath
$WtPath    = Join-Path $WtBase $Name
# The worker CLI launch + boot handshake are data-driven (see Get-WorkerCliProfile).
$WorkerCli = Get-WorkerCliProfile -Config $cfg
$WorkerCmd = $WorkerCli.cmd
if (-not $Session) { $Session = $cfg.psmuxSession }
if (-not $BaseRef) { $BaseRef = "origin/$($cfg.defaultBranch)" }
if (-not $Branch)  { $Branch  = "feature/$Name" }

function Step($msg) { Write-Host "[psmux-dispatch] $msg" }

# --- 0. Resolve bootstrap content ---------------------------------------------
if ($BootstrapFile) {
    if (-not (Test-Path $BootstrapFile)) { Write-Error "BootstrapFile not found: $BootstrapFile"; exit 1 }
    $bootstrapContent = Get-Content $BootstrapFile -Raw
} elseif ($Bootstrap) {
    $bootstrapContent = $Bootstrap
} elseif ($Task) {
    $briefArgs = @{ Config = $cfg; Name = $Name; Branch = $Branch; Task = $Task }
    if ($Title) { $briefArgs.Title = $Title }
    if ($PSBoundParameters.ContainsKey('IssueNumber') -and $IssueNumber) { $briefArgs.IssueNumber = $IssueNumber }
    $bootstrapContent = New-WorkerBrief @briefArgs
} else {
    Write-Error "Provide -Task <desc>, -Bootstrap <text>, or -BootstrapFile <path>"; exit 1
}

# --- 1. Verify psmux + the worker CLI are available ---------------------------
if (-not (Get-Command psmux -ErrorAction SilentlyContinue)) {
    Write-Error "psmux not found on PATH. Install/confirm psmux before dispatching."; exit 1
}
if (-not (Test-Path $WorkerCmd)) {
    Write-Error "Worker CLI not found at $WorkerCmd (workerCli '$($WorkerCli.name)'; cmd from config.workerCmdPath or workerCli.cmd)"; exit 1
}

# --- 2. Create or reuse the worktree ------------------------------------------
if (Test-Path $WtPath) {
    Step "Worktree already exists at $WtPath - reusing"
} else {
    Step "Fetching $BaseRef"
    git -C $RepoRoot fetch origin $cfg.defaultBranch | Out-Null
    Step "Creating worktree $WtPath on branch $Branch off $BaseRef"
    git -C $RepoRoot worktree add $WtPath -b $Branch $BaseRef
    if ($LASTEXITCODE -ne 0) {
        Step "branch may already exist - retrying without -b"
        git -C $RepoRoot worktree add $WtPath $Branch
        if ($LASTEXITCODE -ne 0) { Write-Error "git worktree add failed"; exit 1 }
    }
}

# --- 3. Copy env files (from config.layout) -----------------------------------
foreach ($rel in (Get-EnvFileMappings -Config $cfg)) {
    $src = Join-Path $RepoRoot $rel
    $dst = Join-Path $WtPath $rel
    if ((Test-Path $src) -and -not (Test-Path $dst)) {
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item $src $dst -Force
        Step "Copied $rel -> worktree"
    }
}

# Copy project .mcp.json (usually untracked, so it is NOT in the worktree checkout)
# so the worker inherits the project's MCP servers. Command/stdio servers work as-is;
# HTTP/OAuth servers still need headless auth (e.g. a token), but stdio ones (shadcn,
# playwright, etc.) become available to the worker immediately.
$mcpSrc = Join-Path $RepoRoot ".mcp.json"
$mcpDst = Join-Path $WtPath ".mcp.json"
if ((Test-Path $mcpSrc) -and -not (Test-Path $mcpDst)) {
    Copy-Item $mcpSrc $mcpDst -Force
    Step "Copied .mcp.json -> worktree (project MCP servers)"
}

# --- 4. Write .claude-bootstrap.md --------------------------------------------
$bootstrapPath = Join-Path $WtPath ".claude-bootstrap.md"
Set-Content -Path $bootstrapPath -Value $bootstrapContent -Encoding UTF8
Step "Wrote .claude-bootstrap.md"

# --- 5. Wire up deps: JUNCTION node_modules from the main checkout ------------
# Proven pattern: junction, do NOT install. No install wait, no GB-scale dup per
# worktree. Backend (if any) uses the MAIN venv python by absolute path; there is
# no per-worktree venv.
if (-not $SkipDeps) {
    foreach ($rel in (Get-NodeModuleMappings -Config $cfg)) {
        $wtNm   = Join-Path $WtPath $rel
        $mainNm = Join-Path $RepoRoot $rel
        if (-not (Test-Path $mainNm)) {
            Step "WARN: main checkout has no '$rel' - install deps in the main repo first, then re-dispatch"
        } elseif (Test-Path $wtNm) {
            Step "'$rel' already present in worktree - leaving as-is"
        } else {
            $wtNmParent = Split-Path $wtNm -Parent
            if (-not (Test-Path $wtNmParent)) { New-Item -ItemType Directory -Path $wtNmParent -Force | Out-Null }
            Step "Junctioning '$rel' from main checkout (no install)"
            New-Item -ItemType Junction -Path $wtNm -Target $mainNm | Out-Null
        }
    }
}

# --- 6. Ensure psmux session + add window -------------------------------------
$sessionExists = (psmux ls 2>$null | Select-String -SimpleMatch "$Session")
if (-not $sessionExists) {
    Step "Creating detached psmux session '$Session'"
    psmux new -s $Session -d
}

$existingWindow = (psmux list-windows -t $Session 2>$null | Select-String -SimpleMatch $Name)
if ($existingWindow) {
    Step "Window '$Name' already exists - killing for clean redispatch"
    psmux kill-window -t "${Session}:${Name}" 2>$null
}

Step "Adding psmux window '$Name' rooted at $WtPath"
psmux new-window -t $Session -n $Name -c $WtPath

# --- 7. Launch the worker CLI, drive the boot handshake, send bootstrap -------
# All CLI-specific behavior comes from the resolved worker profile ($WorkerCli):
# clearEnv, launch args, and the accept/ready capture-pane patterns. Nothing here
# is hardcoded to a particular CLI. See Get-WorkerCliProfile in _session-config.ps1.
$target = "${Session}:${Name}"
$argLine    = ($WorkerCli.args -join ' ')
$launchLine = if ($argLine) { "$WorkerCmd $argLine" } else { "$WorkerCmd" }
Step "Launching worker CLI '$($WorkerCli.name)' in $target ($launchLine)"

# Clear inherited env vars FIRST (profile.clearEnv). For Claude this nulls
# CLAUDECODE/CLAUDE_CODE_ENTRYPOINT so the worker isn't treated as a nested
# sub-agent (which would disable its Task tool / agent-team spawning).
if ($WorkerCli.clearEnv.Count -gt 0) {
    $clearLine = ($WorkerCli.clearEnv | ForEach-Object { "`$env:$_=`$null" }) -join '; '
    psmux send-keys -t $target $clearLine
    Start-Sleep -Milliseconds 400
    psmux send-keys -t $target Enter
    Start-Sleep -Milliseconds 800
}

# Invoke the launcher by BARE path and send Enter SEPARATELY. The call-operator
# form (& "$cmd" --flag) fractures through send-keys and PowerShell errors.
psmux send-keys -t $target $launchLine
Start-Sleep -Seconds 1
psmux send-keys -t $target Enter

$hasPatterns = ($WorkerCli.acceptMatchAny.Count -gt 0) -or ($WorkerCli.readyMatchAny.Count -gt 0)
if ($hasPatterns) {
    Step "Waiting for '$($WorkerCli.name)' to be ready (auto-handling its accept screen if any)"
    $accepted = $false
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 3
        $pane = (psmux capture-pane -t $target -p 2>$null) -join "`n"
        $flat = ($pane -replace '\s', '')
        if (-not $accepted -and $WorkerCli.acceptMatchAny.Count -gt 0) {
            $hit = $false
            foreach ($pat in $WorkerCli.acceptMatchAny) { if ($flat.Contains($pat)) { $hit = $true; break } }
            if ($hit) {
                if ($WorkerCli.acceptSend) {
                    Step "Accept screen detected - sending '$($WorkerCli.acceptSend)'"
                    psmux send-keys -t $target $WorkerCli.acceptSend Enter
                }
                $accepted = $true
                continue
            }
        }
        if ($WorkerCli.readyMatchAny.Count -gt 0) {
            $rhit = $false
            foreach ($pat in $WorkerCli.readyMatchAny) { if ($flat.Contains($pat)) { $rhit = $true; break } }
            if ($rhit) { $ready = $true; Step "REPL ready after ~$([int](($i + 1) * 3))s"; break }
        }
    }
    if (-not $ready) { Step "WARN: did not positively detect the ready prompt; sending bootstrap anyway" }
} else {
    Step "Profile '$($WorkerCli.name)' has no accept/ready patterns - fixed boot wait $($WorkerCli.bootWaitSec)s"
    Start-Sleep -Seconds $WorkerCli.bootWaitSec
}

Step "Sending bootstrap message"
psmux send-keys -t $target "Read .claude-bootstrap.md in this worktree root and follow it exactly. You are an autonomous worker: plan first, then build straight through to a PR. Do not stop to ask for permission or approval." Enter

# A long paste can absorb its own trailing Enter into the input box instead of
# submitting. Send a standalone Enter to actually submit the prompt.
Start-Sleep -Seconds 2
psmux send-keys -t $target "" Enter

Step "DISPATCHED: $target  (attach with: psmux attach -t $Session)"
Write-Host "SESSION=$Session"
Write-Host "WINDOW=$Name"
Write-Host "TARGET=$target"
Write-Host "WORKTREE=$WtPath"
Write-Host "BRANCH=$Branch"



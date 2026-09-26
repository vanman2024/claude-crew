# backend-server.ps1
#
# THROWAWAY per-worktree BACKEND for full-stack verification. Symmetric to
# dev-server.ps1 (the frontend). A task that changes the backend can't verify
# against the shared main :8000 (that's the MAIN checkout's old code) and can't
# bind :8000 itself, so this runs THIS branch's backend on its own FREE port.
#
# Why it exists / the rules that keep it from frying the machine:
#   - Runs WITHOUT --reload. uvicorn's reloader spawns a child that re-imports the
#     app (a common Windows crash/segfault) and respawns pile up - the #1 cause of
#     "the backend won't start" and runaway background servers. One process, one PID.
#   - Binds a FREE port ABOVE the main backend port (8001, 8002, ...), never :8000.
#   - Reuses the MAIN checkout's venv python (no slow/flaky per-worktree pip install).
#   - Idempotent: a backend already serving THIS worktree's dir is reused, never
#     duplicated. ALWAYS stop it when done (-Action stop -Port <n>); teardown also
#     force-kills any server whose command line references the worktree path.
#
# Usage (run from / pointed at the worktree root via -Dir):
#   backend-server.ps1 -Action start  -AutoPort -Dir "<worktree>" -Config <cfg>
#   backend-server.ps1 -Action status -Port <n> -Dir "<worktree>" -Config <cfg>
#   backend-server.ps1 -Action stop   -Port <n> -Dir "<worktree>" -Config <cfg>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("start", "stop", "status")]
    [string]$Action,

    [int]$Port,

    # THROWAWAY: ignore the configured port and bind the first FREE port ABOVE the
    # main backend port. start-only; for stop/status pass the -Port it printed.
    [switch]$AutoPort,

    [string]$Dir = "",

    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath
$be  = Get-WorkerBackendConfig -Config $cfg

if (-not $be.hasBackend) {
    Write-Error "No backend configured. Add a 'backendServer' block or a monorepo-split layout part with 'pythonVenv' to session-plugin.json."
    exit 1
}

if (-not $Dir) { $Dir = (Get-Location).Path }
$backendDir = Join-Path $Dir $be.dir
if (-not (Test-Path $backendDir)) {
    Write-Error "Worktree backend dir not found: $backendDir"
    exit 1
}

# Reuse the MAIN checkout's venv python (the worktree has node_modules installed but
# not a python venv; main's venv already has every dep, so this is fast + reliable).
$mainPython = Join-Path $cfg.repoPath (Join-Path $be.dir (Join-Path $be.venv "Scripts\python.exe"))

# Default port = configured base; -AutoPort picks the first free port ABOVE it.
if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = $be.basePort }
if ($AutoPort) {
    if ($Action -eq "start") {
        $basePort = $Port
        $Port = Get-FreePort -BasePort ($basePort + 1) -Reserve @($basePort)
        Write-Host "AUTO_PORT=$Port (main backend port $basePort reserved + skipped; active ports skipped)"
    } else {
        Write-Warning "-AutoPort only applies to -Action start. For $Action pass the -Port the start step printed."
    }
}

function Get-ProcessOnPort {
    param([int]$CheckPort)
    $netstat = netstat -ano | Select-String "LISTENING" | Select-String ":$CheckPort\s"
    if ($netstat) {
        $line = $netstat[0].ToString().Trim()
        return [int](($line -split '\s+')[-1])
    }
    return $null
}
function Get-ProcessCommandLine {
    param([int]$ProcessId)
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if ($proc) { return $proc.CommandLine }
    } catch {}
    return ""
}
function Get-ChildProcesses {
    param([int]$ParentProcessId)
    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction SilentlyContinue
        if ($children) { return $children.ProcessId }
    } catch {}
    return @()
}
# FastAPI always serves /openapi.json; treat ANY HTTP response (even 404) as "up".
function Get-HttpAlive {
    param([int]$CheckPort)
    foreach ($path in @("/openapi.json", "/")) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$CheckPort$path" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
            if ($r.StatusCode) { return $true }
        } catch {
            if ($_.Exception.Response) { return $true }  # responded with an HTTP error => up
        }
    }
    return $false
}

# ============================================================
# ACTION: start
# ============================================================
if ($Action -eq "start") {
    if (-not (Test-Path $mainPython)) {
        Write-Error "Main backend venv python not found: $mainPython`nCreate the MAIN checkout's backend venv + install deps first, then retry."
        exit 1
    }

    # Idempotent: reuse a backend already serving THIS worktree's backend dir.
    $existingPid = Get-ProcessOnPort -CheckPort $Port
    if ($existingPid) {
        $cmdLine = Get-ProcessCommandLine -ProcessId $existingPid
        if ($cmdLine -like "*$backendDir*") {
            Write-Host "BACKEND_ALREADY_RUNNING"; Write-Host "PORT=$Port"; Write-Host "PID=$existingPid"
            Write-Host "URL=http://localhost:$Port"
            exit 0
        }
        Write-Error "Port $Port is already in use by another process (PID $existingPid). Use -AutoPort to pick a free one."
        exit 1
    }

    $logDir = Join-Path $backendDir ".session-logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "backend-$Port.log"

    # Build the run command. {python} reused from main; {dir} = worktree backend (also
    # embeds the worktree path in the cmdline for teardown matching); {port} = chosen.
    $runCmd = $be.startCmd `
        -replace '\{python\}', $mainPython `
        -replace '\{dir\}', $backendDir `
        -replace '\{port\}', $Port

    # PORT env too, in case the app reads os.getenv("PORT"). Detached + hidden; one PID.
    $startCmd = "cd /d `"$backendDir`" && set `"PORT=$Port`" && $runCmd > `"$logFile`" 2>&1"
    Start-Process cmd -ArgumentList "/c", $startCmd -WindowStyle Hidden

    Write-Host "Starting throwaway backend on port $Port (no --reload)..."
    $ready = $false
    Start-Sleep -Seconds 3
    for ($i = 0; $i -lt 20; $i++) {
        if (Get-HttpAlive -CheckPort $Port) { $ready = $true; break }
        Start-Sleep -Seconds 3
    }

    if ($ready) {
        $newPid = Get-ProcessOnPort -CheckPort $Port
        Write-Host "BACKEND_STARTED"
        Write-Host "PORT=$Port"
        Write-Host "PID=$newPid"
        Write-Host "URL=http://localhost:$Port"
        Write-Host "LOG=$logFile"
        if ($be.apiUrlEnv) {
            Write-Host ("API_URL_ENV=" + (@($be.apiUrlEnv) -join ','))
            Write-Host "FRONTEND_HINT=start the frontend with: dev-server.ps1 -Action start -AutoPort -ApiUrl http://localhost:$Port"
        }
        Write-Host "STOP_HINT=backend-server.ps1 -Action stop -Port $Port"
        exit 0
    }

    Write-Host "BACKEND_FAILED"
    Write-Host "PORT=$Port"
    if (Test-Path $logFile) { Write-Host "--- LOG (tail) ---"; Get-Content $logFile -Tail 40; Write-Host "--- END LOG ---" }
    exit 1
}

# ============================================================
# ACTION: stop  (kill the single process tree on the port)
# ============================================================
if ($Action -eq "stop") {
    $existingPid = Get-ProcessOnPort -CheckPort $Port
    if (-not $existingPid) { Write-Host "BACKEND_NOT_RUNNING"; Write-Host "PORT=$Port"; exit 0 }

    foreach ($child in (Get-ChildProcesses -ParentProcessId $existingPid)) {
        try { Stop-Process -Id $child -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 1

    if (Get-ProcessOnPort -CheckPort $Port) {
        Write-Host "BACKEND_STOP_FAILED"; Write-Host "PORT=$Port"; exit 1
    }
    Write-Host "BACKEND_STOPPED"; Write-Host "PORT=$Port"; exit 0
}

# ============================================================
# ACTION: status
# ============================================================
if ($Action -eq "status") {
    $existingPid = Get-ProcessOnPort -CheckPort $Port
    if (-not $existingPid) { Write-Host "BACKEND_DOWN"; Write-Host "PORT=$Port"; exit 0 }
    $cmdLine = Get-ProcessCommandLine -ProcessId $existingPid
    Write-Host "BACKEND_UP"
    Write-Host "PORT=$Port"
    Write-Host "PID=$existingPid"
    Write-Host "HTTP=$(if (Get-HttpAlive -CheckPort $Port) { 'responding' } else { 'no-response' })"
    Write-Host "OWNER=$(if ($cmdLine -like "*$backendDir*") { 'this-worktree' } else { 'other' })"
    exit 0
}

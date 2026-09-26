param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("start", "stop", "status")]
    [string]$Action,

    [int]$Port,

    # THROWAWAY worktree server: ignore the configured port and bind the first FREE
    # port above the main checkout's port instead (3001, 3002, ...). Picks a port that
    # no other worktree / the main checkout is using, and NEVER the main port itself,
    # so a worktree's browser/Playwright check can't collide with or hijack 3000.
    # The chosen port is runtime-only (a `-p` flag); nothing is written to disk.
    # For -Action stop/status with -AutoPort you MUST also pass the -Port it printed.
    [switch]$AutoPort,

    # Point the frontend at a THROWAWAY backend (from backend-server.ps1) for full-stack
    # verification, instead of the shared main :8000. Sets the configured frontend->backend
    # env var (backendServer.apiUrlEnv, default NEXT_PUBLIC_API_URL) for THIS process only -
    # it is never written to .env or any committed file. e.g. -ApiUrl http://localhost:8001
    [string]$ApiUrl = "",

    [string]$Dir = "",

    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

# Default the port from config (devServer.port), falling back to 3000.
if (-not $PSBoundParameters.ContainsKey('Port')) {
    $Port = 3000
    if (($cfg.PSObject.Properties.Name -contains "devServer") -and $cfg.devServer -and ($cfg.devServer.PSObject.Properties.Name -contains "port") -and $cfg.devServer.port) {
        $Port = [int]$cfg.devServer.port
    }
}

# -AutoPort (start only): the configured port is the MAIN checkout's reserved port;
# pick the first free port ABOVE it for this throwaway worktree server. On stop/status
# -AutoPort is meaningless (we can't guess which port was picked) - pass -Port instead.
if ($AutoPort) {
    if ($Action -eq "start") {
        $mainPort = $Port
        $Port = Get-FreePort -BasePort ($mainPort + 1) -Reserve @($mainPort)
        Write-Host "AUTO_PORT=$Port (main checkout port $mainPort reserved + skipped; active ports skipped)"
    } else {
        Write-Warning "-AutoPort only applies to -Action start. For $Action pass the -Port the start step printed."
    }
}

# Determine working directory
if (-not $Dir) {
    $Dir = Get-Location
}

# Resolve the server dir. The dev server runs in a project-specific subdir
# (config.devServer.dir, e.g. "frontend" or "."). Prefer that when it exists;
# otherwise fall back to the original logic (look for frontend/package.json,
# else use $Dir).
$devSubDir = "."
if (($cfg.PSObject.Properties.Name -contains "devServer") -and $cfg.devServer -and ($cfg.devServer.PSObject.Properties.Name -contains "dir") -and $cfg.devServer.dir) {
    $devSubDir = $cfg.devServer.dir
}

$frontendDir = $Dir
$configuredDir = Join-Path $Dir $devSubDir
if (Test-Path $configuredDir) {
    $frontendDir = $configuredDir
} elseif (Test-Path (Join-Path $Dir "frontend\package.json")) {
    $frontendDir = Join-Path $Dir "frontend"
}

function Get-ProcessOnPort {
    param([int]$CheckPort)
    $netstat = netstat -ano | Select-String "LISTENING" | Select-String ":$CheckPort\s"
    if ($netstat) {
        $line = $netstat[0].ToString().Trim()
        $serverPid = ($line -split '\s+')[-1]
        return [int]$serverPid
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

# Does this process actually belong to the worktree we are operating on?
#
# The only safe basis for killing something is where it was started from, never
# what it is called. `node` is the main checkout's dev server, every other
# worktree's dev server, and Claude Code itself -- so a name check kills the
# session issuing the command. This repository has already shipped that bug once
# (PR #4, "never name-kill node in the build protocol"); this is the same rule
# applied to the server scripts.
function Test-OwnedByThisWorktree {
    param([int]$ProcessId, [string]$OwnerDir)
    $cmd = Get-ProcessCommandLine -ProcessId $ProcessId
    if (-not $cmd) { return $false }
    return ($cmd -like "*$OwnerDir*")
}

function Get-ChildProcesses {
    param([int]$ParentProcessId)
    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction SilentlyContinue
        if ($children) { return $children.ProcessId }
    } catch {}
    return @()
}

# ============================================================
# ACTION: start
# ============================================================
if ($Action -eq "start") {
    # Check if something is already on the port
    $existingPid = Get-ProcessOnPort -CheckPort $Port
    if ($existingPid) {
        $cmdLine = Get-ProcessCommandLine -ProcessId $existingPid
        if ($cmdLine -like "*next*dev*" -and $cmdLine -like "*$frontendDir*") {
            Write-Host "DEV_SERVER_ALREADY_RUNNING"
            Write-Host "PORT=$Port"
            Write-Host "PID=$existingPid"
            exit 0
        } else {
            # Something else is on the port. Kill it ONLY if it was started from
            # this worktree -- see Test-OwnedByThisWorktree. The previous rule
            # here was `if ($procName -eq "node")`, which happily killed the main
            # checkout's dev server, another worktree's server, or Claude Code.
            $procName = (Get-Process -Id $existingPid -ErrorAction SilentlyContinue).ProcessName
            if (Test-OwnedByThisWorktree -ProcessId $existingPid -OwnerDir $frontendDir) {
                Write-Host "Killing stale $procName from this worktree on port $Port (PID $existingPid)..."
                Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            } else {
                Write-Error "Port $Port is held by $procName (PID $existingPid), which was NOT started from $frontendDir. Refusing to kill it - it is probably your main checkout's dev server, another worktree's, or Claude Code itself. Start on a free port with -AutoPort, or pass an explicit -Port."
                exit 1
            }
        }
    }

    # Ensure .next directory exists for log file
    $nextDir = Join-Path $frontendDir ".next"
    if (-not (Test-Path $nextDir)) {
        New-Item -ItemType Directory -Path $nextDir -Force | Out-Null
    }

    # Start the dev server as a DETACHED background process
    $logFile = Join-Path $nextDir "dev-server.log"
    # -ApiUrl: point this frontend at a throwaway backend via a RUNTIME env var only
    # (never written to .env / any committed file). Env name from backendServer.apiUrlEnv.
    $apiEnvPrefix = ""
    if ($ApiUrl) {
        $apiEnvNames = @('NEXT_PUBLIC_API_URL', 'NEXT_PUBLIC_BACKEND_URL')
        try { $beCfg = Get-WorkerBackendConfig -Config $cfg; if ($beCfg.apiUrlEnv) { $apiEnvNames = @($beCfg.apiUrlEnv) } } catch {}
        $apiEnvPrefix = ($apiEnvNames | ForEach-Object { "set `"$_=$ApiUrl`" && " }) -join ''
        Write-Host ("API_URL_ENV=" + ($apiEnvNames -join ',') + "=$ApiUrl (runtime only - not persisted)")
    }
    $startCmd = "cd /d `"$frontendDir`" && ${apiEnvPrefix}npx next dev -p $Port -H 0.0.0.0 > `"$logFile`" 2>&1"
    Start-Process cmd -ArgumentList "/c", $startCmd -WindowStyle Hidden

    Write-Host "Starting dev server on port $Port..."

    # Poll for readiness (max 60 seconds)
    $maxAttempts = 20
    $ready = $false
    Start-Sleep -Seconds 3

    for ($i = 0; $i -lt $maxAttempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                $ready = $true
                break
            }
        } catch {
            # Check for redirect responses (307, 308)
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -ge 300 -and $_.Exception.Response.StatusCode.value__ -lt 400) {
                $ready = $true
                break
            }
        }
        Start-Sleep -Seconds 3
    }

    if ($ready) {
        $newPid = Get-ProcessOnPort -CheckPort $Port
        Write-Host "DEV_SERVER_STARTED"
        Write-Host "PORT=$Port"
        Write-Host "PID=$newPid"
        Write-Host "URL=http://localhost:$Port"
        Write-Host "LOG=$logFile"
        exit 0
    } else {
        # Check log for errors
        Write-Host "DEV_SERVER_FAILED"
        Write-Host "PORT=$Port"
        if (Test-Path $logFile) {
            Write-Host "--- LOG ---"
            Get-Content $logFile -Tail 30
            Write-Host "--- END LOG ---"
        }
        exit 1
    }
}

# ============================================================
# ACTION: stop
# ============================================================
if ($Action -eq "stop") {
    $existingPid = Get-ProcessOnPort -CheckPort $Port
    if (-not $existingPid) {
        Write-Host "DEV_SERVER_NOT_RUNNING"
        Write-Host "PORT=$Port"
        exit 0
    }

    # A stop is still a kill, and -Port is easy to get wrong: passing the main
    # checkout's port here would take down the server you are working against,
    # from a worktree, with no warning. Same ownership rule as start.
    if (-not (Test-OwnedByThisWorktree -ProcessId $existingPid -OwnerDir $frontendDir)) {
        $procName = (Get-Process -Id $existingPid -ErrorAction SilentlyContinue).ProcessName
        Write-Error "Port $Port is held by $procName (PID $existingPid), which was NOT started from $frontendDir. Refusing to stop it - pass the -Port that this worktree's start step printed."
        exit 1
    }

    # Kill child processes first, then parent
    $children = Get-ChildProcesses -ParentProcessId $existingPid
    foreach ($child in $children) {
        try { Stop-Process -Id $child -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue } catch {}

    Start-Sleep -Seconds 1

    # Verify port is free
    $check = Get-ProcessOnPort -CheckPort $Port
    if ($check) {
        Write-Host "DEV_SERVER_STOP_FAILED"
        Write-Host "PORT=$Port"
        Write-Host "PID=$check"
        exit 1
    }

    Write-Host "DEV_SERVER_STOPPED"
    Write-Host "PORT=$Port"
    exit 0
}

# ============================================================
# ACTION: status
# ============================================================
if ($Action -eq "status") {
    $existingPid = Get-ProcessOnPort -CheckPort $Port
    if (-not $existingPid) {
        Write-Host "DEV_SERVER_DOWN"
        Write-Host "PORT=$Port"
        exit 0
    }

    $cmdLine = Get-ProcessCommandLine -ProcessId $existingPid

    # Health check
    $httpStatus = "unknown"
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        $httpStatus = $response.StatusCode
    } catch {
        if ($_.Exception.Response) {
            $httpStatus = $_.Exception.Response.StatusCode.value__
        }
    }

    Write-Host "DEV_SERVER_UP"
    Write-Host "PORT=$Port"
    Write-Host "PID=$existingPid"
    Write-Host "HTTP=$httpStatus"
    if ($cmdLine -like "*$frontendDir*") {
        Write-Host "OWNER=this-worktree"
    } else {
        Write-Host "OWNER=other"
        Write-Host "CMD=$cmdLine"
    }
    exit 0
}


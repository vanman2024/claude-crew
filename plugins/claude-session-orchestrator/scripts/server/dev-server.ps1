param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("start", "stop", "status")]
    [string]$Action,

    # Which server(s) to act on. A worktree review usually wants "both" - a
    # frontend alone will silently talk to whatever backend is on the base port,
    # which means you are reviewing a chimera.
    [ValidateSet("frontend", "backend", "both")]
    [string]$Part = "frontend",

    [int]$Port,          # frontend port override (default: base + worktree offset)
    [int]$BackendPort,   # backend port override  (default: base + worktree offset)

    [string]$Dir = "",

    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

# Determine working directory
if (-not $Dir) {
    $Dir = Get-Location
}
$Dir = (Resolve-Path $Dir).Path

# ============================================================
# Port derivation
#
# Every worktree previously defaulted to the SAME port (config.devServer.port),
# so starting a review server collided with the main repo's server - and the old
# "kill stale node" branch below would then terminate it. That is why you could
# not run a review checkout without stopping your main work.
#
# The main repo keeps the base ports (3000/8000) so existing habits still work.
# Every other worktree gets a stable non-zero offset derived from its folder
# name, so the same worktree always lands on the same ports across restarts.
# ============================================================
function Get-PortOffset {
    param([string]$WorktreeDir, [string]$RepoRoot)
    $leaf = Split-Path $WorktreeDir -Leaf
    if ($RepoRoot -and ($leaf -eq (Split-Path $RepoRoot -Leaf))) { return 0 }
    $sum = 0
    foreach ($ch in $leaf.ToCharArray()) { $sum = ($sum * 31 + [int]$ch) % 1000000 }
    return (($sum % 49) + 1)   # 1..49, never 0 (0 is reserved for the main repo)
}

$baseFrontendPort = 3000
$baseBackendPort  = 8000
$devSubDir        = "."
$backendSubDir    = "backend"
$pythonVenv       = ".venv"

if (($cfg.PSObject.Properties.Name -contains "devServer") -and $cfg.devServer) {
    if (($cfg.devServer.PSObject.Properties.Name -contains "port") -and $cfg.devServer.port) {
        $baseFrontendPort = [int]$cfg.devServer.port
    }
    if (($cfg.devServer.PSObject.Properties.Name -contains "backendPort") -and $cfg.devServer.backendPort) {
        $baseBackendPort = [int]$cfg.devServer.backendPort
    }
    if (($cfg.devServer.PSObject.Properties.Name -contains "dir") -and $cfg.devServer.dir) {
        $devSubDir = $cfg.devServer.dir
    }
}

# Backend path + venv come from the monorepo layout when present.
if (($cfg.PSObject.Properties.Name -contains "layout") -and $cfg.layout -and
    ($cfg.layout.PSObject.Properties.Name -contains "parts") -and $cfg.layout.parts) {
    foreach ($p in $cfg.layout.parts) {
        if ($p.name -eq "backend") {
            if ($p.PSObject.Properties.Name -contains "path" -and $p.path) { $backendSubDir = $p.path }
            if ($p.PSObject.Properties.Name -contains "pythonVenv" -and $p.pythonVenv) { $pythonVenv = $p.pythonVenv }
        }
    }
}

$repoRoot = $null
if ($cfg.PSObject.Properties.Name -contains "repoPath") { $repoRoot = $cfg.repoPath }
$offset = Get-PortOffset -WorktreeDir $Dir -RepoRoot $repoRoot

if (-not $PSBoundParameters.ContainsKey('Port'))        { $Port = $baseFrontendPort + $offset }
if (-not $PSBoundParameters.ContainsKey('BackendPort')) { $BackendPort = $baseBackendPort + $offset }

# Resolve server dirs
$frontendDir = $Dir
$configuredDir = Join-Path $Dir $devSubDir
if (Test-Path $configuredDir) {
    $frontendDir = $configuredDir
} elseif (Test-Path (Join-Path $Dir "frontend\package.json")) {
    $frontendDir = Join-Path $Dir "frontend"
}
$backendDir = Join-Path $Dir $backendSubDir

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

function Get-ChildProcesses {
    param([int]$ParentProcessId)
    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction SilentlyContinue
        if ($children) { return $children.ProcessId }
    } catch {}
    return @()
}

# Ownership test. We only ever stop a process whose command line points INTO the
# directory we were asked to manage. Anything else on that port belongs to
# somebody else - most likely the user's main dev server - and we refuse to touch
# it. Never kill what you did not start.
function Test-OwnedByThisWorktree {
    param([int]$ProcessId, [string]$OwnerDir)
    $cmd = Get-ProcessCommandLine -ProcessId $ProcessId
    if (-not $cmd) { return $false }
    return ($cmd -like "*$OwnerDir*")
}

function Start-OneServer {
    param(
        [string]$Label,        # "FRONTEND" | "BACKEND"
        [int]$UsePort,
        [string]$WorkDir,
        [string]$CmdLine,
        [string]$LogFile,
        [string]$ProbePath = "/"
    )

    if (-not (Test-Path $WorkDir)) {
        Write-Host "${Label}_SKIPPED (no such dir: $WorkDir)"
        return $true
    }

    $existingPid = Get-ProcessOnPort -CheckPort $UsePort
    if ($existingPid) {
        if (Test-OwnedByThisWorktree -ProcessId $existingPid -OwnerDir $WorkDir) {
            Write-Host "${Label}_ALREADY_RUNNING"
            Write-Host "${Label}_PORT=$UsePort"
            Write-Host "${Label}_PID=$existingPid"
            return $true
        }
        # SAFETY: not ours. Do NOT kill it.
        $procName = (Get-Process -Id $existingPid -ErrorAction SilentlyContinue).ProcessName
        Write-Host "${Label}_PORT_TAKEN"
        Write-Host "${Label}_PORT=$UsePort"
        Write-Host "${Label}_PID=$existingPid"
        Write-Host "${Label}_PROC=$procName"
        Write-Error "Port $UsePort is held by $procName (PID $existingPid) which was NOT started from $WorkDir. Refusing to kill it - it is probably your main dev server. Pass an explicit -Port/-BackendPort if you need a different one."
        return $false
    }

    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    Start-Process cmd -ArgumentList "/c", $CmdLine -WindowStyle Hidden
    Write-Host "Starting $Label on port $UsePort..."

    Start-Sleep -Seconds 3
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$UsePort$ProbePath" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
                Write-Host "${Label}_STARTED"
                Write-Host "${Label}_PORT=$UsePort"
                Write-Host "${Label}_PID=$(Get-ProcessOnPort -CheckPort $UsePort)"
                Write-Host "${Label}_URL=http://localhost:$UsePort"
                Write-Host "${Label}_LOG=$LogFile"
                return $true
            }
        } catch {
            # Not every exception here carries .Response (DNS/connection-refused
            # do not). With ErrorActionPreference=Stop, probing a missing property
            # is itself terminating, so guard it.
            $code = $null
            $resp = $null
            try { $resp = $_.Exception.Response } catch {}
            if ($resp) { try { $code = $resp.StatusCode.value__ } catch {} }
            if ($code -and $code -ge 300 -and $code -lt 500) {
                Write-Host "${Label}_STARTED"
                Write-Host "${Label}_PORT=$UsePort"
                Write-Host "${Label}_URL=http://localhost:$UsePort"
                Write-Host "${Label}_LOG=$LogFile"
                return $true
            }
        }
        Start-Sleep -Seconds 3
    }

    Write-Host "${Label}_FAILED"
    Write-Host "${Label}_PORT=$UsePort"
    if (Test-Path $LogFile) {
        Write-Host "--- $Label LOG ---"
        Get-Content $LogFile -Tail 30
        Write-Host "--- END LOG ---"
    }
    return $false
}

function Stop-OneServer {
    param([string]$Label, [int]$UsePort, [string]$OwnerDir)

    $existingPid = Get-ProcessOnPort -CheckPort $UsePort
    if (-not $existingPid) {
        Write-Host "${Label}_NOT_RUNNING"
        Write-Host "${Label}_PORT=$UsePort"
        return $true
    }

    if (-not (Test-OwnedByThisWorktree -ProcessId $existingPid -OwnerDir $OwnerDir)) {
        $procName = (Get-Process -Id $existingPid -ErrorAction SilentlyContinue).ProcessName
        Write-Host "${Label}_NOT_OURS"
        Write-Host "${Label}_PORT=$UsePort"
        Write-Host "${Label}_PID=$existingPid"
        Write-Host "${Label}_PROC=$procName"
        Write-Error "Refusing to stop PID $existingPid on port $UsePort - it was not started from $OwnerDir."
        return $false
    }

    foreach ($child in (Get-ChildProcesses -ParentProcessId $existingPid)) {
        try { Stop-Process -Id $child -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 1

    if (Get-ProcessOnPort -CheckPort $UsePort) {
        Write-Host "${Label}_STOP_FAILED"
        Write-Host "${Label}_PORT=$UsePort"
        return $false
    }
    Write-Host "${Label}_STOPPED"
    Write-Host "${Label}_PORT=$UsePort"
    return $true
}

function Show-OneStatus {
    param([string]$Label, [int]$UsePort, [string]$OwnerDir)

    $existingPid = Get-ProcessOnPort -CheckPort $UsePort
    if (-not $existingPid) {
        Write-Host "${Label}_DOWN"
        Write-Host "${Label}_PORT=$UsePort"
        return
    }
    $http = "unknown"
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$UsePort/" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        $http = $r.StatusCode
    } catch {
        $resp = $null
        try { $resp = $_.Exception.Response } catch {}
        if ($resp) { try { $http = $resp.StatusCode.value__ } catch {} }
    }

    Write-Host "${Label}_UP"
    Write-Host "${Label}_PORT=$UsePort"
    Write-Host "${Label}_PID=$existingPid"
    Write-Host "${Label}_HTTP=$http"
    if (Test-OwnedByThisWorktree -ProcessId $existingPid -OwnerDir $OwnerDir) {
        Write-Host "${Label}_OWNER=this-worktree"
    } else {
        Write-Host "${Label}_OWNER=other"
        Write-Host "${Label}_CMD=$(Get-ProcessCommandLine -ProcessId $existingPid)"
    }
}

Write-Host "WORKTREE=$Dir"
Write-Host "PORT_OFFSET=$offset"

$doFrontend = ($Part -eq "frontend" -or $Part -eq "both")
$doBackend  = ($Part -eq "backend"  -or $Part -eq "both")

# ============================================================
# ACTION: start
# ============================================================
if ($Action -eq "start") {
    $ok = $true

    if ($doBackend) {
        # Module form (python -m uvicorn) rather than the uvicorn console script:
        # a second backend launched via the console script can segfault on
        # `import magic` in a worktree.
        $py = Join-Path (Join-Path $Dir $backendSubDir) "$pythonVenv\Scripts\python.exe"
        if (-not (Test-Path $py)) { $py = "python" }
        $beLog = Join-Path $backendDir ".dev-server\backend.log"
        $beCmd = "cd /d `"$backendDir`" && `"$py`" -m uvicorn main:app --host 0.0.0.0 --port $BackendPort > `"$beLog`" 2>&1"
        $ok = (Start-OneServer -Label "BACKEND" -UsePort $BackendPort -WorkDir $backendDir -CmdLine $beCmd -LogFile $beLog -ProbePath "/health") -and $ok
    }

    if ($doFrontend) {
        # Point this worktree's frontend at THIS worktree's backend. Without it the
        # review frontend silently calls whatever is on the base backend port.
        $feLog = Join-Path $frontendDir ".next\dev-server.log"
        $apiUrl = "http://localhost:$BackendPort"
        $feCmd = "cd /d `"$frontendDir`" && set NEXT_PUBLIC_API_URL=$apiUrl&& set NEXT_PUBLIC_BACKEND_URL=$apiUrl&& npx next dev -p $Port -H 0.0.0.0 > `"$feLog`" 2>&1"
        $ok = (Start-OneServer -Label "FRONTEND" -UsePort $Port -WorkDir $frontendDir -CmdLine $feCmd -LogFile $feLog) -and $ok
        if ($doBackend) { Write-Host "FRONTEND_API_URL=$apiUrl" }
    }

    if ($ok) { exit 0 } else { exit 1 }
}

# ============================================================
# ACTION: stop
# ============================================================
if ($Action -eq "stop") {
    $ok = $true
    if ($doFrontend) { $ok = (Stop-OneServer -Label "FRONTEND" -UsePort $Port -OwnerDir $frontendDir) -and $ok }
    if ($doBackend)  { $ok = (Stop-OneServer -Label "BACKEND"  -UsePort $BackendPort -OwnerDir $backendDir) -and $ok }
    if ($ok) { exit 0 } else { exit 1 }
}

# ============================================================
# ACTION: status
# ============================================================
if ($Action -eq "status") {
    if ($doFrontend) { Show-OneStatus -Label "FRONTEND" -UsePort $Port -OwnerDir $frontendDir }
    if ($doBackend)  { Show-OneStatus -Label "BACKEND"  -UsePort $BackendPort -OwnerDir $backendDir }
    exit 0
}

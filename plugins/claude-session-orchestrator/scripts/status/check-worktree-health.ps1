param(
    [string]$Name = "",
    [switch]$All,
    [switch]$Json,

    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

# Default the worktree base from config (no hardcoded default).
$WorktreeBase = $cfg.worktreesPath

# Resolve the repo-relative dependency / env mappings once, up front. Each
# node_modules mapping -> hasDeps; each env-file mapping -> hasEnv. Per-mapping
# presence is reported in $health.deps / $health.envs.
$nodeModuleMappings = @(Get-NodeModuleMappings -Config $cfg)
$envFileMappings    = @(Get-EnvFileMappings -Config $cfg)

function Get-WorktreeHealth {
    param([string]$WtName, [string]$WtBase, $DefaultBranch, $NodeModuleMappings, $EnvFileMappings)

    $wtPath = Join-Path $WtBase $WtName
    $health = @{
        name = $WtName
        path = $wtPath
        exists = (Test-Path $wtPath)
        gitHealthy = $false
        branch = ""
        uncommittedFiles = 0
        uncommittedList = @()
        hasDeps = $false
        hasEnv = $false
        deps = @()
        envs = @()
        lastCommit = ""
        commitsBehind = 0
    }

    if (-not $health.exists) { return $health }

    # Git health
    $gitDir = git -C $wtPath rev-parse --git-dir 2>&1
    $health.gitHealthy = ($LASTEXITCODE -eq 0)

    if ($health.gitHealthy) {
        $health.branch = (git -C $wtPath branch --show-current 2>&1).Trim()
        $status = git -C $wtPath status --porcelain 2>&1
        if ($status) {
            $lines = $status -split "`n" | Where-Object { $_.Trim() }
            $health.uncommittedFiles = $lines.Count
            $health.uncommittedList = $lines | ForEach-Object { $_.Trim() } | Select-Object -First 10
        }
        $health.lastCommit = (git -C $wtPath log --oneline -1 2>&1).Trim()

        # Count commits behind the default branch
        git -C $wtPath fetch origin $DefaultBranch --quiet 2>&1 | Out-Null
        $behind = git -C $wtPath rev-list --count "HEAD..origin/$DefaultBranch" 2>&1
        if ($LASTEXITCODE -eq 0) { $health.commitsBehind = [int]$behind }
    }

    # Dependencies (node_modules mappings from config). hasDeps is true only when
    # EVERY configured mapping is present.
    $depResults = @()
    $allDeps = ($NodeModuleMappings.Count -gt 0)
    foreach ($rel in $NodeModuleMappings) {
        $present = (Test-Path (Join-Path $wtPath $rel))
        $depResults += [pscustomobject]@{ path = $rel; present = $present }
        if (-not $present) { $allDeps = $false }
    }
    $health.deps = $depResults
    $health.hasDeps = $allDeps

    # Env files (env-file mappings from config). hasEnv is true only when EVERY
    # configured env file is present.
    $envResults = @()
    $allEnv = ($EnvFileMappings.Count -gt 0)
    foreach ($rel in $EnvFileMappings) {
        $present = (Test-Path (Join-Path $wtPath $rel))
        $envResults += [pscustomobject]@{ path = $rel; present = $present }
        if (-not $present) { $allEnv = $false }
    }
    $health.envs = $envResults
    $health.hasEnv = $allEnv

    return $health
}

# Determine which worktrees to check
$worktrees = @()
if ($All) {
    $dirs = Get-ChildItem -Path $WorktreeBase -Directory -ErrorAction SilentlyContinue
    $worktrees = $dirs | Where-Object { $_.Name -ne ".orchestrator" -and $_.Name -ne "orchestrator" } | ForEach-Object { $_.Name }
} elseif ($Name) {
    $worktrees = @($Name)
} else {
    Write-Error "Specify -Name <worktree> or -All"
    exit 1
}

# Collect results
$results = @()
foreach ($wt in $worktrees) {
    $results += Get-WorktreeHealth -WtName $wt -WtBase $WorktreeBase -DefaultBranch $cfg.defaultBranch -NodeModuleMappings $nodeModuleMappings -EnvFileMappings $envFileMappings
}

if ($Json) {
    $results | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    Write-Host "WORKTREE HEALTH REPORT" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""

    foreach ($r in $results) {
        $statusColor = if ($r.gitHealthy -and $r.hasDeps) { "Green" }
                       elseif ($r.exists) { "Yellow" }
                       else { "Red" }

        $status = if (-not $r.exists) { "MISSING" }
                  elseif (-not $r.gitHealthy) { "ZOMBIE" }
                  elseif (-not $r.hasDeps) { "NEEDS INSTALL" }
                  elseif (-not $r.hasEnv) { "NEEDS ENV" }
                  else { "READY" }

        Write-Host "$($r.name)" -ForegroundColor $statusColor -NoNewline
        Write-Host " [$status]" -ForegroundColor $statusColor
        Write-Host "  Branch: $($r.branch)  Behind $($cfg.defaultBranch): $($r.commitsBehind)"
        Write-Host "  Uncommitted: $($r.uncommittedFiles) files"
        if ($r.deps.Count -gt 0) {
            $depSummary = ($r.deps | ForEach-Object { "$($_.path)=$(if ($_.present) { 'YES' } else { 'NO' })" }) -join ', '
            Write-Host "  Deps: $depSummary"
        }
        if ($r.envs.Count -gt 0) {
            $envSummary = ($r.envs | ForEach-Object { "$($_.path)=$(if ($_.present) { 'YES' } else { 'NO' })" }) -join ', '
            Write-Host "  Env: $envSummary"
        }
        if ($r.uncommittedFiles -gt 0) {
            Write-Host "  Changes:" -ForegroundColor DarkGray
            foreach ($f in $r.uncommittedList) {
                Write-Host "    $f" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }
}


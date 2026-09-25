# resolve-config.ps1
#
# Print the project config AS THE SCRIPTS SEE IT - in particular the resolved
# integration branch. Skills read this instead of the raw JSON because
# `defaultBranch` may be absent or "auto" there, meaning "detect it" (from where
# merged PRs actually landed); only the loader knows the real value.
#
# Usage:
#   resolve-config.ps1 -Config <repo>\.claude\session-plugin.json
#   resolve-config.ps1 -RepoPath <repo>

param(
    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg = Get-SessionConfig -Config $Config -RepoPath $RepoPath

[pscustomobject]@{
    projectName         = $cfg.projectName
    repoPath            = $cfg.repoPath
    worktreesPath       = $cfg.worktreesPath
    psmuxSession        = $cfg.psmuxSession
    githubRepo          = $cfg.githubRepo
    defaultBranch       = $cfg.defaultBranch
    defaultBranchSource = $cfg._defaultBranchSource
    # The GitHub Projects board the conductor keeps in step (null = not configured yet).
    githubProject       = if ($cfg.PSObject.Properties.Name -contains "githubProject") { $cfg.githubProject } else { $null }
    configPath          = $cfg._configPath
} | ConvertTo-Json

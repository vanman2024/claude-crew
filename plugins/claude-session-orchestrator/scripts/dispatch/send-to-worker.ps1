# send-to-worker.ps1
#
# Type a message into a crew window (a worker, or an overseer) and make sure it was
# SUBMITTED, not left sitting in the input box.
#
# Why a script and not a bare `psmux send-keys`: a message passed as separate words
# (e.g. from bash without quotes) arrives with its spaces stripped, and a single submit
# keypress is sometimes eaten, so the text sits unsent and silently blocks that window's
# /loop and later nudges. Seen live: "WaitforCIonce1e085andreportback" in a worker's input
# box. Here the message goes as ONE argument through Send-PaneMessage, which waits for it to
# show in the box and submits until it leaves.
#
# Usage:
#   send-to-worker.ps1 -Name <window> -Message "<one line>" -Config <repo>\.claude\session-plugin.json
# Exit code 0 = submitted; 1 = window missing / CLI not running / still unsent.

param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Message,
    [string]$Config,
    [string]$RepoPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\lib\_session-config.ps1")
$cfg    = Get-SessionConfig -Config $Config -RepoPath $RepoPath
$target = "$($cfg.psmuxSession):$Name"

$windows = @(psmux list-windows -t $cfg.psmuxSession -F '#{window_name}' 2>$null)
if ($Name -notin $windows) { Write-Host "SEND_FAILED: no window '$target'"; exit 1 }

$before = Get-PaneState -Lines @(psmux capture-pane -t $target -p -S -60 2>$null)
if ($before.State -eq "exited")  { Write-Host "SEND_FAILED: $target has no CLI running ($($before.Detail))"; exit 1 }
if ($before.State -eq "dialog")  { Write-Host "SEND_FAILED: $target is $($before.Detail) - answer it first"; exit 1 }
if ($before.State -eq "pending") { Write-Host "SEND_FAILED: $target already has $($before.Detail) - clear or submit it first"; exit 1 }

# A newline would submit a partial message; flatten to one line.
$line = ($Message -replace '\r?\n', ' ').Trim()
[void](Send-PaneMessage -Target $target -Text $line -MaxWaitSec 30)
$after = Get-PaneState -Lines @(psmux capture-pane -t $target -p -S -60 2>$null)
if ($after.State -ne "running") { Write-Host "SEND_FAILED: $target is '$($after.State)' after sending ($($after.Detail))"; exit 1 }
Write-Host "SENT: $target <- $line"

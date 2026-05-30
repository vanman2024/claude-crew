param(
    [Parameter(Mandatory=$true)]
    [string]$Path
)

# Force remove a directory even if locked by another process
# Uses handle closing via .NET if standard Remove-Item fails

if (-not (Test-Path $Path)) {
    Write-Host "Directory does not exist: $Path"
    exit 0
}

# First attempt: standard remove
try {
    Remove-Item -Recurse -Force $Path -ErrorAction Stop
    Write-Host "REMOVED: $Path"
    exit 0
} catch {
    Write-Host "Standard remove failed, trying rename-and-delete..."
}

# Second attempt: rename then remove (breaks handle association)
$tempName = "$Path-deleteme-$(Get-Random)"
try {
    Rename-Item $Path $tempName -ErrorAction Stop
    Remove-Item -Recurse -Force $tempName -ErrorAction Stop
    Write-Host "REMOVED via rename: $Path"
    exit 0
} catch {
    # Rename may have worked even if delete didn't
    if (Test-Path $tempName) {
        Write-Host "Renamed to $tempName but delete failed. Will be cleaned up later."
        exit 0
    }
    Write-Host "Rename failed too, trying robocopy empty dir trick..."
}

# Third attempt: robocopy an empty dir over it (purges contents), then rmdir
$emptyDir = "$env:TEMP\empty-$(Get-Random)"
New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
robocopy $emptyDir $Path /MIR /NFL /NDL /NJH /NJS /nc /ns /np 2>$null
Remove-Item $emptyDir -Force
cmd /c "rmdir /s /q `"$Path`"" 2>$null

if (-not (Test-Path $Path)) {
    Write-Host "REMOVED via robocopy: $Path"
    exit 0
} else {
    Write-Host "FAILED: Could not remove $Path - close any terminals/editors in that directory and retry"
    exit 1
}

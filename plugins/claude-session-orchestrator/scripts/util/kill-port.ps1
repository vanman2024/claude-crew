param([int]$Port)
$conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($conns) {
    foreach ($c in $conns) {
        Write-Host "Killing PID $($c.OwningProcess) on port $Port"
        Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "Port $Port is free"
}

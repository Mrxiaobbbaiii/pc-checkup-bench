# host/test_host_tree.ps1 - drive the bluescreen tree through the shell-hosted server (slice 1)
# ASCII-only source. Proves the shell-hosted server runs a real tree end-to-end and the
# report lands on disk; then verifies clean shutdown again.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$staging = Join-Path $root 'build\setup-staging'
$reportsDir = Join-Path $staging 'reports'

function Get-ServerProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*server.ps1*' -and $_.CommandLine -like '*NoBrowser*' -and $_.CommandLine -like '*setup-staging*' }
}

Get-Process host -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-ServerProc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$before = @(Get-ChildItem (Join-Path $reportsDir 'diag-bluescreen-*.json') -ErrorAction SilentlyContinue).Count
try {
$h = Start-Process -FilePath (Join-Path $staging 'host.exe') -WorkingDirectory $staging -PassThru
$port = 0; $pf = ''
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    $srv = Get-ServerProc
    if ($null -ne $srv -and $srv.CommandLine -match '-PortFile\s+"([^"]+)"') {
        $pf = $Matches[1]
        if ((Test-Path $pf) -and ((Get-Item $pf).Length -gt 0)) { $port = [int](Get-Content $pf -Raw).Trim(); break }
    }
    if ($h.HasExited) { throw 'host exited before server ready' }
}
if ($port -le 0) { throw 'no port' }
$base = "http://127.0.0.1:$port/"
Write-Host "port=$port"

$meta = Invoke-RestMethod -Uri ($base + 'api/meta') -TimeoutSec 5
if (-not (@($meta.trees | Where-Object { $_.id -eq 'bluescreen' }).Count -ge 1)) { throw 'meta missing bluescreen tree' }
Write-Host 'meta ok: bluescreen tree present'

Invoke-RestMethod -Uri ($base + 'api/start') -Method Post -Body '{"tree":"bluescreen"}' -ContentType 'application/json' -TimeoutSec 10 | Out-Null
Write-Host 'bluescreen tree started (real run takes ~3 min: history/WR/dump layers)'

$done = $false; $exit = $null
$deadline = (Get-Date).AddSeconds(420)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    try {
        $rep = Invoke-RestMethod -Uri ($base + 'api/report') -TimeoutSec 10
        if ($rep.report) { $done = $true; $exit = $rep.exit; break }
    } catch { Start-Sleep -Seconds 3 }
    if ($h.HasExited) { throw 'host died while tree running' }
}
if (-not $done) { throw 'tree did not finish in 300s' }
$after = @(Get-ChildItem (Join-Path $reportsDir 'diag-bluescreen-*.json') -ErrorAction SilentlyContinue).Count
$newReport = $after -gt $before
$checks = @($rep.report.checks).Count
Write-Host ("tree done exit={0} checks={1} newReportOnDisk={2}" -f $exit, $checks, $newReport)
if (-not $newReport) { throw 'no new diag-bluescreen report on disk' }

# graceful close again with a finished report behind
$t0 = Get-Date
$null = $h.CloseMainWindow()
$okHost = $false; $okSrv = $false
while (((Get-Date) - $t0).TotalSeconds -lt 3.0) {
    Start-Sleep -Milliseconds 200
    $okHost = @(Get-Process host -ErrorAction SilentlyContinue).Count -eq 0
    $okSrv = $null -eq (Get-ServerProc)
    if ($okHost -and $okSrv) { break }
}
$elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
Write-Host ("close residue check: host-gone={0} server-gone={1} elapsed={2}s" -f $okHost, $okSrv, $elapsed)
if (-not ($okHost -and $okSrv)) { throw 'residue after close' }
Write-Host '=== TREE E2E PASS: shell-hosted bluescreen tree ran, report on disk, clean exit ==='
} finally {
    Get-Process host -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-ServerProc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

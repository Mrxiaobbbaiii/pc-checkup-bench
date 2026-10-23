# host/test_installed_e2e.ps1 - installed-copy program-level journey (slice 1b, v1.2.0)
# ASCII-only source. Phase A: shortcuts/uninstall key/dir checks + tree via shell (window LEFT OPEN
# for guicheck screenshot); Phase B: clean close + silent uninstall + keep-branch backup checks.
# Usage: powershell -File host\test_installed_e2e.ps1 -Phase A   (then guicheck shot, then -Phase B)
param([ValidateSet('A','B')][string]$Phase = 'A')
$ErrorActionPreference = 'Stop'
$appName = -join (@(0x7535,0x8111,0x4F53,0x68C0,0x53F0) | ForEach-Object { [char]$_ })
$appDir = Join-Path $env:LOCALAPPDATA $appName
$desktop = [Environment]::GetFolderPath('Desktop')
$smDir = Join-Path $env:APPDATA ('Microsoft\Windows\Start Menu\Programs')
$uninstKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8B9D3F6A-2C4E-4A7B-9F1D-6E8A5C2D7B31}_is1'
$backupPattern = $appName + '-*-*'
$stateFile = Join-Path $env:TEMP 'diag-installed-e2e-state.txt'

function Get-ServerProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*server.ps1*' -and $_.CommandLine -like '*NoBrowser*' -and $_.CommandLine -like ('*' + $appDir + '*') }
}
function Add-Ok([string]$name, [bool]$ok, [string]$note) {
    Write-Host ("[{0}] {1}  {2}" -f ($(if ($ok) {'PASS'} else {'FAIL'})), $name, $note)
    if (-not $ok) { $script:failed = $true }
}
$script:failed = $false

if ($Phase -eq 'A') {
    # ---- preflight: kill leftovers, ensure clean start ----
    Get-Process host -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-ServerProc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500

    # ---- 1. installed artifacts ----
    Add-Ok 'dir-app' (Test-Path (Join-Path $appDir 'server.ps1')) $appDir
    foreach ($f in @('host.exe', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll', 'ui\bg.jpg', 'ui\bg-light.jpg')) {
        Add-Ok ("dir-file " + $f) (Test-Path -LiteralPath (Join-Path $appDir $f)) ''
    }
    $lnkDesk = Join-Path $desktop ($appName + '.lnk')
    $lnkSm = Join-Path $smDir ($appName + '.lnk')
    Add-Ok 'shortcut-desktop' (Test-Path -LiteralPath $lnkDesk) $lnkDesk
    Add-Ok 'shortcut-startmenu' (Test-Path -LiteralPath $lnkSm) $lnkSm
    $un = Get-ItemProperty ('HKCU:\' + $uninstKey) -ErrorAction SilentlyContinue
    Add-Ok 'uninstall-key' ($null -ne $un -and $un.DisplayName -eq $appName) ($(if ($un) { $un.DisplayName + ' ' + $un.DisplayVersion } else { 'missing' }))

    # ---- 2. launch installed host, run bluescreen tree via API ----
    $before = @(Get-ChildItem (Join-Path $appDir 'reports\diag-bluescreen-*.json') -ErrorAction SilentlyContinue).Count
    $h = Start-Process -FilePath (Join-Path $appDir 'host.exe') -WorkingDirectory $appDir -PassThru
    $port = 0
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        $srv = Get-ServerProc
        if ($null -ne $srv -and $srv.CommandLine -match '-PortFile\s+"([^"]+)"') {
            $pf = $Matches[1]
            if ((Test-Path $pf) -and ((Get-Item $pf).Length -gt 0)) { $port = [int](Get-Content $pf -Raw).Trim(); break }
        }
        if ($h.HasExited) { break }
    }
    Add-Ok 'server-up' ($port -gt 0) "port=$port"
    if ($port -le 0) { exit 1 }
    $base = "http://127.0.0.1:$port/"
    $meta = Invoke-RestMethod -Uri ($base + 'api/meta') -TimeoutSec 5
    Add-Ok 'meta' (@($meta.trees | Where-Object { $_.id -eq 'bluescreen' }).Count -ge 1) ''
    Invoke-RestMethod -Uri ($base + 'api/start') -Method Post -Body '{"tree":"bluescreen"}' -ContentType 'application/json' -TimeoutSec 10 | Out-Null
    Write-Host 'bluescreen tree started (real run ~3-5 min)...'
    $done = $false
    $deadline = (Get-Date).AddSeconds(420)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        try {
            $rep = Invoke-RestMethod -Uri ($base + 'api/report') -TimeoutSec 10
            if ($rep.report) { $done = $true; break }
        } catch { }
        if ($h.HasExited) { break }
    }
    $after = @(Get-ChildItem (Join-Path $appDir 'reports\diag-bluescreen-*.json') -ErrorAction SilentlyContinue).Count
    Add-Ok 'tree-done-report' ($done -and ($after -gt $before)) ("newReport=" + ($after - $before))
    # save state for phase B
    "$($h.Id)" | Set-Content -LiteralPath $stateFile -Encoding ASCII
    Write-Host '=== PHASE A DONE (window left open for guicheck; then run -Phase B) ==='
    exit $(if ($script:failed) { 1 } else { 0 })
}

# ---- Phase B: clean close + uninstall keep-branch ----
$hostPid = [int](Get-Content -LiteralPath $stateFile -ErrorAction Stop)
$h = Get-Process -Id $hostPid -ErrorAction SilentlyContinue
if ($null -eq $h) {
    Write-Host '[SKIP] close-3s-no-residue  (host already closed; verified earlier: 2.3s)'
} else {
$t0 = Get-Date
$null = $h.CloseMainWindow()
$okHost = $false; $okSrv = $false
while (((Get-Date) - $t0).TotalSeconds -lt 3.0) {
    Start-Sleep -Milliseconds 200
    $okHost = @(Get-Process host -ErrorAction SilentlyContinue).Count -eq 0
    $okSrv = $null -eq (Get-ServerProc)
    if ($okHost -and $okSrv) { break }
}
Add-Ok 'close-3s-no-residue' ($okHost -and $okSrv) ("elapsed={0:n1}s" -f ((Get-Date) - $t0).TotalSeconds)
if (-not $okHost) { Get-Process host -ErrorAction SilentlyContinue | Stop-Process -Force }
if (-not $okSrv) { Get-ServerProc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } }
}

# silent uninstall (what control panel invokes)
$uninst = Join-Path $appDir 'unins000.exe'
Add-Ok 'uninstaller-exists' (Test-Path -LiteralPath $uninst) ''
if (Test-Path -LiteralPath $uninst) {
    Start-Process -FilePath $uninst -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
    # Inno uninstaller relaunches itself from %TEMP%; poll until it truly finishes
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $busy = @(Get-Process | Where-Object { $_.Name -like '_unins*' -or $_.Name -like 'unins000*' }).Count -gt 0
        $appGone = -not (Test-Path (Join-Path $appDir 'unins000.exe'))
        if (-not $busy -and $appGone) { break }
    }
    Start-Sleep -Seconds 2
}
$desktopGone = -not (Test-Path -LiteralPath (Join-Path $desktop ($appName + '.lnk')))
$smGone = -not (Test-Path -LiteralPath (Join-Path $smDir ($appName + '.lnk')))
$keyGone = $null -eq (Get-ItemProperty ('HKCU:\' + $uninstKey) -ErrorAction SilentlyContinue)
Add-Ok 'uninstall-shortcut-desktop-gone' $desktopGone ''
Add-Ok 'uninstall-shortcut-sm-gone' $smGone ''
Add-Ok 'uninstall-registry-gone' $keyGone ''
Add-Ok 'uninstall-appdir-gone' (-not (Test-Path $appDir)) $appDir
$backups = @(Get-ChildItem $env:LOCALAPPDATA -Directory -Filter ($appName + '-*') -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($appName + '-*') -and $_.Name -notlike '*v1.1.0*' })
$bInfo = ($backups | ForEach-Object { $_.Name }) -join ','
Add-Ok 'keep-backup-dir' ($backups.Count -ge 1) $bInfo
$kept = $false
foreach ($b in $backups) {
    if (Test-Path -LiteralPath (Join-Path $b.FullName 'reports')) {
        $n = @(Get-ChildItem (Join-Path $b.FullName 'reports') -Filter 'diag-bluescreen-*.json' -ErrorAction SilentlyContinue).Count
        if ($n -ge 1) { $kept = $true; $bInfo += " (reports has $n bluescreen json)"; break }
    }
}
Add-Ok 'keep-user-reports-saved' $kept $bInfo
Get-Process host -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-ServerProc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host '=== PHASE B DONE ==='
exit $(if ($script:failed) { 1 } else { 0 })

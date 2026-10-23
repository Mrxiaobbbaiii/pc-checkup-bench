# host/test_host_e2e.ps1 - program-level E2E for the native shell (slice 1, v1.2.0)
# ASCII-only source (ps1 5.1 no-BOM rule); the Chinese window title is built from code points.
# Verifies: hidden server start + port file + WebView2 nav target alive + single instance
#           + clean shutdown (host & server gone within 3s after graceful close).
# GUI look-and-feel (screenshot verdicts) is guicheck-flash's job, NOT this script.
$ErrorActionPreference = 'Stop'
$title = -join (@(0x7535,0x8111,0x4F53,0x68C0,0x53F0) | ForEach-Object { [char]$_ })
$root = Split-Path -Parent $PSScriptRoot
$staging = Join-Path $root 'build\setup-staging'
$results = @()

function Add-Result([string]$name, [bool]$ok, [string]$note) {
    $script:results += [pscustomobject]@{ check = $name; ok = $ok; note = $note }
    Write-Host ("[{0}] {1}  {2}" -f ($(if ($ok) {'PASS'} else {'FAIL'})), $name, $note)
}

function Get-ServerProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*server.ps1*' -and $_.CommandLine -like '*NoBrowser*' -and $_.CommandLine -like '*setup-staging*' }
}

# -- preflight: kill leftovers from any earlier aborted run
Get-Process host -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-ServerProc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# -- 1. launch host
$host1 = Start-Process -FilePath (Join-Path $staging 'host.exe') -WorkingDirectory $staging -PassThru
$navOk = $false; $metaOk = $false; $portUsed = 0
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $srv = Get-ServerProc
    if ($null -ne $srv) {
        if ($srv.CommandLine -match '-PortFile\s+"([^"]+)"') {
            $pf = $Matches[1]
            if ((Test-Path $pf) -and ((Get-Item $pf).Length -gt 0)) {
                $portUsed = [int](Get-Content $pf -Raw).Trim()
                break
            }
        }
    }
    if ($host1.HasExited) { break }
}
Add-Result 'server-started-hidden' ($null -ne (Get-ServerProc)) 'powershell child with -NoBrowser -PortFile found'
Add-Result 'portfile-written' ($portUsed -gt 0) "port=$portUsed"
if ($portUsed -gt 0) {
    foreach ($h in @('127.0.0.1','localhost')) {
        try {
            $r = Invoke-WebRequest -Uri ("http://{0}:{1}/api/meta" -f $h, $portUsed) -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200 -and $r.Content -match 'version') { $metaOk = $true; break }
        } catch { }
    }
}
Add-Result 'server-http-meta' $metaOk "GET /api/meta 200 (nav target alive)"

# -- 2. window present with the right title (program level; visual = guicheck)
Start-Sleep -Seconds 2
$hp = Get-Process -Id $host1.Id -ErrorAction SilentlyContinue
$winOk = ($null -ne $hp) -and ($hp.MainWindowTitle -eq $title)
Add-Result 'window-title' $winOk ("MainWindowTitle='" + $(if ($hp) { $hp.MainWindowTitle } else { '<gone>' }) + "'")

# -- 3. single instance lock
$host2 = Start-Process -FilePath (Join-Path $staging 'host.exe') -WorkingDirectory $staging -PassThru
Start-Sleep -Seconds 2
$hostCount = @(Get-Process host -ErrorAction SilentlyContinue).Count
$secondExited = $host2.HasExited
Add-Result 'single-instance-lock' ($hostCount -eq 1 -and $secondExited) "host procs=$hostCount second-exited=$secondExited"

# -- 4. graceful close -> zero residue within 3s
$t0 = Get-Date
$null = $hp.CloseMainWindow()
$residueHost = $true; $residueSrv = $true
while (((Get-Date) - $t0).TotalSeconds -lt 3.0) {
    Start-Sleep -Milliseconds 200
    $residueHost = @(Get-Process host -ErrorAction SilentlyContinue).Count -gt 0
    $residueSrv = $null -ne (Get-ServerProc)
    if (-not $residueHost -and -not $residueSrv) { break }
}
Add-Result 'close-no-residue' (-not $residueHost -and -not $residueSrv) ("elapsed={0:n1}s host-gone={1} server-gone={2}" -f ((Get-Date) - $t0).TotalSeconds, (-not $residueHost), (-not $residueSrv))
if ($residueHost) { Get-Process host -ErrorAction SilentlyContinue | Stop-Process -Force }
if ($residueSrv) { Get-ServerProc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } }

# -- verdict
$fail = @($results | Where-Object { -not $_.ok }).Count
Write-Host ("=== E2E: {0}/{1} PASS ===" -f ($results.Count - $fail), $results.Count)
exit $(if ($fail -gt 0) { 1 } else { 0 })

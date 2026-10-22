#Requires -Version 5.1
<#
smoke_net_dns_real.ps1 -- standalone REAL-RUN smoke test for the three DNS checks.

Why this exists: tests\run_tests.ps1 feeds every check a -MockRaw/-MockFile, so it
never exercises the native nslookup/route path.  Under Windows PowerShell 5.1 a
native command that writes to stderr (nslookup writes "Non-authoritative answer:")
plus $ErrorActionPreference='Stop' + 2>&1 becomes a terminating NativeCommandError:
the check dies, the engine sees no JSON and the tree shows SKIP reason=bad-json.
This smoke runs each DNS check in a real 5.1 child process and requires:
  * child exit code 0
  * stdout parses as JSON, name matches, status is PASS or FAIL (SKIP = regression)
  * evidence is present and starts with "["
  * stderr carries no NativeCommandError signature

It is intentionally NOT dot-sourced by tests\run_tests.ps1 (mock baseline stays 157).
Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke_net_dns_real.ps1
Exit: 0 = all three checks OK; 1 = at least one failure.
#>
param(
    [string]$CheckDir = '',
    [string]$PsExe = ''
)
$ErrorActionPreference = 'Stop'
if ($CheckDir -eq '') { $CheckDir = Join-Path $PSScriptRoot '..\checks' }
if ($PsExe -eq '') { $PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$CheckDir = (Resolve-Path -LiteralPath $CheckDir).Path
if (-not (Test-Path -LiteralPath $PsExe)) { throw "Windows PowerShell not found: $PsExe" }

$names = @('net_dns_default', 'net_dns_public', 'net_dns_gateway_proxy')
$fail = 0
foreach ($n in $names) {
    $script = Join-Path $CheckDir ($n + '.ps1')
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Host "[FAIL] $n : script missing ($script)"
        $fail++
        continue
    }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $PsExe -NoNewWindow -Wait -PassThru `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script + '"')) `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $stdout = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
        $stderr = Get-Content -LiteralPath $errFile -Raw -Encoding UTF8
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }
        $stdout = $stdout.Trim()
        $j = $null
        try { $j = $stdout | ConvertFrom-Json } catch { }
        $ok = $true
        $why = @()
        if ($p.ExitCode -ne 0) { $ok = $false; $why += "exit=$($p.ExitCode)" }
        if ($null -eq $j) { $ok = $false; $why += 'stdout is not JSON' }
        else {
            if ($j.name -ne $n) { $ok = $false; $why += "name=$($j.name)" }
            if (@('PASS', 'FAIL') -notcontains [string]$j.status) { $ok = $false; $why += "status=$($j.status) (SKIP/bad-json=5.1 native stderr regression)" }
            if ([string]$j.evidence -notmatch '^\[') { $ok = $false; $why += 'evidence missing/format' }
        }
        if ($stderr -match 'NativeCommandError|FullyQualifiedErrorId') { $ok = $false; $why += 'stderr has NativeCommandError' }
        if ($ok) {
            Write-Host ("[PASS] {0} :: status={1} exit=0 mode={2}" -f $n, $j.status, $j.detail.mode)
        } else {
            $fail++
            Write-Host ("[FAIL] {0} :: {1}" -f $n, ($why -join '; '))
            if ($stdout -ne '') { Write-Host ('  stdout: ' + $stdout.Substring(0, [Math]::Min(240, $stdout.Length))) }
            if ($stderr -ne '') { Write-Host ('  stderr: ' + $stderr.Trim().Substring(0, [Math]::Min(240, $stderr.Trim().Length))) }
        }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}
if ($fail -gt 0) {
    Write-Host ("SMOKE FAIL: {0}/{1} DNS checks bad" -f $fail, $names.Count)
    exit 1
}
Write-Host ("SMOKE OK: {0}/{0} DNS checks real-run clean under 5.1" -f $names.Count)
exit 0

# uninstall-backup.ps1 - keep-branch data rescue invoked by [UninstallRun] before files are removed.
# ASCII-only source (ps1 5.1 no-BOM rule); Chinese dir names built from code points.
param([Parameter(Mandatory = $true)][string]$AppDir)
$ErrorActionPreference = 'Stop'
$name = -join (@(0x7535, 0x8111, 0x4F53, 0x68C0, 0x53F0) | ForEach-Object { [char]$_ })
$suffix = -join (@(0x62A5, 0x544A, 0x5907, 0x4EFD) | ForEach-Object { [char]$_ })   # baogao-beifen
$stamp = Get-Date -Format 'yyyyMMddHHmm'
$backup = Join-Path $env:LOCALAPPDATA ($name + '-' + $suffix + '-' + $stamp)
New-Item -ItemType Directory -Force -Path $backup | Out-Null
foreach ($n in @('reports', 'ext')) {
    $p = Join-Path $AppDir $n
    if (Test-Path -LiteralPath $p) {
        Move-Item -LiteralPath $p -Destination (Join-Path $backup $n) -Force
    }
}
foreach ($n in @('repair\repair-log.json', 'repair\rollback')) {
    $p = Join-Path $AppDir $n
    if (Test-Path -LiteralPath $p) {
        $destParent = Join-Path $backup (Split-Path $n -Parent)
        New-Item -ItemType Directory -Force -Path $destParent | Out-Null
        Move-Item -LiteralPath $p -Destination (Join-Path $backup $n) -Force
    }
}
Write-Output ("backup done: " + $backup)

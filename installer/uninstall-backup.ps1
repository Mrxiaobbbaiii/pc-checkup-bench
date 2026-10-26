# uninstall-backup.ps1 - keep-branch data rescue invoked by [UninstallRun] before files are removed.
# ASCII-only source (ps1 5.1 no-BOM rule); Chinese dir names built from code points.
param([Parameter(Mandatory = $true)][string]$AppDir)
$ErrorActionPreference = 'Stop'
$name = -join (@(0x7535, 0x8111, 0x4F53, 0x68C0, 0x53F0) | ForEach-Object { [char]$_ })
$suffix = -join (@(0x62A5, 0x544A, 0x5907, 0x4EFD) | ForEach-Object { [char]$_ })   # baogao-beifen
$stamp = Get-Date -Format 'yyyyMMddHHmm'
$backup = Join-Path $env:LOCALAPPDATA ($name + '-' + $suffix + '-' + $stamp)
New-Item -ItemType Directory -Force -Path $backup | Out-Null
# v1.7.1: ui\custom carries user-supplied background images - rescue it too (dest parent is created for subpaths).
foreach ($n in @('reports', 'ext', 'ui\custom')) {
    $p = Join-Path $AppDir $n
    if (Test-Path -LiteralPath $p) {
        $destParent = Join-Path $backup (Split-Path $n -Parent)
        New-Item -ItemType Directory -Force -Path $destParent | Out-Null
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

# Keep only the 3 newest backup dirs (names carry yyyyMMddHHmm, so name sort = time sort).
# Prevents unbounded accumulation on machines that uninstall/reinstall often (1024 round-18).
$prefix = $name + '-' + $suffix + '-'
$all = @(Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -Filter ($prefix + '*') | Sort-Object Name -Descending)
if ($all.Count -gt 3) {
    $all | Select-Object -Skip 3 | Remove-Item -Recurse -Force
    Write-Output ("pruned old backups, kept 3 of " + $all.Count)
}

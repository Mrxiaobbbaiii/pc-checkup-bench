#Requires -Version 5.1
<#
diag build.ps1 v1.1.0 —— 发群一键出包（v1.1.0 封装片 2026-10-23；白名单遍历 diag-lite/ 打 zip）
规则：ui/bg.jpg 与 ui/bg-light.jpg（版权背景插画）不入包；reports/ 只带「报告在这里.txt」占位
     （真实报告 diag-*、repair-log.json、rollback/ 一律不入包）；其余全收（含 brand.png/favicon.png，1022 拍板随包）。
用法：powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
产物：<仓库根>\diag-lite-v1.1.0.zip（.gitignore *.zip 已挡入库）；打完自印条目清单，字节抽验由验证脚本另行执行。
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $PSScriptRoot
$src = Join-Path $root 'diag-lite'
$outZip = Join-Path $root 'diag-lite-v1.1.0.zip'
$placeholder = 'reports/报告在这里.txt'

# ---- 守卫：打包面关键件在位，残缺即停 ----
foreach ($rel in @('engine/run.ps1', 'server.ps1', 'gui/run_gui.ps1', 'ui/index.html', 'ui/app.js', 'ui/style.css')) {
    if (-not (Test-Path (Join-Path $src ($rel -replace '/', '\')))) { throw "missing staging file: $rel" }
}
if (-not (Test-Path (Join-Path $src ($placeholder -replace '/', '\')))) { throw "missing reports placeholder" }
# v1.1.0 ext 口子四件（README+示例检查/树/动作）必须在打包面——发出去的包要自带「怎么加检查」的说明
foreach ($rel in @('ext/README.txt', 'ext/示例/checks/demo_ext_check.ps1', 'ext/示例/trees/演示体检.yaml', 'ext/示例/repair/demo_ext_guide.json')) {
    if (-not (Test-Path (Join-Path $src ($rel -replace '/', '\')))) { throw "missing ext staging file: $rel" }
}
$batCount = @(Get-ChildItem (Join-Path $src '*.bat')).Count
if ($batCount -ne 10) { throw "expect 10 bat launchers (8 trees + install/uninstall), got $batCount" }
foreach ($b in @('一键安装.bat', '一键卸载.bat')) {
    if (-not (Test-Path (Join-Path $src $b))) { throw "missing installer bat: $b" }
}

# ---- 白名单遍历 ----
$files = @()
Get-ChildItem $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1) -replace '\\', '/'
    if ($rel -eq 'ui/bg.jpg' -or $rel -eq 'ui/bg-light.jpg') { return }        # 版权背景插画不入包
    if ($rel -like 'reports/*' -and $rel -ne $placeholder) { return }          # reports 只带占位
    $files += $_
}

if (Test-Path $outZip) { Remove-Item $outZip -Force }
$zip = [System.IO.Compression.ZipFile]::Open($outZip, [System.IO.Compression.ZipArchiveMode]::Create, [System.Text.Encoding]::UTF8)
try {
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($src.Length + 1) -replace '\\', '/'
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $zip.Dispose()
}

# ---- 自印清单（重开读档核实）----
$check = [System.IO.Compression.ZipFile]::OpenRead($outZip)
try {
    $total = ($check.Entries | Measure-Object -Property Length -Sum).Sum
    Write-Host "=== diag-lite-v1.1.0.zip: $($check.Entries.Count) entries, $total bytes uncompressed ==="
    foreach ($e in $check.Entries) { Write-Host ("  {0}  ({1} bytes)" -f $e.FullName, $e.Length) }
} finally {
    $check.Dispose()
}
Write-Host "BUILD OK: $outZip"

#Requires -Version 5.1
<#
diag build.ps1 v1.8.0 —— 发群一键出包（v1.1.0 封装片 2026-10-23；白名单遍历 diag-lite/ 打 zip）
规则：ui/bg.jpg 与 ui/bg-light.jpg（1025 起为程序生成图，无版权限制）随包分发；reports/ 只带「报告在这里.txt」占位
     （真实报告 diag-*、repair-log.json、rollback/ 一律不入包）；其余全收（含 brand.png/favicon.png）。
用法：powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
产物：<仓库根>\diag-lite-v1.7.1.zip（.gitignore *.zip 已挡入库）；打完自印条目清单，字节抽验由验证脚本另行执行。
#>
param([switch]$Setup)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ($Setup) {
    # ---- 新形态出口（v1.2.0 片1）：csc 编 host.exe + 组 staging + ISCC 出 setup.exe ----
    # 不带 -Setup 跑 = 下方旧 lite zip 流程原样不动。
    $sroot = $PSScriptRoot
    $hostDir = Join-Path $sroot 'host'
    $hostOut = Join-Path $sroot 'build\host-out'
    $staging = Join-Path $sroot 'build\setup-staging'
    $buildDir = Join-Path $sroot 'build'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

    # 守卫 1：ISCC 在位（本机未装 Inno Setup 时给明确指引；6/7 皆可）
    $iscc = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup (6 or 7) not found. Install it from jrsoftware.org (default options) first, then rerun: powershell -File build.ps1 -Setup' }

    # 守卫 2：diag-lite staging 新鲜（keyfile 与源逐字节同，防把旧引擎打进安装器）
    foreach ($rel in @('server.ps1', 'engine/run.ps1', 'ui/index.html', 'ui/app.js', 'ui/style.css', 'ui/i18n/zh-CN.js', 'ui/i18n/en-US.js')) {
        $srcHash = (Get-FileHash -LiteralPath (Join-Path $sroot ($rel -replace '/', '\')) -Algorithm SHA256).Hash
        $liteHash = (Get-FileHash -LiteralPath (Join-Path $sroot (('diag-lite/' + $rel) -replace '/', '\')) -Algorithm SHA256).Hash
        if ($srcHash -ne $liteHash) { throw "diag-lite staging is stale: $rel differs from source. Sync diag-lite first, then rerun -Setup." }
    }

    # 守卫 3：WebView2 bootstrapper 在位（异机缺 runtime 引导）
    if (-not (Test-Path -LiteralPath (Join-Path $sroot 'installer\bootstrapper\MicrosoftEdgeWebview2Setup.exe'))) {
        throw 'WebView2 bootstrapper missing. Download https://go.microsoft.com/fwlink/p/?LinkId=2124703 into installer\bootstrapper\'
    }

    New-Item -ItemType Directory -Force -Path $hostOut, $staging, $buildDir | Out-Null

    # 步骤 1：csc 编 host.exe（免 SDK，WinForms+WebView2 薄壳）
    $cscArgs = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001',
        ('/win32icon:"' + (Join-Path $hostDir 'app.ico') + '"'),
        ('/out:"' + (Join-Path $hostOut 'host.exe') + '"'),
        ('/r:"' + (Join-Path $hostDir 'third_party\Microsoft.Web.WebView2.Core.dll') + '"'),
        ('/r:"' + (Join-Path $hostDir 'third_party\Microsoft.Web.WebView2.WinForms.dll') + '"'),
        '/r:System.dll', '/r:System.Core.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll',
        ('"' + (Join-Path $hostDir 'Program.cs') + '"'))
    & $csc @cscArgs
    if ($LASTEXITCODE -ne 0) { throw "csc failed: $LASTEXITCODE" }
    # csc 只产 host.exe；引用的 WebView2 托管 dll 要随包分发——从 third_party 同步进 hostOut
    # （1024 修复：此前靠 host-out 里的一次性手工副本，clean 重建即断链；现在构建自足）
    Copy-Item (Join-Path $hostDir 'third_party\Microsoft.Web.WebView2.Core.dll') $hostOut -Force
    Copy-Item (Join-Path $hostDir 'third_party\Microsoft.Web.WebView2.WinForms.dll') $hostOut -Force
    # staging 先清空再组——只加不减式 Copy 会把已剔除件（gui 等）残留打进新包
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Copy-Item (Join-Path $hostOut '*') $staging -Force
    Copy-Item (Join-Path $hostDir 'third_party\x64\WebView2Loader.dll') $staging -Force

    # 步骤 2：组 staging = diag-lite 全量（bg 双图随包）+ host 四件
    Copy-Item (Join-Path $sroot 'diag-lite\*') $staging -Recurse -Force
    # 运行时用户数据不进安装包（对齐头注释声明）：修复历史+真实报告+回滚包（防升级覆盖回滚/本机数据外发）
    Remove-Item (Join-Path $staging 'reports\repair-log.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $staging 'reports\diag-*') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $staging 'reports\rollback') -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($f in @('host.exe', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $staging $f))) { throw "staging incomplete: $f" }
    }

    # 步骤 3：ISCC 出 setup.exe（文件名由 .iss 的 OutputBaseFilename 决定，1025 起英文化）
    & $iscc (Join-Path $sroot 'installer\diag-setup.iss')
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed: $LASTEXITCODE" }
    # 注：本行曾用「Get-ChildItem ... | Select-Object -First 1」管道式在脚本内稳定报
    # 「FileInfo→SwitchParameter 绑定错」（单独复现不报、BOM 正常，根因未定案）——改数组式绕行，语义不变。
    $setupFiles = @(Get-ChildItem -Path (Join-Path $sroot 'build') -Filter 'PC-CheckupBench-setup-v*.exe')
    if ($setupFiles.Count -ne 1 -or $setupFiles[0].Length -lt 1000000) { throw 'setup.exe missing or suspiciously small' }
    Write-Host ("SETUP BUILD OK: {0} ({1} bytes)" -f $setupFiles[0].Name, $setupFiles[0].Length)

    # 步骤 4（哈希公示）：出包即写 .sha256 旁文件 + RELEASES.md 累积记录（分发完整性）
    $sha = (Get-FileHash -LiteralPath $setupFiles[0].FullName -Algorithm SHA256).Hash
    [System.IO.File]::WriteAllText(($setupFiles[0].FullName + '.sha256'), ($sha + '  ' + $setupFiles[0].Name + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    $relLog = Join-Path $buildDir 'RELEASES.md'
    $relLine = ("| {0} | {1} | {2} | {3} |" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $setupFiles[0].Name, $setupFiles[0].Length, $sha)
    if (-not (Test-Path $relLog)) {
        [System.IO.File]::WriteAllText($relLog, ("# RELEASES（出包记录：时间 | 文件 | 字节 | SHA256）`r`n`r`n" + $relLine + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    } else {
        [System.IO.File]::AppendAllText($relLog, ($relLine + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    }
    Write-Host ("HASH PUBLISHED: {0}" -f $sha)
    return
}


$root = $PSScriptRoot
$src = Join-Path $root 'diag-lite'
$outZip = Join-Path $root 'diag-lite-v1.7.1.zip'
$placeholder = 'reports/报告在这里.txt'

# ---- 守卫：打包面关键件在位，残缺即停 ----
foreach ($rel in @('engine/run.ps1', 'server.ps1', 'ui/index.html', 'ui/app.js', 'ui/style.css')) {
    if (-not (Test-Path (Join-Path $src ($rel -replace '/', '\')))) { throw "missing staging file: $rel" }
}
if (-not (Test-Path (Join-Path $src ($placeholder -replace '/', '\')))) { throw "missing reports placeholder" }
# v1.1.0 ext 口子四件（README+示例检查/树/动作）必须在打包面——发出去的包要自带「怎么加检查」的说明
foreach ($rel in @('ext/README.txt', 'ext/示例/checks/demo_ext_check.ps1', 'ext/示例/trees/演示体检.yaml', 'ext/示例/repair/demo_ext_guide.json')) {
    if (-not (Test-Path (Join-Path $src ($rel -replace '/', '\')))) { throw "missing ext staging file: $rel" }
}
$batCount = @(Get-ChildItem (Join-Path $src '*.bat')).Count
if ($batCount -ne 10) { throw "expect 10 bat launchers (8 functional + install/uninstall; v1.6.0 安全体检.bat), got $batCount" }
foreach ($b in @('一键安装.bat', '一键卸载.bat')) {
    if (-not (Test-Path (Join-Path $src $b))) { throw "missing installer bat: $b" }
}

# ---- 白名单遍历 ----
$files = @()
Get-ChildItem $src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1) -replace '\\', '/'
    if ($rel -like 'reports/*' -and $rel -ne $placeholder) { return }          # reports 只带占位（bg 双图 1025 起随包）
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
    Write-Host "=== diag-lite-v1.7.1.zip: $($check.Entries.Count) entries, $total bytes uncompressed ==="
    foreach ($e in $check.Entries) { Write-Host ("  {0}  ({1} bytes)" -f $e.FullName, $e.Length) }
} finally {
    $check.Dispose()
}
Write-Host "BUILD OK: $outZip"

# 哈希公示：lite zip 同样出 .sha256 旁文件
$zipSha = (Get-FileHash -LiteralPath $outZip -Algorithm SHA256).Hash
[System.IO.File]::WriteAllText(($outZip + '.sha256'), ($zipSha + '  ' + (Split-Path $outZip -Leaf) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("HASH PUBLISHED: {0}" -f $zipSha)

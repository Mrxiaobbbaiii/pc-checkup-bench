#Requires -Version 5.1
<#
检查项：bs_minidump_inventory —— dump 现场盘点（层：evidence）
命令：枚举 C:\Windows\Minidump\*.dmp + C:\Windows\MEMORY.DMP（名/大小/时间，只读）+ 1001 蓝屏史条数
判定：有 dump→PASS 附清单（可深度分析素材）；无 dump 但有蓝屏史→PASS 附 WARN（1001 记录过 dump 但文件已被清理）；无蓝屏史→SKIP；目录枚举权限不足→SKIP（无法判定）
mock 契约：===PART=== 两段：段1=dump 清单（`文件名 | KB | 日期`，空则 NONE），段2=蓝屏史条数（数字）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$dumps = @()
$histCount = -1
$probeNote = ''
if ($MockRaw -ne '' -or $MockFile -ne '') {
    $parts = @($MockRaw -split '===PART===' | ForEach-Object { $_.Trim("`r`n") })
    $listPart = $parts[0]
    if ($parts.Count -gt 1) { [void][int]::TryParse($parts[1].Trim(), [ref]$histCount) }
    if ($listPart.Trim() -ne '' -and $listPart.Trim() -ne 'NONE') {
        foreach ($ln in ($listPart -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $f = $ln -split '\s*\|\s*', 3
            $dumps += [PSCustomObject]@{ name = $f[0].Trim(); kb = $f[1].Trim(); date = $f[2].Trim() }
        }
    }
} else {
    try {
        $minidumpDir = 'C:\Windows\Minidump'
        if (Test-Path -LiteralPath $minidumpDir -PathType Container) {
            $dumps += @(Get-ChildItem -LiteralPath $minidumpDir -Filter *.dmp -ErrorAction Stop | ForEach-Object {
                [PSCustomObject]@{ name = $_.Name; kb = [string][int][math]::Ceiling($_.Length / 1KB); date = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
            })
            $probeNote += "Minidump 目录可枚举；"
        } else {
            $probeNote += "Minidump 目录不存在；"
        }
        if (Test-Path -LiteralPath 'C:\Windows\MEMORY.DMP' -PathType Leaf) {
            $m = Get-Item -LiteralPath 'C:\Windows\MEMORY.DMP' -ErrorAction Stop
            $dumps += [PSCustomObject]@{ name = $m.Name; kb = [string][int][math]::Ceiling($m.Length / 1KB); date = $m.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
            $probeNote += "MEMORY.DMP 存在；"
        } else {
            $probeNote += "MEMORY.DMP 不存在；"
        }
    } catch {
        [PSCustomObject]@{
            name = 'bs_minidump_inventory'; status = 'SKIP'
            evidence = "[枚举 C:\Windows\Minidump / MEMORY.DMP] 权限不足或 IO 错（$($_.Exception.Message)），无法判定 dump 存亡"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'probe-denied' }
        } | ConvertTo-Json -Depth 5
        return
    }
    # 蓝屏史条数（同源 1001 查询，只读取证）
    try {
        $hist = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-90) } -ErrorAction Stop)
        $histCount = $hist.Count
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEvents') { $histCount = 0 } else {
            [PSCustomObject]@{
                name = 'bs_minidump_inventory'; status = 'SKIP'
                evidence = "[Get-WinEvent System Id=1001 近90天] 查询失败（无法判定）：$($_.Exception.Message)"
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
            } | ConvertTo-Json -Depth 5
            return
        }
    }
}

$cmdTag = '[枚举 C:\Windows\Minidump\*.dmp + C:\Windows\MEMORY.DMP]'
if ($dumps.Count -ge 1) {
    $status = 'PASS'
    $lines = ($dumps | ForEach-Object { '{0} | {1} KB | {2}' -f $_.name, $_.kb, $_.date }) -join "`n"
    $evidence = "$cmdTag`n$lines`n（dump 在=下次蓝屏可送深度分析的素材，别手动清理）"
    $suggestion = ''
} elseif ($histCount -ge 1) {
    $status = 'PASS'
    $evidence = "$cmdTag`n未发现 dump 文件，但近 90 天有 $histCount 条 1001 蓝屏记录 → [WARN] 1001 记录过 dump 但文件已被清理（证据丢失）$probeNote"
    $suggestion = ''
} elseif ($histCount -eq 0) {
    $status = 'SKIP'
    $evidence = "$cmdTag`n无 dump 且近 90 天无蓝屏史（0 条 1001），无可盘点对象"
    $suggestion = ''
} else {
    # histCount 仍为 -1=未知（防御分支，正常不可达）
    $status = 'SKIP'
    $evidence = "$cmdTag`n蓝屏史条数未知，无法判定"
    $suggestion = ''
}

[PSCustomObject]@{
    name       = 'bs_minidump_inventory'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ dumps = $dumps; historyCount = $histCount; probe = $probeNote }
} | ConvertTo-Json -Depth 5

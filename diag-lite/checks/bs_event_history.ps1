#Requires -Version 5.1
<#
检查项：bs_event_history —— 蓝屏史（近 90 天 WER 1001 事件）
层：history。命令：Get-WinEvent System Id=1001 Provider=Microsoft-Windows-WER-SystemErrorReporting StartTime=-90d（只读）
判定：0 条→PASS（近 90 天无蓝屏史）；≥1 条→FAIL（附 日期+码+dump 清单）；Get-WinEvent 权限等服务异常→SKIP（无匹配事件=合法 0 条）
mock 契约：逐行 `yyyy-MM-dd HH:mm | 0x00000139 | C:\WINDOWS\Minidump\xxx.dmp`（真实 1001 消息简化为管道分隔；dump 字段可缺省）
注：真实 1001 消息里码恒为 0x+8 位十六进制、dump 路径以 .dmp 结尾，均为 ASCII 恒定锚，不依赖系统语言。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$records = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        if ($ln -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*\|\s*(0x[0-9A-Fa-f]{1,8})\s*\|\s*(.*)$') {
            $records += [PSCustomObject]@{ time = $Matches[1]; code = $Matches[2]; dump = $Matches[3].Trim() }
        }
    }
} else {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-90) } -ErrorAction Stop)
        foreach ($e in $events) {
            $code = if ($e.Message -match '0x[0-9A-Fa-f]{8}') { $Matches[0] } else { '-' }
            $dump = if ($e.Message -match '[A-Za-z]:\\[^\s"]+\.dmp') { $Matches[0] } else { '-' }
            $records += [PSCustomObject]@{ time = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'); code = $code; dump = $dump }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEvents') {
            $records = @()   # 90 天无 1001 记录=合法空态，不是错误
        } else {
            [PSCustomObject]@{
                name = 'bs_event_history'; status = 'SKIP'
                evidence = "[Get-WinEvent System Id=1001 近90天] 查询失败（无法判定）：$($_.Exception.Message)"
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
            } | ConvertTo-Json -Depth 5
            return
        }
    }
}

$cmdTag = '[Get-WinEvent System Id=1001 Provider=WER-SystemErrorReporting 近90天]'
if ($records.Count -eq 0) {
    $status = 'PASS'
    $evidence = "$cmdTag`n近 90 天无蓝屏史（0 条 1001 记录）"
    $suggestion = ''
} else {
    $status = 'FAIL'
    $evidence = $cmdTag + "`n" + (($records | ForEach-Object { '{0} | {1} | {2}' -f $_.time, $_.code, $_.dump }) -join "`n")
    $suggestion = "近 90 天有 $($records.Count) 次真蓝屏（WER 1001 记录——WER 是 Windows 的错误上报机制，日期/蓝屏码/dump 明细见证据）。蓝屏码什么含义、是不是「同码复发=慢性病」，看下一层「蓝屏码频次」（自带常见蓝屏码的人话翻译）。`n【修复命令，请自己执行】无即时命令——先看归因层结论再动手（驱动/硬件方向修法完全不同）。`n【回滚】不适用（本项只读取证）"
}

[PSCustomObject]@{
    name       = 'bs_event_history'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ records = $records; count = $records.Count }
} | ConvertTo-Json -Depth 5

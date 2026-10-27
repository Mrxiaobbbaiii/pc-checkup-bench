#Requires -Version 5.1
<#
检查项：hw_memdiag_history —— Windows 内存诊断结果史（层：memory_board）
命令：Get-WinEvent Provider=Microsoft-Windows-MemoryDiagnostics-Results（全历史）；只读
判定（消息优先，知识来源 §十 2026-10-27 修正；旧「1101=检出硬件问题/1102=无问题」ID 硬映射作废——1101 实际语义=detected no errors（通过），本机 10-13 事件原文实证）：
  Message 含 hardware problems→FAIL（检出硬件问题：mdsched 复核/送修）；含 no errors→PASS；两者都不含（无法判读）→SKIP(unrecognized-result)；无任何事件（从未跑过系统内存诊断，常态）→SKIP
ID 仅进 evidence 展示，不参与判定分支。
mock 契约：逐行 `MM-dd | ID | 结论短语`（如 `03-02 | 1101 | no errors`）；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$events = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        if ($ln -match '^(\d{2}-\d{2})\s*\|\s*(\d+)\s*\|\s*(.+?)\s*$') { $events += [PSCustomObject]@{ date = $Matches[1]; id = $Matches[2]; msg = $Matches[3] } }
    }
} else {
    try {
        foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -ErrorAction Stop)) {
            $events += [PSCustomObject]@{ date = $e.TimeCreated.ToString('MM-dd'); id = [string]$e.Id; msg = (([string]$e.Message) -replace '\s+', ' ').Trim() }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEvents') { $events = @() } else {
            [PSCustomObject]@{
                name = 'hw_memdiag_history'; status = 'SKIP'
                evidence = "[Get-WinEvent MemoryDiagnostics-Results] 查询失败（无法判定）：$($_.Exception.Message)"
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
            } | ConvertTo-Json -Depth 5
            return
        }
    }
}

$cmdTag = '[Get-WinEvent System Provider=MemoryDiagnostics-Results 全历史]'
if ($events.Count -eq 0) {
    [PSCustomObject]@{
        name = 'hw_memdiag_history'; status = 'SKIP'
        evidence = "$cmdTag`n无内存诊断记录（从未跑过 mdsched.exe=常态）——不是「内存没病」，是没查过"
        suggestion = '想立内存基线：【修复命令，请自己执行】mdsched.exe（Windows 内存诊断，重启后自动跑约十几分钟，结果回本事件日志）'; detail = [PSCustomObject]@{ reason = 'never-run' }
    } | ConvertTo-Json -Depth 5
    return
}

function Get-Excerpt([string]$m) { if ($m.Length -gt 120) { $m.Substring(0, 120) + '...' } else { $m } }

$bad = @($events | Where-Object { $_.msg -match 'hardware\s+problems' })
$okEvents = @($events | Where-Object { $_.msg -match 'no\s+errors' })
$lines = ($events | ForEach-Object { '{0} | {1} | {2}' -f $_.date, $_.id, (Get-Excerpt $_.msg) }) -join "`n"
if ($bad.Count -ge 1) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n$lines"
    $suggestion = "Windows 内存诊断检出硬件问题（检出 $($bad.Count) 条，日期见证据）：内存条/插槽/兼容性嫌疑。`n【修复命令，请自己执行】mdsched.exe 再跑一轮复核；多内存条=拔到单条轮测定位坏条；确认坏=送修/换条。`n【回滚】不适用（只读检测+复测）"
} elseif ($okEvents.Count -ge 1) {
    $status = 'PASS'
    $evidence = "$cmdTag`n$lines"
    $suggestion = ''
} else {
    [PSCustomObject]@{
        name = 'hw_memdiag_history'; status = 'SKIP'
        evidence = "$cmdTag`n$lines`n结论原文无法判读（不含已知结论短语）——诚实跳过不硬判，人工看一眼 mdsched 结果页"
        suggestion = ''
        detail = [PSCustomObject]@{ reason = 'unrecognized-result'; events = $events; badCount = 0 }
    } | ConvertTo-Json -Depth 5
    return
}
[PSCustomObject]@{
    name = 'hw_memdiag_history'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ events = $events; badCount = $bad.Count }
} | ConvertTo-Json -Depth 5

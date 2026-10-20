#Requires -Version 5.1
<#
检查项：hw_memdiag_history —— Windows 内存诊断结果史（层：memory_board）
命令：Get-WinEvent Provider=Microsoft-Windows-MemoryDiagnostics-Results（1101=检测到硬件问题/1102=无问题，全历史）；只读
判定（design 第十节 5）：有 1101→FAIL（已报硬件问题：memtest86+ 复核/送修）；仅 1102→PASS；无任何事件（从未跑过系统内存诊断，常态）→SKIP
mock 契约：逐行 `MM-dd | 1101`（或 `1102`）；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$events = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        if ($ln -match '^(\d{2}-\d{2})\s*\|\s*(110[12])') { $events += [PSCustomObject]@{ date = $Matches[1]; id = $Matches[2] } }
    }
} else {
    try {
        foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -ErrorAction Stop)) {
            $events += [PSCustomObject]@{ date = $e.TimeCreated.ToString('MM-dd'); id = [string]$e.Id }
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

$bad = @($events | Where-Object { $_.id -eq '1101' })
$lines = ($events | ForEach-Object { '{0} | {1}' -f $_.date, $_.id }) -join "`n"
if ($bad.Count -ge 1) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n$lines"
    $suggestion = "Windows 内存诊断报过硬件问题（1101×$($bad.Count)）：内存条/插槽/兼容性嫌疑。`n【修复命令，请自己执行】mdsched.exe 再跑一轮复核；多内存条=拔到单条轮测定位坏条；确认坏=送修/换条。`n【回滚】不适用（只读检测+复测）"
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n$lines"
    $suggestion = ''
}
[PSCustomObject]@{
    name = 'hw_memdiag_history'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ events = $events; badCount = $bad.Count }
} | ConvertTo-Json -Depth 5

#Requires -Version 5.1
<#
检查项：bs_whea_hardware —— WHEA 硬件层报错（层：attribution）
命令：Get-WinEvent System Provider=Microsoft-Windows-WHEA-Logger 近 30 天（只读）
判定：≥1 条→FAIL（硬件层事件：内存/CPU/PCIe 报错，附日期与消息首行摘要）；0 条→PASS；查询异常→SKIP
mock 契约：逐行 `MM-dd | 消息首行`
注：判定只看事件条数不看消息内容（消息文案随系统语言变，日期/条数恒定）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$items = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        if ($ln -match '^(\d{2}-\d{2})\s*\|\s*(.*)$') {
            $items += [PSCustomObject]@{ date = $Matches[1]; summary = $Matches[2].Trim() }
        }
    }
} else {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop)
        foreach ($e in $events) {
            $firstLine = ($e.Message -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
            if (-not $firstLine) { $firstLine = '(消息为空)' }
            $items += [PSCustomObject]@{ date = $e.TimeCreated.ToString('MM-dd'); summary = $firstLine.Trim() }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEvents') { $items = @() } else {
            [PSCustomObject]@{
                name = 'bs_whea_hardware'; status = 'SKIP'
                evidence = "[Get-WinEvent System Provider=WHEA-Logger 近30天] 查询失败（无法判定）：$($_.Exception.Message)"
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
            } | ConvertTo-Json -Depth 5
            return
        }
    }
}

$cmdTag = '[Get-WinEvent System Provider=WHEA-Logger 近30天]'
if ($items.Count -ge 1) {
    $status = 'FAIL'
    $lines = ($items | Select-Object -First 10 | ForEach-Object { '{0} | {1}' -f $_.date, $_.summary }) -join "`n"
    $evidence = "$cmdTag`n$lines"
    if ($items.Count -gt 10) { $evidence += "`n…（共 $($items.Count) 条，只列前 10）" }
    $suggestion = "近 30 天有 $($items.Count) 条 WHEA 硬件层报错（日期+摘要见证据）：内存/CPU/PCIe/供电硬件嫌疑。`n【修复命令，请自己执行】跑 Windows 内存诊断 mdsched.exe（重启后自动检测内存，约十几分钟）；台式机顺手查温度与超频设置（XMP/超频先回默认观察）。`n【回滚】不适用（只读检测；BIOS 设置如改动，记住原值可改回）"
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n近 30 天无 WHEA 硬件报错（0 条）"
    $suggestion = ''
}

[PSCustomObject]@{
    name       = 'bs_whea_hardware'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ items = $items; count = $items.Count }
} | ConvertTo-Json -Depth 5

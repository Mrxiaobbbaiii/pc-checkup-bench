#Requires -Version 5.1
<#
检查项：bs_powerloss_distinction —— 掉电/死机与蓝屏辨别（层：history）
命令：Get-WinEvent System Id=41(Microsoft-Windows-Kernel-Power) + Id=1001(WER) 近 90 天（只读）
判定：41 与任一 1001 时间差 ≤2 分钟=同一次蓝屏（配对掉）；孤立 41 ≥2 次→FAIL（频繁掉电/死机：电源/过热/强制关机嫌疑）；孤立 ≤1 次→PASS 附注
mock 契约：===PART=== 两段：段1=41 事件逐行时间，段2=1001 逐行时间；行格式 `yyyy-MM-dd HH:mm`
注：中国无夏令时，分钟级配对无时钟漂移风险（1019 自问挂起项）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function ConvertTo-Timestamps { param([string]$Text)
    $list = @()
    foreach ($ln in ($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        if ($ln -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})') {
            try { $list += [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm', $null) } catch { }
        }
    }
    return ,$list
}

$parts = @($MockRaw -split '===PART===' | ForEach-Object { $_.Trim("`r`n") })
$t41 = @(); $t1001 = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    $t41 = ConvertTo-Timestamps $parts[0]
    if ($parts.Count -gt 1) { $t1001 = ConvertTo-Timestamps $parts[1] }
} else {
    try {
        $e41 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = (Get-Date).AddDays(-90) } -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEvents') {
            [PSCustomObject]@{
                name = 'bs_powerloss_distinction'; status = 'SKIP'
                evidence = "[Get-WinEvent System Id=41 近90天] 查询失败（无法判定）：$($_.Exception.Message)"
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
            } | ConvertTo-Json -Depth 5
            return
        }
        $e41 = @()
    }
    try {
        $e1001 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-90) } -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEvents') {
            [PSCustomObject]@{
                name = 'bs_powerloss_distinction'; status = 'SKIP'
                evidence = "[Get-WinEvent System Id=1001 近90天] 查询失败（无法判定）：$($_.Exception.Message)"
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
            } | ConvertTo-Json -Depth 5
            return
        }
        $e1001 = @()
    }
    # 与 mock 同一条判定路径：真实事件也先转成同格式时间行
    $t41 = ConvertTo-Timestamps (($e41 | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') }) -join "`n")
    $t1001 = ConvertTo-Timestamps (($e1001 | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') }) -join "`n")
}

# 配对：41 与任一 1001 差 ≤2 分钟=同一次蓝屏
$isolated = @($t41 | Where-Object {
    $t = $_
    @($t1001 | Where-Object { [math]::Abs(($_ - $t).TotalMinutes) -le 2.0 }).Count -eq 0
})

$cmdTag = '[Get-WinEvent System Id=41(Kernel-Power) / Id=1001(WER) 近90天]'
$statLine = "41 事件 $($t41.Count) 条（配对蓝屏 $($t41.Count - $isolated.Count) / 孤立 $($isolated.Count)），1001 事件 $($t1001.Count) 条"
if ($isolated.Count -ge 2) {
    $status = 'FAIL'
    $isoLines = ($isolated | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm') }) -join '，'
    $evidence = "$cmdTag`n$statLine`n孤立 41 时间：$isoLines"
    $suggestion = "近 90 天有 $($isolated.Count) 次掉电/死机（Kernel-Power 41 且无蓝屏 1001 伴随，时间见证据）：电源/过热/强制关机嫌疑（长按电源键也算）。`n【修复命令，请自己执行】无命令可修——物理排查：台式机查电源线/插座/电源本体老化；清灰查散热（过热保护性断电高发）；笔记本查电池健康 powercfg /batteryreport。`n【回滚】不适用（物理操作）"
} elseif ($t41.Count -ge 1) {
    $status = 'PASS'
    $evidence = "$cmdTag`n$statLine（41 均与蓝屏配对或孤立 ≤1 次，不算独立掉电隐患）"
    $suggestion = ''
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n$statLine（近 90 天无 41 也无 1001 记录）"
    $suggestion = ''
}

[PSCustomObject]@{
    name       = 'bs_powerloss_distinction'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ total41 = $t41.Count; total1001 = $t1001.Count; isolated41 = $isolated.Count }
} | ConvertTo-Json -Depth 5

#Requires -Version 5.1
<#
检查项：sec_defender_threats —— 近 30 天病毒检出记录（层：defender）
命令：Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Windows Defender/Operational'; Id=1006,1007,1008,1116,1117,1118,1119; StartTime=(Get-Date).AddDays(-30) }（只读）
判定（安全树规格 v1.6 第一节 3）：日志不存在/被禁用/查询异常→SKIP(query-error)；0 条事件→PASS；
  存在 1008/1118/1119（处置失败/严重失败）→FAIL；处置数(1007+1117)<检出数(1006+1116)→FAIL（工程线：Allow 动作也计为已处置）；其余→PASS 附检出清单
判定只依赖事件 Id 数字（本地化消息只做展示）。事件 ID 出处：https://learn.microsoft.com/en-us/defender-endpoint/troubleshoot-microsoft-defender-antivirus
mock 契约：逐行 `时间 | Id | Name=… | Severity=… | Path=… | Action=…`（Action 可空；空输入=0 事件）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result { param($Status, $Evidence, $Suggestion, $Detail)
    [PSCustomObject]@{
        name = 'sec_defender_threats'; status = $Status; evidence = $Evidence; suggestion = $Suggestion; detail = $Detail
    } | ConvertTo-Json -Depth 6
}

function Get-EvField { param([string]$Msg, [string[]]$Labels)
    foreach ($chunk in ($Msg -split '\s{2,}')) {
        foreach ($lb in $Labels) {
            if ($chunk -match ('^' + [regex]::Escape($lb) + '\s*[:：]\s*(.+?)\s*$')) { return $Matches[1] }
        }
    }
    return ''
}

function Ev-Line { param($ev)
    if ($ev.id -eq 1007 -or $ev.id -eq 1117) {
        $act = if ($ev.action -ne '') { " → $($ev.action)" } else { '' }
        return "$($ev.time) 处置 $($ev.name)$act"
    }
    $verb = '检出'
    if ($ev.id -eq 1008 -or $ev.id -eq 1118) { $verb = '处置失败' }
    elseif ($ev.id -eq 1119) { $verb = '处置严重失败' }
    $sev = if ($ev.severity -ne '') { "（$($ev.severity)）" } else { '' }
    $pth = if ($ev.path -ne '') { " $($ev.path)" } else { '' }
    return "$($ev.time) $verb $($ev.name)$sev$pth"
}

$cmdTag = '[Get-WinEvent Microsoft-Windows-Windows Defender/Operational 1006,1007,1008,1116,1117,1118,1119 近30天]'
$ids = @(1006, 1007, 1008, 1116, 1117, 1118, 1119)
$events = @()

if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -lt 2) { continue }
        $idNum = 0
        if (-not [int]::TryParse($p[1].Trim(), [ref]$idNum)) { continue }
        $ev = [PSCustomObject]@{ time = $p[0].Trim(); id = $idNum; name = ''; severity = ''; path = ''; action = '' }
        for ($i = 2; $i -lt $p.Count; $i++) {
            $j = $p[$i].IndexOf('=')
            if ($j -le 0) { continue }
            $k = $p[$i].Substring(0, $j).Trim(); $v = $p[$i].Substring($j + 1).Trim()
            if ($k -eq 'Name') { $ev.name = $v }
            elseif ($k -eq 'Severity') { $ev.severity = $v }
            elseif ($k -eq 'Path') { $ev.path = $v }
            elseif ($k -eq 'Action') { $ev.action = $v }
        }
        $events += $ev
    }
} else {
    try {
        $log = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = $ids; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop)
        foreach ($e in $log) {
            $msg = [string]$e.Message
            $events += [PSCustomObject]@{
                time = $e.TimeCreated.ToString('yyyy/MM/dd HH:mm:ss')
                id = $e.Id
                name = Get-EvField $msg @('Name', '名称')
                severity = Get-EvField $msg @('Severity', '严重性')
                path = Get-EvField $msg @('Path', '路径')
                action = Get-EvField $msg @('Action', '操作')
            }
        }
    } catch {
        $exMsg = $_.Exception.Message
        $fid = [string]$_.FullyQualifiedErrorId
        if ($fid -match 'NoMatchingEventsFound' -or $exMsg -match 'No events were found|未找到|找不到') {
            $events = @()
        } else {
            Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：$exMsg" '' ([PSCustomObject]@{ reason = 'query-error'; error = $exMsg })
            return
        }
    }
}

$detected = @($events | Where-Object { $_.id -eq 1006 -or $_.id -eq 1116 }).Count
$remediated = @($events | Where-Object { $_.id -eq 1007 -or $_.id -eq 1117 }).Count
$failed = @($events | Where-Object { $_.id -eq 1008 -or $_.id -eq 1118 -or $_.id -eq 1119 }).Count

$body = (@($events | ForEach-Object { Ev-Line $_ }) -join "`n")
$head = $cmdTag
if ($body -ne '') { $head = "$cmdTag`n$body" }
$detail = [PSCustomObject]@{ detected = $detected; remediated = $remediated; failed = $failed; events = @($events) }

$suggestion = "近 30 天有病毒检出且存在未处置/处置失败的记录——查出来的东西可能还在机器上。`n【人工路径】Win+I →「隐私和安全性」→「Windows 安全中心」→「病毒和威胁防护」→「保护历史记录」——逐条看：状态不是「已隔离/已删除」的条目，点开按按钮处理；处理完点「快速扫描」复扫一轮。`n【回滚】不适用（清除威胁为目标动作）"

if ($failed -gt 0) {
    Out-Result 'FAIL' "$head`n结论：近 30 天检出 $detected 次，其中处置失败 $failed 次（事件 1008/1118/1119）——查出来的东西可能还在机器上" $suggestion $detail
} elseif ($remediated -lt $detected) {
    Out-Result 'FAIL' "$head`n结论：近 30 天检出 $detected 次、处置记录 $remediated 次——有检出无对应处置，威胁可能未被清除" $suggestion $detail
} else {
    $tail = if ($detected -gt 0) { "近 30 天检出 $detected 次，均有处置记录" } else { "近 30 天无任何检出记录" }
    Out-Result 'PASS' "$head`n$tail" '' $detail
}

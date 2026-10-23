#Requires -Version 5.1
<#
检查项：pf_app_crashes —— 应用崩溃/卡死史（层：runtime）
命令：Get-WinEvent Application 日志 近 30 天 id=1000（应用崩溃）/1002（应用卡死），只读
判定：按应用名聚合；任一应用 ≥2 次，或合计 ≥3 次 → FAIL（附 top 应用+次数）；合计 1-2 次且不重复 → PASS 附注；0 次 → PASS；Application 日志不可读 → SKIP
mock 契约：逐行 `EventID | 应用名 | 时间`；空=PASS（0 条）；首行 QUERY-ERROR=SKIP
语言无关：应用名优先取首个以 .exe 结尾的 Properties 值（1000/1002 首参恒为应用名）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$events = @()
$queryError = $false
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：Application 日志不可读'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            if ($p.Count -ge 1) {
                $eid = 0
                if (-not [int]::TryParse($p[0].Trim(), [ref]$eid)) { continue }
                $app = if ($p.Count -ge 2 -and $p[1].Trim() -ne '') { $p[1].Trim() } else { '未知应用' }
                $when = if ($p.Count -ge 3 -and $p[2].Trim() -ne '') { $p[2].Trim() } else { '时间未知' }
                $events += [PSCustomObject]@{ id = $eid; app = $app; when = $when }
            }
        }
    }
} else {
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = @(1000, 1002); StartTime = (Get-Date).AddDays(-30) } -MaxEvents 300 -ErrorAction Stop)
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'No events|找不到') { $evts = @() } else { $queryError = $true; $errText = $m }
    }
    if (-not $queryError) {
        foreach ($e in $evts) {
            if ($e.ProviderName -notmatch 'Application (Error|Hang)') { continue }
            $app = ''
            foreach ($prop in @($e.Properties)) {
                $v = [string]$prop.Value
                if ($v -match '(?i)\.exe$') { $app = $v; break }
            }
            if (-not $app) {
                foreach ($prop in @($e.Properties)) {
                    $v = [string]$prop.Value
                    if ($v -and $v -notmatch '^[\d\s]*$') { $app = $v; break }
                }
            }
            if (-not $app) { $app = '未知应用' }
            $app = ($app -split '[\\/]')[-1]
            $events += [PSCustomObject]@{ id = $e.Id; app = $app; when = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm') }
        }
    }
}

$cmdTag = '[Application 日志 1000 崩溃/1002 卡死 近30天]'
if ($queryError) {
    [PSCustomObject]@{
        name = 'pf_app_crashes'; status = 'SKIP'
        evidence = "$cmdTag`nApplication 日志不可读（无法判定）：$errText——不是「应用都稳定」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}

$grouped = @($events | Group-Object -Property app | Sort-Object -Property Count -Descending)
$top = @($grouped | Select-Object -First 5)
$topLines = ($top | ForEach-Object {
    $recent = @($_.Group | Select-Object -First 3 | ForEach-Object { $_.when }) -join '、'
    '{0} ×{1}（{2}）' -f $_.Name, $_.Count, $recent
}) -join "`n"

if ($events.Count -eq 0) {
    $status = 'PASS'
    $evidence = "$cmdTag`n0 次（近 30 天没有应用崩溃/卡死记录）"
    $suggestion = ''
} elseif ($events.Count -le 2 -and @($grouped | Where-Object { $_.Count -ge 2 }).Count -eq 0) {
    $status = 'PASS'
    $evidence = "$cmdTag`n共 $($events.Count) 次（少量且不重复，暂未见系统性崩溃）`n$topLines"
    $suggestion = ''
} else {
    $status = 'FAIL'
    $apps = @($top | ForEach-Object { $_.Name }) -join '、'
    $evidence = "$cmdTag`n共 $($events.Count) 次，涉及 $(@($grouped).Count) 个应用`n$topLines"
    $suggestion = "近 30 天应用崩溃/卡死共 $($events.Count) 次，点名：$apps。同一个应用反复崩溃，优先更新/重装它；多个不同应用都崩，常见于内存/驱动/安全软件冲突，转「硬件体检」看内存诊断与 WHEA。`n【修复命令，请自己执行】无（按应用名更新/重装；反复崩溃可卸载重装或换版本）`n【回滚】不需要（本检查只读，未改任何设置）"
}

[PSCustomObject]@{
    name = 'pf_app_crashes'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ total = $events.Count; groups = $top | ForEach-Object { @{ app = $_.Name; count = $_.Count; recent = @($_.Group | Select-Object -First 5 | ForEach-Object { $_.when }) } } }
} | ConvertTo-Json -Depth 6

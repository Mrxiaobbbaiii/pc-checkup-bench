#Requires -Version 5.1
<#
检查项：pf_boot_degradation_events —— Windows 点名拖慢开机事件（层：boot）
命令：Get-WinEvent 'Microsoft-Windows-Diagnostics-Performance/Operational' 近 30 天 id=101/103 且 Level≥Warning（101=应用拖慢启动、103=服务拖慢启动，微软点名事件，只读）
判定：≥3 条→FAIL（附 top5 谁拖了多少毫秒）；1-2 条→PASS 附注清单；0 条→PASS；日志不可读→SKIP
只收 101/103：102/106/108/110 等=实拍确认后才扩（design 铁则，本版禁预收）
mock 契约：逐行 `EventID | who | ms`；空=PASS（0 条）；首行 QUERY-ERROR=SKIP
语言无关：who/ms 从 ToXml() 的 EventData 抓（Name/FileName/ServiceName 类=who，DegradationTime 无则 TotalTime=ms），不靠消息文案。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$logName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
$items = @()
$queryError = $false
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：日志不可读'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            if ($p.Count -ge 2) { $items += [PSCustomObject]@{ id = [int]$p[0].Trim(); who = $p[1].Trim(); ms = $(if ($p.Count -ge 3) { [long]($p[2].Trim() -replace '[^\d]', '') } else { 0 }) } }
        }
    }
} else {
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Id = @(101, 103); StartTime = (Get-Date).AddDays(-30) } -MaxEvents 200 -ErrorAction Stop | Where-Object { $_.Level -ge 1 -and $_.Level -le 3 })
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'No events|找不到') { $evts = @() } elseif ($m -match '权限|提升|unauthorized|not authorized') { $queryError = $true; $errText = "$m（该日志需管理员权限读取——管理员身份运行可复核）" } else { $queryError = $true; $errText = $m }
    }
    if (-not $queryError) {
        foreach ($e in $evts) {
            $xml = $e.ToXml()
            $who = ''; $ms = $null
            foreach ($dm in [regex]::Matches($xml, '<Data\s+Name=["'']([^"'']+)["'']\s*>\s*(.*?)\s*</Data>')) {
                $k = $dm.Groups[1].Value; $v = $dm.Groups[2].Value
                if (-not $who -and $k -in @('FileName', 'Name', 'ServiceName', 'ImageName')) { $who = $v }
                if ($k -eq 'DegradationTime') { $ms = [long]($v -replace '[^\d]', '') }
                if ($k -eq 'TotalTime' -and $null -eq $ms) { $ms = [long]($v -replace '[^\d]', '') }
            }
            if (-not $who -and @($e.Properties).Count -gt 0) { $who = [string]$e.Properties[0].Value }
            if ($null -eq $ms) { $ms = 0 }
            $items += [PSCustomObject]@{ id = $e.Id; who = $who; ms = $ms }
        }
    }
}

$cmdTag = '[Diagnostics-Performance id=101/103 近30天 Warning+]'
if ($queryError) {
    [PSCustomObject]@{
        name = 'pf_boot_degradation_events'; status = 'SKIP'
        evidence = "$cmdTag`n日志不可读（无法判定）：$errText——不是「没人拖慢」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}

$top = @($items | Sort-Object -Property ms -Descending | Select-Object -First 5)
$topLines = ($top | ForEach-Object { '{0} 拖慢启动: {1} {2}ms' -f $_.id, $_.who, $_.ms }) -join "`n"

if ($items.Count -eq 0) {
    $status = 'PASS'
    $evidence = "$cmdTag`n0 条（近 30 天 Windows 未点名任何应用/服务拖慢启动）"
    $suggestion = ''
} elseif ($items.Count -le 2) {
    $status = 'PASS'
    $evidence = "$cmdTag`n共 $($items.Count) 条（少量，未见系统性拖累）`n$topLines"
    $suggestion = ''
} else {
    $status = 'FAIL'
    $evidence = "$cmdTag`n共 $($items.Count) 条`n$topLines"
    $suggestion = "近 30 天被 Windows 点名拖慢开机 $($items.Count) 次（101=应用、103=服务，微软官方点名非本工具猜测）。对上号的自启在任务管理器→「启动应用」里禁用；服务类点名的，按服务名卸载对应软件。`n【修复命令，请自己执行】无（手动操作：任务管理器→启动应用 右键禁用）`n【回滚】同一位置右键重新启用"
}

[PSCustomObject]@{
    name = 'pf_boot_degradation_events'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ count = $items.Count; top = $top }
} | ConvertTo-Json -Depth 6

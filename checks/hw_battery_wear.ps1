#Requires -Version 5.1
<#
检查项：hw_battery_wear —— 电池损耗（层：power_thermal）
命令：Win32_Battery（有无电池）＋ root\wmi BatteryStaticData(DDesignedCapacity)/BatteryFullChargedCapacity(FullChargedCapacity)；全只读
判定（design 第十节 3）：损耗=(设计−满充)/设计 ≥40%→FAIL（重度损耗：续航崩/鼓包风险，建议换电池）；<40%→PASS 附损耗数；无电池（台式）→SKIP
mock 契约：两行 `Designed | <mWh>`、`FullCharged | <mWh>`；空=SKIP（无电池）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$designed = $null; $full = $null
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p[0] -eq 'Designed') { $designed = [long]$p[1] }
        elseif ($p[0] -eq 'FullCharged') { $full = [long]$p[1] }
    }
} else {
    try {
        $bat = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        if ($bat.Count -eq 0) { $designed = $null } else {
            $sd = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1
            $fc = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
            if ($sd -and $fc) { $designed = [long]$sd.DesignedCapacity; $full = [long]$fc.FullChargedCapacity }
        }
    } catch {
        [PSCustomObject]@{
            name = 'hw_battery_wear'; status = 'SKIP'
            evidence = "[Win32_Battery + root\wmi Battery*] 查询失败（无法判定）：$($_.Exception.Message)"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
}

$cmdTag = '[Win32_Battery + root\wmi BatteryStaticData/BatteryFullChargedCapacity]'
if ($null -eq $designed -or $null -eq $full -or $designed -le 0) {
    [PSCustomObject]@{
        name = 'hw_battery_wear'; status = 'SKIP'
        evidence = "$cmdTag`n无电池或容量数据不暴露（台式机=正常）——本项不适用"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-battery' }
    } | ConvertTo-Json -Depth 5
    return
}

$wearPct = [math]::Round(($designed - $full) * 100.0 / $designed, 1)
$evidence = "$cmdTag`n设计容量 {0} mWh，当前满充 {1} mWh → 损耗 {2}%" -f $designed, $full, $wearPct
if ($wearPct -ge 40) {
    $status = 'FAIL'
    $suggestion = "电池损耗 $wearPct%（≥40% 重度）：续航显著缩水，老化电池有鼓包风险。`n【修复命令，请自己执行】powercfg /batteryreport（只读，生成本机电池报告核对充放循环）；换电池前用报告确认型号/循环次数。`n【回滚】不适用（只读检测）"
} else {
    $status = 'PASS'
    $suggestion = ''
}
[PSCustomObject]@{
    name = 'hw_battery_wear'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ designedMWh = $designed; fullChargedMWh = $full; wearPct = $wearPct }
} | ConvertTo-Json -Depth 5

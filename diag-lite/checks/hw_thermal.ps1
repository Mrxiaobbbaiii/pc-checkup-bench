#Requires -Version 5.1
<#
检查项：hw_thermal —— ACPI 热区温度（层：power_thermal）
命令：root\wmi MSAcpi_ThermalZoneTemperature（CurrentTemperature，0.1K→℃）；只读
判定（design 第十节 4）：任一热区 >75℃→FAIL（过热：清灰/风扇/硅脂）；全 ≤75℃→PASS 附读数；无热区暴露（台式常见）→SKIP；读数无效（≤0℃ 或 >120℃=ACPI 假值机型）→SKIP 附注「热区读数不可信」
mock 契约：逐行 `InstanceName | tempC`；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$zones = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -ge 2) { $zones += [PSCustomObject]@{ zone = $p[0]; tempC = [double]$p[1] } }
    }
} else {
    try {
        foreach ($t in @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)) {
            if ($null -ne $t.CurrentTemperature) {
                $zones += [PSCustomObject]@{ zone = $t.InstanceName; tempC = [math]::Round($t.CurrentTemperature / 10.0 - 273.15, 1) }
            }
        }
    } catch {
        [PSCustomObject]@{
            name = 'hw_thermal'; status = 'SKIP'
            evidence = "[root\wmi MSAcpi_ThermalZoneTemperature] 查询失败（无法判定）：$($_.Exception.Message)"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
}

$cmdTag = '[root\wmi MSAcpi_ThermalZoneTemperature]'
if ($zones.Count -eq 0) {
    [PSCustomObject]@{
        name = 'hw_thermal'; status = 'SKIP'
        evidence = "$cmdTag`n无热区暴露（台式机 ACPI 常不提供）——不是「不热」，是这台机器没告诉 Windows。温度请用 HWiNFO/HWiNFO64 侧读"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-thermal-zone' }
    } | ConvertTo-Json -Depth 5
    return
}

$invalid = @($zones | Where-Object { $_.tempC -le 0 -or $_.tempC -gt 120 })
if ($invalid.Count -ge 1) {
    $lines = ($zones | ForEach-Object { '{0} | {1}℃' -f $_.zone, $_.tempC }) -join "`n"
    [PSCustomObject]@{
        name = 'hw_thermal'; status = 'SKIP'
        evidence = "$cmdTag`n$lines`n存在 ACPI 假值（≤0℃ 或 >120℃）——热区读数不可信"
        suggestion = '本机 ACPI 热区读数不可信；真实温度请用 HWiNFO 侧读 CPU/主板传感器'; detail = [PSCustomObject]@{ reason = 'invalid-readings'; zones = $zones }
    } | ConvertTo-Json -Depth 5
    return
}

$lines = ($zones | ForEach-Object { '{0} | {1}℃' -f $_.zone, $_.tempC }) -join "`n"
$hot = @($zones | Where-Object { $_.tempC -gt 75 })
if ($hot.Count -ge 1) {
    $hotLines = ($hot | ForEach-Object { '{0}={1}℃' -f $_.zone, $_.tempC }) -join '、'
    $status = 'FAIL'
    $evidence = "$cmdTag`n$lines`n结论：热区过热（>75℃）：$hotLines"
    $suggestion = "热区过热：$hotLines（>75℃）。持续过热=降频、死机、加速老化。`n【修复命令，请自己执行】清灰（风扇/散热鳍片）；笔记本+2 年未清=优先做；CPU 换硅脂；装 HWiNFO 盯 CPU 温度曲线确认效果。`n【回滚】不适用（硬件保养动作）"
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n$lines"
    $suggestion = ''
}
[PSCustomObject]@{
    name = 'hw_thermal'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ zones = $zones; maxC = ($zones | Measure-Object tempC -Maximum).Maximum }
} | ConvertTo-Json -Depth 5

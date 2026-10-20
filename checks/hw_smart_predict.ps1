#Requires -Version 5.1
<#
检查项：hw_smart_predict —— SMART 预警与可靠性计数器（层：storage）
命令：Get-PhysicalDisk | Get-StorageReliabilityCounter（Wear/ReadErrorsUncorrected/Temperature，K→℃）＋ root\wmi MSStorageDriver_FailurePredictStatus（PredictFailure）；全只读
判定（design 第十节 2）：PredictFailure=true / ReadErrorsUncorrected>0 / Wear>10 / 盘温>60℃ 任一→FAIL；全部计数器 null→SKIP（家用盘常见，诚实缺口）；root\wmi 被拒（非管理员常 Access denied）→SKIP 附注「管理员身份可复核」；否则 PASS
mock 契约：逐行 `盘名 | wear | errUnc | tempC | predictFailure`（数值可为 null）；特殊行 `ACCESS-DENIED`；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$rows = @(); $denied = $false
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        if ($ln -match 'ACCESS-DENIED') { $denied = $true; continue }
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -ge 5) { $rows += [PSCustomObject]@{ name = $p[0]; wear = $p[1]; errUnc = $p[2]; tempC = $p[3]; predict = $p[4] } }
    }
} else {
    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $rc = $null
            try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $denied = $true }
            $wear = 'null'; $errU = 'null'; $tempC = 'null'
            if ($rc) {
                if ($null -ne $rc.Wear) { $wear = [string][int]$rc.Wear }
                if ($null -ne $rc.ReadErrorsUncorrected) { $errU = [string][long]$rc.ReadErrorsUncorrected }
                if ($null -ne $rc.Temperature) { $tempC = [string][math]::Round($rc.Temperature - 273.15, 1) }
            }
            $rows += [PSCustomObject]@{ name = [string]$d.FriendlyName; wear = $wear; errUnc = $errU; tempC = $tempC; predict = 'null' }
        }
    } catch {
        [PSCustomObject]@{
            name = 'hw_smart_predict'; status = 'SKIP'
            evidence = "[Get-StorageReliabilityCounter] 查询失败（无法判定）：$($_.Exception.Message)"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    try {
        foreach ($s in @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
            if ($s.PredictFailure) { $rows += [PSCustomObject]@{ name = ($s.InstanceName -split '\\')[-1]; wear = 'null'; errUnc = 'null'; tempC = 'null'; predict = 'true' } }
        }
    } catch { $denied = $true }
}

$cmdTag = '[Get-StorageReliabilityCounter + root\wmi FailurePredictStatus]'
$allNull = ($rows.Count -eq 0) -or (@($rows | Where-Object { $_.wear -ne 'null' -or $_.errUnc -ne 'null' -or $_.tempC -ne 'null' -or $_.predict -ne 'null' }).Count -eq 0)
if ($allNull -and -not $denied) {
    [PSCustomObject]@{
        name = 'hw_smart_predict'; status = 'SKIP'
        evidence = "$cmdTag`n全部计数器 null（家用盘不向 Windows 暴露 SMART 明细=常见）——不是「无预警」，是看不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'counters-null' }
    } | ConvertTo-Json -Depth 5
    return
}
if ($denied -and $allNull) {
    [PSCustomObject]@{
        name = 'hw_smart_predict'; status = 'SKIP'
        evidence = "$cmdTag`nSMART 探测被拒绝（非管理员账户常 Access denied）——不是「盘健康」，是权限不够"
        suggestion = '管理员身份可复核：右键开始菜单→终端(管理员)重跑本体检'; detail = [PSCustomObject]@{ reason = 'access-denied' }
    } | ConvertTo-Json -Depth 5
    return
}

$findings = @()
foreach ($r in $rows) {
    if ($r.predict -eq 'true') { $findings += '{0}：SMART PredictFailure=true（盘自报将要故障）' -f $r.name }
    elseif ($r.errUnc -ne 'null' -and [long]$r.errUnc -gt 0) { $findings += '{0}：不可纠正读错误 {1} 次' -f $r.name, $r.errUnc }
    elseif ($r.wear -ne 'null' -and [int]$r.wear -gt 10) { $findings += '{0}：SSD 磨损 {1}%（超 10% 警戒）' -f $r.name, $r.wear }
    elseif ($r.tempC -ne 'null' -and [double]$r.tempC -gt 60) { $findings += '{0}：盘温 {1}℃（超 60℃）' -f $r.name, $r.tempC }
}
$lines = ($rows | ForEach-Object { '{0} | wear={1} | errUnc={2} | {3}℃ | predict={4}' -f $_.name, $_.wear, $_.errUnc, $_.tempC, $_.predict }) -join "`n"
if ($denied) { $lines += "`n(部分探测被拒，非管理员；可用管理员身份复核)" }
if ($findings.Count -ge 1) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n$lines`n结论：`n" + ($findings -join "`n")
    $suggestion = "SMART 预警：`n" + ($findings -join "`n") + "`n【修复命令，请自己执行】立即备份重要数据；CrystalDiskInfo 看 SMART 明细复核；PredictFailure=true 或坏读持续增长=准备换盘。`n【回滚】不适用（只读检测）"
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n$lines"
    $suggestion = ''
}
[PSCustomObject]@{
    name = 'hw_smart_predict'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ rows = $rows; findings = $findings }
} | ConvertTo-Json -Depth 5

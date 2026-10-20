#Requires -Version 5.1
<#
检查项：hw_disk_health —— 物理磁盘健康（层：storage）
命令：Get-PhysicalDisk（FriendlyName/MediaType/HealthStatus/OperationalStatus，只读）
判定（design 第十节 1）：任一盘 HealthStatus≠Healthy→FAIL（Warning=坏块/磨损征兆备份数据；Unhealthy=濒死立即备份换盘）；全 Healthy→PASS 附盘清单；cmdlet 不可用或无盘→SKIP
mock 契约：逐行 `FriendlyName | MediaType | HealthStatus | OperationalStatus`；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$disks = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -ge 4) { $disks += [PSCustomObject]@{ name = $p[0]; media = $p[1]; health = $p[2]; oper = $p[3] } }
    }
} else {
    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $disks += [PSCustomObject]@{ name = [string]$d.FriendlyName; media = [string]$d.MediaType; health = [string]$d.HealthStatus; oper = [string]$d.OperationalStatus }
        }
    } catch {
        [PSCustomObject]@{
            name = 'hw_disk_health'; status = 'SKIP'
            evidence = "[Get-PhysicalDisk] 查询失败（无法判定）：$($_.Exception.Message)"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
}

$cmdTag = '[Get-PhysicalDisk]'
if ($disks.Count -eq 0) {
    [PSCustomObject]@{
        name = 'hw_disk_health'; status = 'SKIP'
        evidence = "$cmdTag`n无物理盘信息（存储模块不可用或无盘）——不是「盘健康」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data' }
    } | ConvertTo-Json -Depth 5
    return
}

$bad = @($disks | Where-Object { $_.health -ne 'Healthy' })
$lines = ($disks | ForEach-Object { '{0} | {1} | {2} | {3}' -f $_.name, $_.media, $_.health, $_.oper }) -join "`n"
if ($bad.Count -ge 1) {
    $badLines = ($bad | ForEach-Object { '{0}（{1}）' -f $_.name, $_.health }) -join '、'
    $status = 'FAIL'
    $evidence = "$cmdTag`n$lines"
    $suggestion = "有 $($bad.Count) 块盘健康状态异常：$badLines。Warning=坏块/磨损征兆，Unhealthy=濒死。`n【修复命令，请自己执行】第一步永远是备份重要数据到另一块盘/网盘；然后跑只读扫描 chkdsk <盘符>: /scan（在线只读，不改盘）；装 CrystalDiskInfo 看 SMART 明细（05/C5/C6 计数）。`n【回滚】不适用（以上全为只读动作）"
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n$lines"
    $suggestion = ''
}
[PSCustomObject]@{
    name = 'hw_disk_health'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ disks = $disks; badCount = $bad.Count }
} | ConvertTo-Json -Depth 5

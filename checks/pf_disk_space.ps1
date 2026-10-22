#Requires -Version 5.1
<#
检查项：pf_disk_space —— 磁盘水位（层：runtime）
命令：Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"（Size/FreeSpace，系统盘按 %SystemDrive% 匹配，只读）
判定（design 十一节 5）：系统盘剩余 <10% 或 <20GB 任一→FAIL（10%=SSD 高位掉速工程线、20GB=更新预留工程线，Win11 官方最低存储 64GB 无「保留多少」明文——工程线同 v0.3 先例）；系统盘 10-15%→PASS 附注「偏紧」；非系统盘 <10% 且 <20GB→PASS 附 WARN 备注；其余→PASS 附水位表；无本地盘→SKIP
mock 契约：逐行 `盘符 | 总GB | 剩GB | sys`（系统盘行第 4 列=sys，其余=-）；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$disks = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -ge 4) {
            $disks += [PSCustomObject]@{
                drive = $p[0].Trim(); sizeGB = [double]$p[1].Trim(); freeGB = [double]$p[2].Trim()
                isSys = ($p[3].Trim() -eq 'sys')
            }
        }
    }
} else {
    try {
        $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{
                drive = [string]$_.DeviceID
                sizeGB = [math]::Round($_.Size / 1GB, 1)
                freeGB = [math]::Round($_.FreeSpace / 1GB, 1)
                isSys = ([string]$_.DeviceID -eq $env:SystemDrive)
            }
        })
    } catch {
        [PSCustomObject]@{
            name = 'pf_disk_space'; status = 'SKIP'
            evidence = "[Win32_LogicalDisk DriveType=3] 查询失败（无法判定）：$($_.Exception.Message)"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
}

$cmdTag = '[Win32_LogicalDisk DriveType=3]'
if ($disks.Count -eq 0) {
    [PSCustomObject]@{
        name = 'pf_disk_space'; status = 'SKIP'
        evidence = "$cmdTag`n无本地磁盘记录——不是「水位健康」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data'; disks = @() }
    } | ConvertTo-Json -Depth 5
    return
}

foreach ($d in $disks) { $d | Add-Member -NotePropertyName pct -NotePropertyValue ([math]::Round($d.freeGB / $d.sizeGB * 100, 1)) -Force }

$sys = $disks | Where-Object { $_.isSys } | Select-Object -First 1
$table = ($disks | ForEach-Object {
    $line = '{0} 总 {1}GB 剩 {2}GB ({3}%)' -f $_.drive, $_.sizeGB, $_.freeGB, $_.pct
    if ($_.isSys) { $line += ' ← 系统盘' }
    $line
}) -join "`n"

$warnOthers = @($disks | Where-Object { -not $_.isSys -and $_.pct -lt 10 -and $_.freeGB -lt 20 })

if ($sys -and ($sys.pct -lt 10 -or $sys.freeGB -lt 20)) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n$table"
    $suggestion = "系统盘只剩 $($sys.freeGB)GB（$($sys.pct)%）——磁盘将满是固态掉速、系统更新失败的元凶（警戒线：剩余 10% 或 20GB 任一触线）。`n【修复命令，请自己执行】无（手动操作：设置→系统→存储→清理建议 清理；再打开「存储感知」自动清理临时文件；大文件自行搬到非系统盘）`n【回滚】不适用（清理动作均系统自带、可重复执行）"
} elseif ($sys -and $sys.pct -lt 15) {
    $status = 'PASS'
    $evidence = "$cmdTag`n$table`n系统盘偏紧（$($sys.pct)%，10-15% 区间），接近掉速警戒线"
    $suggestion = ''
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n$table"
    if ($warnOthers.Count -ge 1) {
        $wNames = ($warnOthers | ForEach-Object { '{0}（剩 {1}GB，{2}%）' -f $_.drive, $_.freeGB, $_.pct }) -join '、'
        $evidence = "$evidence`nWARN：非系统盘水位紧张 $wNames（不拖系统性能，存文件前留意）"
    }
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'pf_disk_space'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ disks = $disks }
} | ConvertTo-Json -Depth 5

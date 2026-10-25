#Requires -Version 5.1
<#
检查项：pf_disk_saturation —— 磁盘 IO 堵塞（「磁盘 100%」现场，层：runtime）
命令：Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk（排除 _Total，取 CurrentDiskQueueLength/AvgDiskSecPerTransfer）间隔 2 秒双采样（单次快照误报高——瞬时 IO 高峰人人有，只读）
判定：两次采样系统盘队列均 >2→FAIL（队列>2=性能监视经典工程线，微软无单一明文阈值页）；仅一次 >2→PASS 附注「瞬时高峰，未见持续」；均 ≤2→PASS 附队列值；查询失败/空→SKIP（精简系统常见=诚实缺口）
AvgDiskSecPerTransfer 官方 SQL I/O 排障文以 15ms 为延迟提示线→只附毫秒读数，不单独立 FAIL 判据
mock 契约：===SAMPLE=== 分隔两段（第1/2次采样），每段逐行 `盘实例 | 队列 | 平均响应秒`（系统盘行盘实例含 C:）；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Get-DiskSnapshot {
    # 返回逐行 `实例 | 队列 | 平均响应秒`（排除 _Total）
    try {
        $rows = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop |
            Where-Object { $_.Name -ne '_Total' } |
            ForEach-Object { '{0} | {1} | {2}' -f [string]$_.Name, [string]$_.CurrentDiskQueueLength, [string]$_.AvgDiskSecPerTransfer })
        return $rows
    } catch { return $null }
}

function Parse-Sample {
    param([string[]]$Lines)
    $r = @()
    foreach ($ln in $Lines) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -ge 3) {
            $r += [PSCustomObject]@{ inst = $p[0].Trim(); queue = [double]$p[1].Trim(); avgSec = [double]$p[2].Trim() }
        }
    }
    return $r
}

$samples = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    $parts = $MockRaw -split '===SAMPLE==='
    foreach ($part in $parts) {
        $lines = @($part -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -ge 1) { $samples += ,(Parse-Sample $lines) }
    }
} else {
    $s1 = Get-DiskSnapshot
    if ($null -eq $s1) {
        [PSCustomObject]@{
            name = 'pf_disk_saturation'; status = 'SKIP'
            evidence = "[Win32_PerfFormattedData_PerfDisk_PhysicalDisk] 计数器查询失败（精简系统常见）——不是「IO 健康」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    Start-Sleep -Seconds 2
    $s2 = Get-DiskSnapshot
    if ($null -eq $s2) { $s2 = $s1 }
    $samples = @((Parse-Sample $s1), (Parse-Sample $s2))
}

$cmdTag = '[Win32_PerfFormattedData_PerfDisk_PhysicalDisk 双采样(间隔2s)]'
$validSamples = @($samples | Where-Object { @($_).Count -ge 1 })
if ($validSamples.Count -lt 2) {
    [PSCustomObject]@{
        name = 'pf_disk_saturation'; status = 'SKIP'
        evidence = "$cmdTag`n采样数据不足（$($validSamples.Count)/2 次有效）——不是「IO 健康」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data' }
    } | ConvertTo-Json -Depth 5
    return
}

# 系统盘实例：实例名以 %SystemDrive% 结尾（形如 "0 C:"）；无匹配→取两次队列最大实例并如实标注
$sysDrive = $env:SystemDrive
$targetInst = ''
foreach ($row in $validSamples[0]) {
    if ($row.inst.Trim().EndsWith($sysDrive)) { $targetInst = $row.inst.Trim(); break }
}
$howTag = ''
if (-not $targetInst) {
    $targetInst = ($validSamples[0] | Sort-Object -Property queue -Descending | Select-Object -First 1).inst
    $howTag = '（未见系统盘独立实例，按全盘最大值判）'
}

$q = @(); $ms = @()
for ($i = 0; $i -lt 2; $i++) {
    $row = $validSamples[$i] | Where-Object { $_.inst.Trim() -eq $targetInst } | Select-Object -First 1
    if ($row) { $q += [double]$row.queue; $ms += [math]::Round($row.avgSec * 1000) }
}
if ($q.Count -lt 2) {
    [PSCustomObject]@{
        name = 'pf_disk_saturation'; status = 'SKIP'
        evidence = "$cmdTag`n目标实例「$targetInst」采样不完整——不是「IO 健康」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'partial-data' }
    } | ConvertTo-Json -Depth 5
    return
}

$evidence = "$cmdTag$howTag`n第1次 $targetInst 队列=$($q[0]) 平均响应=$($ms[0])ms`n第2次 $targetInst 队列=$($q[1]) 平均响应=$($ms[1])ms"

if ($q[0] -gt 2 -and $q[1] -gt 2) {
    $status = 'FAIL'
    $suggestion = "系统盘 IO 持续堵塞（队列 $($q[0])/$($q[1])，两次采样均>2）——这就是任务管理器「磁盘 100%」的卡顿现场（平均响应 $($ms[0])/$($ms[1])ms，15ms 以上=明显延迟提示线）。常见元凶=磁盘将满/杀毒全盘扫描/机械盘老化/Windows 更新后台下载。配合磁盘水位与启动负担层证据定位。`n【修复命令，请自己执行】无（先看任务管理器→性能→磁盘 哪个进程在占）`n【回滚】不适用"
} elseif ($q[0] -gt 2 -or $q[1] -gt 2) {
    $status = 'PASS'
    $evidence = "$evidence`n瞬时高峰（仅 1 次>2），未见持续"
    $suggestion = ''
} else {
    $status = 'PASS'
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'pf_disk_saturation'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ instance = $targetInst; queue = $q; avgMs = $ms }
} | ConvertTo-Json -Depth 5

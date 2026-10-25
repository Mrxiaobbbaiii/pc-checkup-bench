#Requires -Version 5.1
<#
检查项：pf_memory_pressure —— 内存压力（层：runtime）
命令：Get-CimInstance Win32_OperatingSystem（TotalVirtualMemorySize/FreeVirtualMemory，KB）+ Win32_ComputerSystem（TotalPhysicalMemory，字节）（只读）
判定：物理 <4GB→FAIL（Win11 官方最低内存线）；commit 率>90%→FAIL（内存+页面文件双吃紧=卡顿进行时）；物理 4-8GB 且 commit≤90%→PASS 附注「规格贴最低线」；≥8GB→PASS 附容量+commit 率；查询失败→SKIP
设计要点：不用「空闲物理内存低」判 FAIL（Windows 拿空闲内存做缓存=正常设计，空闲低≠故障）——FreePhysicalMemory 只取证不判定
mock 契约：单行 `物理GB | commit总量GB | commit空闲GB`；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$physGB = 0; $commitTotalGB = 0; $commitFreeGB = 0
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -ge 3) {
            $physGB = [double]$p[0].Trim(); $commitTotalGB = [double]$p[1].Trim(); $commitFreeGB = [double]$p[2].Trim()
        }
    }
    if ($physGB -le 0) {
        [PSCustomObject]@{
            name = 'pf_memory_pressure'; status = 'SKIP'
            evidence = "[Win32_ComputerSystem/Win32_OperatingSystem] mock 无有效数据——不是「内存健康」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data' }
        } | ConvertTo-Json -Depth 5
        return
    }
} else {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $physGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $commitTotalGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
        $commitFreeGB = [math]::Round($os.FreeVirtualMemory / 1MB, 1)
    } catch {
        [PSCustomObject]@{
            name = 'pf_memory_pressure'; status = 'SKIP'
            evidence = "[Win32_ComputerSystem/Win32_OperatingSystem] 查询失败（无法判定）：$($_.Exception.Message)"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
}

$commitUsedGB = [math]::Round($commitTotalGB - $commitFreeGB, 1)
$commitPct = if ($commitTotalGB -gt 0) { [math]::Round(($commitTotalGB - $commitFreeGB) / $commitTotalGB * 100) } else { 0 }
$cmdTag = '[Win32_ComputerSystem/Win32_OperatingSystem]'

if ($physGB -lt 4) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n物理内存 ${physGB}GB（Win11 官方最低线 4GB）`ncommit ${commitUsedGB}/${commitTotalGB}GB (${commitPct}%)"
    $suggestion = "物理内存 ${physGB}GB 低于 Windows 11 官方最低要求（4GB）——日常使用必卡：浏览器多开、微信+网页同开就顶满。根治=加内存条（老笔记本一般可加到 8/16GB）；过渡=同时少开程序、浏览器标签页控制在 10 个以内。`n【修复命令，请自己执行】无（硬件升级）`n【回滚】不适用"
} elseif ($commitPct -gt 90) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n物理内存 ${physGB}GB`ncommit ${commitUsedGB}/${commitTotalGB}GB (${commitPct}%) ← 内存+页面文件双吃紧"
    $suggestion = "commit 已用 ${commitPct}%（内存+页面文件合计水位，>90%=卡顿进行时：切窗口卡顿、输入延迟都是它）。先关占内存大户（浏览器标签/虚拟机/大软件）；若物理内存本身 <8GB，加内存条是根治方向。`n【修复命令，请自己执行】无（先关程序观察；任务管理器→性能→内存 看「已提交」曲线）`n【回滚】不适用"
} elseif ($physGB -lt 8) {
    $status = 'PASS'
    $evidence = "$cmdTag`n物理内存 ${physGB}GB`ncommit ${commitUsedGB}/${commitTotalGB}GB (${commitPct}%)`n规格贴最低线（4-8GB 区间），多开必卡，加内存条是根治方向"
    $suggestion = ''
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n物理内存 ${physGB}GB`ncommit ${commitUsedGB}/${commitTotalGB}GB (${commitPct}%)"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'pf_memory_pressure'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ physicalGB = $physGB; commitTotalGB = $commitTotalGB; commitFreeGB = $commitFreeGB; commitPct = $commitPct }
} | ConvertTo-Json -Depth 5

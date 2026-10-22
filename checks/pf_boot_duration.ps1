#Requires -Version 5.1
<#
检查项：pf_boot_duration —— 开机时长（层：boot）
命令：Get-WinEvent 'Microsoft-Windows-Diagnostics-Performance/Operational' id=100 近 5 次（Windows 每次开机自动记一条，EventData 含 BootTime 毫秒；慢启动时 Level 由 Windows 按官方阈值自动升 Warning/Critical——只读）
判定（design 十一节 1）：近 5 次 Warning/Critical ≥2→FAIL；均值>60000ms→FAIL（60s=工程线）；均值 30000-60000→PASS 附注「偏慢」；<30000→PASS；日志不存在/无 100 事件/查询失败→SKIP
mock 契约：逐行 `MM-dd | Level | BootMs`（Level=Warning/Critical/Error/Information）；空=SKIP
语言无关：BootTime 从 ToXml() 的 EventData 抓（不靠消息文案）；Level 用数值 1/2/3=Critical/Error/Warning（标记级）、4=Information。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$boots = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -ge 3) { $boots += [PSCustomObject]@{ day = $p[0].Trim(); level = $p[1].Trim(); ms = [long]($p[2].Trim() -replace '[^\d]', '') } }
    }
} else {
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 5 -ErrorAction Stop)
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'No events|找不到') { $evts = @() }
        else {
            $extra = ''
            if ($m -match '权限|提升|unauthorized|not authorized') { $extra = '（该日志需管理员权限读取——管理员身份运行可复核）' }
            [PSCustomObject]@{
                name = 'pf_boot_duration'; status = 'SKIP'
                evidence = "[Diagnostics-Performance id=100] 查询失败（无法判定）：$m$extra"
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
            } | ConvertTo-Json -Depth 5
            return
        }
    }
    foreach ($e in $evts) {
        $xml = $e.ToXml()
        $ms = 0
        if ($xml -match '<Data\s+Name=["'']BootTime["'']\s*>\s*(\d+)\s*<') { $ms = [long]$Matches[1] }
        $lvlName = switch ([int]$e.Level) { 1 { 'Critical' } 2 { 'Error' } 3 { 'Warning' } default { 'Information' } }
        $boots += [PSCustomObject]@{ day = $e.TimeCreated.ToString('MM-dd'); level = $lvlName; ms = $ms }
    }
}

$cmdTag = '[Diagnostics-Performance id=100 近5次]'
if ($boots.Count -eq 0) {
    [PSCustomObject]@{
        name = 'pf_boot_duration'; status = 'SKIP'
        evidence = "$cmdTag`n无 100 开机记录（日志不存在或被清理）——不是「开机快」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data'; samples = 0 }
    } | ConvertTo-Json -Depth 5
    return
}

$markCount = @($boots | Where-Object { $_.level -in @('Warning', 'Critical', 'Error') }).Count
$avgMs = [math]::Round(($boots | Measure-Object -Property ms -Average).Average)
$list = ($boots | ForEach-Object { '{0} {1} {2}ms({3}秒)' -f $_.day, $_.level, $_.ms, [math]::Round($_.ms / 1000) }) -join "`n"
$evidence = "$cmdTag`n$list`n均值 ${avgMs}ms"
$disablePath = '【修复命令，请自己执行】无（手动操作：按 Ctrl+Shift+Esc 打开任务管理器→「启动应用」页，把不认识/不用的高影响自启右键禁用）`n【回滚】任务管理器→「启动应用」同一位置右键重新启用即可'

if ($markCount -ge 2) {
    $status = 'FAIL'
    $suggestion = "近 5 次开机有 $markCount 次被 Windows 自动标记为慢启动（Warning/Critical=微软官方慢启动判定，不是本工具自定标准）。配合「启动负担层」的自启清单与服务超时证据定位元凶。`n$disablePath"
} elseif ($avgMs -gt 60000) {
    $status = 'FAIL'
    $suggestion = "近 5 次开机均值 $([math]::Round($avgMs / 1000)) 秒，超过 60 秒警戒线。配合「启动负担层」证据定位：自启过多/服务超时/磁盘 IO 是三大常客。`n$disablePath"
} elseif ($avgMs -ge 30000) {
    $status = 'PASS'
    $evidence = "$evidence`n偏慢（均值 $([math]::Round($avgMs / 1000)) 秒，30-60 秒区间），配合启动负担层看"
    $suggestion = ''
} else {
    $status = 'PASS'
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'pf_boot_duration'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ samples = $boots.Count; warnCount = $markCount; avgMs = $avgMs }
} | ConvertTo-Json -Depth 5

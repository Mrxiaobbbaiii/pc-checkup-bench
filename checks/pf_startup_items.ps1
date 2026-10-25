#Requires -Version 5.1
<#
检查项：pf_startup_items —— 自启清单负担（层：startup）
命令：Get-CimInstance Win32_StartupCommand（Name/Command/Location/User，官方 WMI 类一次拉全注册表 Run 键+启动文件夹，只读），对照 checks/pf_suspects.json 嫌疑名单（实证收录制，v0.4 空名单起步）
判定：命中名单→FAIL（附 label+advice）；总数>20→FAIL（附全清单+识别指引）；≤20→PASS 附清单+人话；查询失败→SKIP
注：该类不反映任务管理器「已禁用」状态（StartupApproved 二进制无官方文档口径，不解读）——evidence 注明以任务管理器→启动应用页实际状态为准
mock 契约：逐行 `Name | Location | Command`；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '', [string]$SuspectsFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# 名单加载（缺失/损坏→SKIP 不得崩，同 bs_suspects 先例；注意 v0.4 空名单 [] 是合法态，不得当损坏）
$listPath = if ($SuspectsFile -ne '') { $SuspectsFile } else { Join-Path $PSScriptRoot 'pf_suspects.json' }
$parsed = $null
try { $parsed = Get-Content -LiteralPath $listPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $parsed = $null }
if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['suspects']) {
    $suspects = @()
    $listWhy = if (-not (Test-Path -LiteralPath $listPath)) { 'file not found' } else { 'JSON parse failed' }
    [PSCustomObject]@{
        name = 'pf_startup_items'; status = 'SKIP'
        evidence = "[嫌疑名单加载] $listPath 不可用（$listWhy），无法比对"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'suspects-unreadable'; path = $listPath }
    } | ConvertTo-Json -Depth 5
    return
}
$suspects = @($parsed.suspects)

$cmds = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $f = $ln -split '\s*\|\s*', 3
        if ($f.Count -ge 2) {
            $cmds += [PSCustomObject]@{ name = $f[0].Trim(); location = $f[1].Trim(); command = $(if ($f.Count -gt 2) { $f[2].Trim() } else { '' }) }
        }
    }
} else {
    try {
        $cmds = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{ name = [string]$_.Name; location = [string]$_.Location; command = [string]$_.Command }
        })
    } catch {
        [PSCustomObject]@{
            name = 'pf_startup_items'; status = 'SKIP'
            evidence = "[Win32_StartupCommand] 查询失败（无法判定）：$($_.Exception.Message)"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
}

$cmdTag = "[Win32_StartupCommand × pf_suspects.json 名单 $($suspects.Count) 条]"
if ($cmds.Count -eq 0) {
    [PSCustomObject]@{
        name = 'pf_startup_items'; status = 'SKIP'
        evidence = "$cmdTag`n无自启记录（查询无数据）——不是「零负担」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data'; total = 0 }
    } | ConvertTo-Json -Depth 5
    return
}

# 名单命中（Name/Command 包含 pattern）
$hits = @()
foreach ($s in $suspects) {
    foreach ($c in $cmds) {
        if (($c.name -like "*$($s.pattern)*") -or ($c.command -like "*$($s.pattern)*")) {
            $hits += [PSCustomObject]@{ name = $c.name; location = $c.location; pattern = $s.pattern; label = $s.label; advice = $s.advice }
        }
    }
}

$locGroups = @{}
foreach ($c in $cmds) {
    $g = if ($c.location -match 'HKCU') { 'HKCU Run' } elseif ($c.location -match 'HKLM|Registry') { 'HKLM Run' } elseif ($c.location -match 'Startup|启动') { 'Startup' } else { $c.location }
    if (-not $locGroups.ContainsKey($g)) { $locGroups[$g] = 0 }
    $locGroups[$g]++
}
$locSummary = ($locGroups.GetEnumerator() | ForEach-Object { '{0} {1} 项' -f $_.Key, $_.Value }) -join '，'
$listAll = ($cmds | ForEach-Object { '[{0}] {1}' -f $_.location, $_.name }) -join "`n"
$noteDisabled = '注：本清单不反映任务管理器「已禁用」状态，以 任务管理器→启动应用 页实际状态为准'

$overload = $cmds.Count -gt 20
if ($hits.Count -ge 1) {
    $status = 'FAIL'
    $hitLines = ($hits | ForEach-Object { '{0}（{1}）← 命中名单: {2}' -f $_.name, $_.location, $_.label }) -join "`n"
    $evidence = "$cmdTag`n共 $($cmds.Count) 项（$locSummary）`n$hitLines"
    $parts = @()
    foreach ($h in $hits) {
        $fixPart = $h.advice; $rbPart = '不适用（见名单 advice）'
        $idx = $h.advice.IndexOf('回滚：')
        if ($idx -ge 0) {
            $fixPart = $h.advice.Substring(0, $idx).TrimEnd('。，； ')
            $rbPart = $h.advice.Substring($idx + 3).Trim()
        }
        $parts += "自启项命中嫌疑名单：$($h.label)。`n【修复命令，请自己执行】$fixPart`n【回滚】$rbPart"
    }
    if ($overload) { $parts += "另：自启总数 $($cmds.Count) 项超过 20 项负担线，全清单见证据。逐个识别，不认识的不急着自己动，对照任务管理器→启动应用页。" }
    $suggestion = $parts -join "`n"
} elseif ($overload) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n共 $($cmds.Count) 项（$locSummary），超过 20 项负担线`n$listAll`n$noteDisabled"
    $suggestion = "自启项共 $($cmds.Count) 个，超过 20 项工程负担线——开机要挨个拉起它们，开机慢的常驻侧元凶。逐个识别：认识的、不必要的在任务管理器→「启动应用」右键禁用；不认识的不急着自己动，先对照任务管理器启动页影响评级再定。`n【修复命令，请自己执行】无（手动操作：按 Ctrl+Shift+Esc 打开任务管理器 → 左侧「启动应用」→ 右键不要的项 → 点「禁用」）。`n【看到什么算成功】该行右侧显示「已禁用」、字变灰；重启后开机明显变快、本项计数下降。`n【这步失败了先】右键里没有「禁用」= 该项来自系统或策略，跳过别硬动；拿不准的项一律先不动。`n【回滚】同一位置右键重新启用`n$noteDisabled"
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n共 $($cmds.Count) 项（$locSummary）`n$($cmds | Select-Object -First 8 | ForEach-Object { '[{0}] {1}' -f $_.location, $_.name })`n$noteDisabled"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'pf_startup_items'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ total = $cmds.Count; hits = $hits; locations = $locGroups }
} | ConvertTo-Json -Depth 6

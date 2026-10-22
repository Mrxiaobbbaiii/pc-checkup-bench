#Requires -Version 5.1
<#
检查项：bs_suspect_drivers —— 已知嫌疑驱动在跑（层：evidence）
命令：Get-CimInstance Win32_SystemDriver（只读），对照 checks/bs_suspects.json 嫌疑名单（数据与代码分离，可增长）
判定：任一驱动 Name/PathName 包含名单 pattern 且 State=Running→FAIL（附名单 label+advice）；无命中→PASS；名单文件缺失或 JSON 损坏→SKIP 带证据（施工单完工问 1）
mock 契约：逐行 `name | state | path`（如 `nnndisfilter | Running | C:\Windows\system32\drivers\nnndisfilter.sys`）
注：Win32_SystemDriver 的 State 值恒为英文（Running/Stopped），不随系统语言变。
#>
param([string]$MockRaw = '', [string]$MockFile = '', [string]$SuspectsFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# 名单加载（缺失/损坏→SKIP 不得崩，施工单完工问 1 的既定行为）
$listPath = if ($SuspectsFile -ne '') { $SuspectsFile } else { Join-Path $PSScriptRoot 'bs_suspects.json' }
$suspects = $null
try { $suspects = (Get-Content -LiteralPath $listPath -Raw -Encoding UTF8 | ConvertFrom-Json).suspects } catch { $suspects = $null }
if (-not $suspects) {
    $listWhy = if (-not (Test-Path -LiteralPath $listPath)) { 'file not found' } else { 'JSON parse failed' }
    [PSCustomObject]@{
        name = 'bs_suspect_drivers'; status = 'SKIP'
        evidence = "[嫌疑名单加载] $listPath 不可用（$listWhy），无法比对"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'suspects-unreadable'; path = $listPath }
    } | ConvertTo-Json -Depth 5
    return
}
$suspects = @($suspects)

$drivers = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $f = $ln -split '\s*\|\s*', 3
        if ($f.Count -ge 2) {
            $drivers += [PSCustomObject]@{ name = $f[0].Trim(); state = $f[1].Trim(); path = $(if ($f.Count -gt 2) { $f[2].Trim() } else { '' }) }
        }
    }
} else {
    $drivers = @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop | ForEach-Object {
        [PSCustomObject]@{ name = [string]$_.Name; state = [string]$_.State; path = [string]$_.PathName }
    })
}

$hits = @()
foreach ($s in $suspects) {
    foreach ($d in $drivers) {
        if ($d.state -ieq 'Running' -and (($d.name -like "*$($s.pattern)*") -or ($d.path -like "*$($s.pattern)*"))) {
            $hits += [PSCustomObject]@{ driver = $d.name; state = $d.state; path = $d.path; pattern = $s.pattern; label = $s.label; advice = $s.advice }
        }
    }
}

$cmdTag = "[Get-CimInstance Win32_SystemDriver × bs_suspects.json 名单 $($suspects.Count) 条]"
if ($hits.Count -ge 1) {
    $status = 'FAIL'
    $hitLines = ($hits | ForEach-Object { '{0} | {1} | {2} ← 命中名单: {3}' -f $_.driver, $_.state, $_.path, $_.label }) -join "`n"
    $evidence = "$cmdTag`n$hitLines"
    $parts = @()
    foreach ($h in $hits) {
        $fixPart = $h.advice; $rbPart = '不适用（见名单 advice）'
        $idx = $h.advice.IndexOf('回滚：')
        if ($idx -ge 0) {
            $fixPart = $h.advice.Substring(0, $idx).TrimEnd('。，； ')
            $rbPart = $h.advice.Substring($idx + 3).Trim()
        }
        $parts += "命中嫌疑名单：$($h.label)，正在这台电脑上运行。`n【修复命令，请自己执行】$fixPart`n【回滚】$rbPart"
    }
    $suggestion = $parts -join "`n"
} else {
    $status = 'PASS'
    $sample = ($drivers | Select-Object -First 5 | ForEach-Object { '{0} | {1}' -f $_.name, $_.state }) -join '；'
    $evidence = "$cmdTag`n扫描 $($drivers.Count) 个驱动无 Running 命中（摘录前 5）：$sample"
    $suggestion = ''
}

[PSCustomObject]@{
    name       = 'bs_suspect_drivers'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ hits = $hits; scanned = $drivers.Count; suspects = $suspects.Count }
} | ConvertTo-Json -Depth 5

#Requires -Version 5.1
<#
检查项：bs_code_frequency —— 同码复发判定（慢性病识别，层：attribution）
命令：与 bs_event_history 同源（Get-WinEvent System Id=1001 近 90 天，只读），对码聚合计数
判定：任一码 ≥2 次→FAIL（慢性病）；全部单次→PASS 附注；0 条→PASS；码书 JSON 损坏/缺失→SKIP 带证据
码书联动：checks/bugcheck_codes.json 查到→suggestion 用其 name+cause+ref；查不到→如实写"未收录+官方查询法"（零瞎编）
mock 契约：同 bs_event_history（逐行 `yyyy-MM-dd HH:mm | 0x00000139 | dump路径`）
#>
param([string]$MockRaw = '', [string]$MockFile = '', [string]$CodesFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# 码书加载（数据文件损坏→SKIP 不得崩的既定行为）
$bookPath = if ($CodesFile -ne '') { $CodesFile } else { Join-Path $PSScriptRoot 'bugcheck_codes.json' }
$book = $null
try { $book = Get-Content -LiteralPath $bookPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $book = $null }
if (-not $book -or -not $book.codes) {
    $bookWhy = if (-not (Test-Path -LiteralPath $bookPath)) { 'file not found' } else { 'JSON parse failed' }
    [PSCustomObject]@{
        name = 'bs_code_frequency'; status = 'SKIP'
        evidence = "[码书加载] $bookPath 不可用（$bookWhy），无法翻译蓝屏码语义"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'codebook-unreadable'; path = $bookPath }
    } | ConvertTo-Json -Depth 5
    return
}

# 取证（与 bs_event_history 同源同格式；mock 走同一解析路径）
$records = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        if ($ln -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*\|\s*(0x[0-9A-Fa-f]{1,8})\s*\|\s*(.*)$') {
            $records += [PSCustomObject]@{ time = $Matches[1]; code = $Matches[2] }
        }
    }
} else {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-90) } -ErrorAction Stop)
        foreach ($e in $events) {
            $code = if ($e.Message -match '0x[0-9A-Fa-f]{8}') { $Matches[0] } else { '-' }
            $records += [PSCustomObject]@{ time = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'); code = $code }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEvents') { $records = @() } else {
            [PSCustomObject]@{
                name = 'bs_code_frequency'; status = 'SKIP'
                evidence = "[Get-WinEvent System Id=1001 近90天] 查询失败（无法判定）：$($_.Exception.Message)"
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
            } | ConvertTo-Json -Depth 5
            return
        }
    }
}

# 码归一化（消息里 0x00000139 → 码书键 0x139）
function ConvertTo-BsCode { param([string]$Raw)
    try { return '0x{0:X}' -f [Convert]::ToInt64($Raw, 16) } catch { return $Raw }
}

$cmdTag = '[1001 蓝屏码聚合·近90天·码书=' + (Split-Path $bookPath -Leaf) + ']'
$detailNote = 'no-records'
if ($records.Count -eq 0) {
    $status = 'PASS'
    $evidence = "$cmdTag`n无蓝屏记录（0 条），无慢性病判断对象"
    $suggestion = ''
} else {
    $groups = @($records | ForEach-Object { [PSCustomObject]@{ code = (ConvertTo-BsCode $_.code) } } | Group-Object -Property code | Sort-Object Count -Descending)
    $repeat = @($groups | Where-Object { $_.Count -ge 2 })
    $distLine = ($groups | ForEach-Object { "$($_.Name) × $($_.Count)" }) -join '，'
    if ($repeat.Count -ge 1) {
        $status = 'FAIL'
        $evidence = "$cmdTag`n$distLine"
        $parts = @()
        foreach ($r in $repeat) {
            $entry = @($book.codes | Where-Object { $_.code -ieq $r.Name })[0]
            if ($entry) {
                $parts += "蓝屏码 $($r.Name)（$($entry.name)）反复出现 $($r.Count) 次=慢性病（驱动/硬件方向），非偶发。$($entry.cause)`n官方参考：$($entry.ref)"
            } else {
                $parts += "蓝屏码 $($r.Name) 反复出现 $($r.Count) 次=慢性病。该码未收录码书，查官方：learn.microsoft.com 搜 'Bug Check $($r.Name)'（零瞎编原则，不编造语义）"
            }
        }
        $suggestion = ($parts -join "`n") + "`n【修复命令，请自己执行】对照 evidence 层 bs_suspect_drivers 的嫌疑驱动结论处理（卸载捆绑软件/更新或回滚驱动）；无驱动命中时优先内存检测（mdsched.exe 或 memtest86+）。`n【回滚】驱动可经设备管理器回滚；卸载的软件可重装恢复"
    } else {
        $status = 'PASS'
        $evidence = "$cmdTag`n$distLine（全部单次）"
        $suggestion = ''
    }
    $detailNote = $(if ($repeat.Count -ge 1) { 'repeat-found' } else { 'all-single' })
}

[PSCustomObject]@{
    name       = 'bs_code_frequency'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ distribution = $distLine; note = $detailNote }
} | ConvertTo-Json -Depth 5

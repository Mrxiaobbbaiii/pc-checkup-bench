#Requires -Version 5.1
<#
检查项：hw_disk_errors —— 磁盘/文件系统错误史（层：storage）
命令：Get-WinEvent System 日志 Provider=Ntfs 近 30 天 id=55（目录损坏）/98（卷损坏）/153（延迟写入失败），只读
判定：55/98 任意一条 → FAIL（结构损坏信号，先备份再修）；仅 153 ≥3 条 → FAIL（磁盘写入长期跟不上）；153 1-2 条 → PASS 附注；0 条 → PASS；System 日志不可读 → SKIP
mock 契约：逐行 `EventID | 卷/说明 | 时间`；空=PASS（0 条）；首行 QUERY-ERROR=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$events = @()
$queryError = $false
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：System 日志不可读'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            if ($p.Count -ge 1) {
                $eid = 0
                if (-not [int]::TryParse($p[0].Trim(), [ref]$eid)) { continue }
                $vol = if ($p.Count -ge 2 -and $p[1].Trim() -ne '') { $p[1].Trim() } else { '未知卷' }
                $when = if ($p.Count -ge 3 -and $p[2].Trim() -ne '') { $p[2].Trim() } else { '时间未知' }
                $events += [PSCustomObject]@{ id = $eid; vol = $vol; when = $when }
            }
        }
    }
} else {
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Ntfs'; Id = @(55, 98, 153); StartTime = (Get-Date).AddDays(-30) } -MaxEvents 300 -ErrorAction Stop)
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'No events|找不到') { $evts = @() } else { $queryError = $true; $errText = $m }
    }
    if (-not $queryError) {
        foreach ($e in $evts) {
            $vol = ''
            foreach ($prop in @($e.Properties)) {
                $v = [string]$prop.Value
                if ($v -match '^[A-Za-z]:\\?$' -or $v -match '(?i)^\\\\Device\\\\HarddiskVolume') { $vol = $v; break }
            }
            if (-not $vol) {
                foreach ($prop in @($e.Properties)) {
                    $v = [string]$prop.Value
                    if ($v -and $v -notmatch '^[\d\s]*$' -and $v.Length -le 60) { $vol = $v; break }
                }
            }
            if (-not $vol) { $vol = '系统卷' }
            $events += [PSCustomObject]@{ id = $e.Id; vol = $vol; when = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm') }
        }
    }
}

$cmdTag = '[System Ntfs 55/98/153 近30天]'
if ($queryError) {
    [PSCustomObject]@{
        name = 'hw_disk_errors'; status = 'SKIP'
        evidence = "$cmdTag`nSystem 日志不可读（无法判定）：$errText——不是「磁盘没问题」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}

$cnt55 = @($events | Where-Object { $_.id -eq 55 }).Count
$cnt98 = @($events | Where-Object { $_.id -eq 98 }).Count
$cnt153 = @($events | Where-Object { $_.id -eq 153 }).Count
$recent = ($events | Select-Object -First 4 | ForEach-Object { '{0} | {1} | {2}' -f $_.id, $_.vol, $_.when }) -join "`n"
$breakdown = "55 目录损坏 $cnt55 条；98 卷损坏 $cnt98 条；153 延迟写入失败 $cnt153 条"

if ($events.Count -eq 0) {
    $status = 'PASS'
    $evidence = "$cmdTag`n0 条（近 30 天没有 NTFS 文件系统错误）"
    $suggestion = ''
} elseif ($cnt55 -ge 1 -or $cnt98 -ge 1 -or $cnt153 -ge 3) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n$breakdown`n$recent"
    $suggestion = "近 30 天发现文件系统错误：$breakdown。55/98 多为目录/卷结构损坏（突然断电、坏道、线材松动都可能导致），先备份重要数据再修。`n【修复命令，请自己执行】先在线只读扫描：chkdsk C: /scan（按实际盘符替换，不改盘）；确认后再修复：chkdsk C: /f（会要求重启并锁盘，别断电）；SMART 同时异常的盘尽快换盘。`n【回滚】chkdsk /f 是修复动作，无自动回滚；动手前先备份数据。"
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n$breakdown（153 少量=偶发写入延迟，暂未见结构损坏）`n$recent"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'hw_disk_errors'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ total = $events.Count; id55 = $cnt55; id98 = $cnt98; id153 = $cnt153; recent = @($events | Select-Object -First 10 | ForEach-Object { @{ id = $_.id; volume = $_.vol; when = $_.when } }) }
} | ConvertTo-Json -Depth 6

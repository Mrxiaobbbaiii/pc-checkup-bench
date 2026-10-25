#Requires -Version 5.1
<#
检查项：sec_suspicious_tasks —— 可疑计划任务清单（非微软路径）（层：system_hardening）
命令：schtasks /query /fo csv /v（只读；叶子内经 System.Diagnostics.Process 调用，OEM 代码页解码）
判定（安全树规格 v1.6 第一节 8）：查询异常/表头定位失败→SKIP(query-error/unknown-locale)；
  第三方（任务名不以 \Microsoft\ 开头）任务执行路径命中可疑位置（\Users\ \AppData\ \Temp\ \ProgramData\ \Public\、UNC、无盘符裸命令、
  非系统只读目录）→FAIL；可疑为空且有第三方任务→PASS 附注；无第三方任务→PASS
佐证：计划任务=持久化高发位置（MITRE ATT&CK T1053.005：https://attack.mitre.org/techniques/T1053/005/ ，业界权威非微软官方）
出处：https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks
mock 契约：MockRaw=CSV 原文含表头行（表头按列名动态定位：任务名/TaskName、要运行的任务/Task To Run）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result { param($Status, $Evidence, $Suggestion, $Detail)
    [PSCustomObject]@{
        name = 'sec_suspicious_tasks'; status = $Status; evidence = $Evidence; suggestion = $Suggestion; detail = $Detail
    } | ConvertTo-Json -Depth 6
}

function Classify-Exec { param([string]$Exec)
    $r = @{ susp = $false; reason = '' }
    if ($Exec -eq '') { return $r }
    if ($Exec.StartsWith('\\')) { $r.susp = $true; $r.reason = 'UNC 路径（\\ 开头）'; return $r }
    foreach ($m in @('\Users\', '\AppData\', '\Temp\', '\ProgramData\', '\Public\')) {
        if ($Exec -like ('*' + $m + '*')) { $r.susp = $true; $r.reason = "路径含 $m（用户可写目录）"; return $r }
    }
    $probe = $Exec.Trim('"')
    if ($probe -match '^(?:[a-zA-Z]:)?\\(?:Windows|Program Files|Program Files \(x86\))\\') { return $r }
    if ($Exec -match '[a-zA-Z]:\\') {
        $p = ([regex]::Match($Exec, '"([^"]+)"')).Groups[1].Value
        if ($p -eq '') { $p = ([regex]::Match($Exec, '[a-zA-Z]:\\[^\s]+')).Value }
        $dirFrag = ''
        if ($p -ne '') {
            try { $dir = Split-Path -Parent $p } catch { $dir = '' }
            if ($dir) { $dirFrag = ($dir -replace '^[a-zA-Z]:', '') }
        }
        if ($dirFrag -ne '' -and $dirFrag -ne '\') { $r.reason = "路径含 $dirFrag，非系统只读目录" }
        else { $r.reason = '非系统只读目录（不在 \Windows\ 或 \Program Files 下）' }
        $r.susp = $true
        return $r
    }
    $r.susp = $true
    $r.reason = '无盘符的相对/裸命令'
    return $r
}

$cmdTagBase = '[schtasks /query /fo csv /v]'
$raw = ''

if ($MockRaw -ne '' -or $MockFile -ne '') {
    $raw = $MockRaw
} else {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\schtasks.exe'
        $psi.Arguments = '/query /fo csv /v'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $ms = New-Object System.IO.MemoryStream
        $proc.StandardOutput.BaseStream.CopyTo($ms)
        $errTxt = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $bytes = $ms.ToArray()
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $raw = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        } else {
            $oemcp = (Get-Culture).TextInfo.OEMCodePage
            if ($oemcp -le 0) { $oemcp = 936 }
            $raw = [System.Text.Encoding]::GetEncoding($oemcp).GetString($bytes)
        }
        if ($proc.ExitCode -ne 0) { throw "schtasks 退出码 $($proc.ExitCode)：$errTxt" }
    } catch {
        Out-Result 'SKIP' "$cmdTagBase`n查询失败（无法判定）：$($_.Exception.Message)" '' ([PSCustomObject]@{ reason = 'query-error' })
        return
    }
}

$rows = $null
try {
    $csvLines = @($raw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($csvLines.Count -gt 0) { $rows = @($csvLines | ConvertFrom-Csv -ErrorAction Stop) }
} catch { $rows = $null }

$taskCol = ''; $execCol = ''
if ($rows -and $rows.Count -gt 0) {
    $props = @($rows[0].PSObject.Properties.Name)
    if ($props -contains '任务名') { $taskCol = '任务名' } elseif ($props -contains 'TaskName') { $taskCol = 'TaskName' }
    if ($props -contains '要运行的任务') { $execCol = '要运行的任务' } elseif ($props -contains 'Task To Run') { $execCol = 'Task To Run' }
}
if (-not $rows -or $rows.Count -eq 0 -or -not $taskCol -or -not $execCol) {
    Out-Result 'SKIP' "$cmdTagBase`n表头无法识别（unknown-locale：中英文列名都定位不到任务名/执行命令列）`n结论：schtasks 表头无法识别（unknown-locale）——任务名/执行命令列定位失败" '' ([PSCustomObject]@{ reason = 'unknown-locale' })
    return
}

$third = 0
$susp = @()
$norm = @()
foreach ($r in $rows) {
    $t = ([string]$r.$taskCol).Trim()
    if ($t -eq '') { continue }
    if ($t -match '^\\Microsoft\\') { continue }
    $third++
    $exec = ([string]$r.$execCol).Trim()
    $c = Classify-Exec $exec
    if ($c.susp) { $susp += [PSCustomObject]@{ task = $t; exec = $exec; reason = $c.reason } }
    else { $norm += [PSCustomObject]@{ task = $t; exec = $exec } }
}

$tag = "schtasks /query /fo csv /v · 非微软任务 $third 条，其中指向用户可写目录 $($susp.Count) 条"
$lines = @("[$tag]")
foreach ($s in $susp) { $lines += ('[可疑] {0} → {1}（{2}）' -f $s.task, $s.exec, $s.reason) }
foreach ($n in $norm) { $lines += ('[正常] {0} → {1}' -f $n.task, $n.exec) }
$head = $lines -join "`n"
$detail = [PSCustomObject]@{ totalTasks = $rows.Count; thirdParty = $third; suspicious = @($susp); normal = @($norm) }

if ($susp.Count -gt 0) {
    $suggestion = "发现 $($susp.Count) 条指向用户可写目录（用户目录/临时目录/ProgramData）的计划任务——自己加的同步/下载/脚本任务是常态，但恶意软件把持久化藏在这里也是常态，逐条认领一遍：认识=保留，不认识=禁用后观察。`n【人工路径】打开「计划任务核查」处置卡（修复中心-红卡），照五要素逐条过。`n【回滚】不适用（禁用的任务右键「启用」即恢复）"
    Out-Result 'FAIL' "$head`n结论：发现 $($susp.Count) 条指向用户可写目录的计划任务——大多数是自装工具（同步/下载/脚本），也须逐条认领（恶意软件持久化头号位置）" $suggestion $detail
} elseif ($third -gt 0) {
    Out-Result 'PASS' "$head`n第三方任务 $third 条，全部位于系统只读目录，正常软件自启" '' $detail
} else {
    Out-Result 'PASS' "$head`n第三方任务 0 条——计划任务全部来自微软自带组件" '' $detail
}

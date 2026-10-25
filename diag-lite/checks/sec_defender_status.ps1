#Requires -Version 5.1
<#
检查项：sec_defender_status —— Defender 防护开关与病毒库新鲜度（层：defender）
命令：Get-MpComputerStatus（只读）
判定（安全树规格 v1.6 第一节 1）：
  查询异常→SKIP(query-error)；AMRunningMode=Passive Mode/SxS Mode→SKIP(third-party-av，第三方杀软接管属正常态)；
  AntivirusEnabled=False 或 RealTimeProtectionEnabled=False→FAIL；病毒库年龄>7 天→FAIL（工程线：安全智能每日多次发布，7 天未更=明显滞后）；
  3<年龄≤7→PASS 附注「建议尽快手动更新」；年龄≤3 且开关全开→PASS
出处：https://learn.microsoft.com/en-us/powershell/module/defender/get-mpcomputerstatus
mock 契约：逐行 `字段=值`（AMRunningMode/AntivirusEnabled/RealTimeProtectionEnabled/AntivirusSignatureAge/AntivirusSignatureLastUpdated）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result { param($Status, $Evidence, $Suggestion, $Detail)
    [PSCustomObject]@{
        name = 'sec_defender_status'; status = $Status; evidence = $Evidence; suggestion = $Suggestion; detail = $Detail
    } | ConvertTo-Json -Depth 5
}

$cmdTag = '[Get-MpComputerStatus]'
$mode = ''; $av = $true; $rtp = $true; $age = -1; $last = ''

if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $i = $ln.IndexOf('=')
        if ($i -le 0) { continue }
        $k = $ln.Substring(0, $i).Trim(); $v = $ln.Substring($i + 1).Trim()
        if ($k -eq 'AMRunningMode') { $mode = $v }
        elseif ($k -eq 'AntivirusEnabled') { $av = ($v -ieq 'True') }
        elseif ($k -eq 'RealTimeProtectionEnabled') { $rtp = ($v -ieq 'True') }
        elseif ($k -eq 'AntivirusSignatureAge') { if ($v -match '^-?\d+$') { $age = [int]$v } }
        elseif ($k -eq 'AntivirusSignatureLastUpdated') { $last = $v }
    }
} else {
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        $mode = [string]$s.AMRunningMode
        $av = [bool]$s.AntivirusEnabled
        $rtp = [bool]$s.RealTimeProtectionEnabled
        if ($null -ne $s.AntivirusSignatureAge) { $age = [int]$s.AntivirusSignatureAge }
        if ($null -ne $s.AntivirusSignatureLastUpdated) { $last = [string]$s.AntivirusSignatureLastUpdated }
    } catch {
        Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：$($_.Exception.Message)" '' ([PSCustomObject]@{ reason = 'query-error' })
        return
    }
}

$ageLine = if ($age -ge 0) { "病毒库年龄: $age 天（最近更新: $last）" } else { "病毒库年龄: 未知（最近更新: $last）" }
$head = "$cmdTag`n运行模式: $mode`n杀毒防护: $av | 实时保护: $rtp`n$ageLine"
$detail = [PSCustomObject]@{ mode = $mode; antivirus = $av; realtime = $rtp; sigAgeDays = $age; sigLastUpdated = $last }

if ($mode -in @('Passive Mode', 'SxS Mode')) {
    $d = [PSCustomObject]@{ reason = 'third-party-av'; mode = $mode; antivirus = $av; realtime = $rtp; sigAgeDays = $age; sigLastUpdated = $last }
    Out-Result 'SKIP' "$head`n结论：检测到第三方杀软接管（运行模式: $mode）——Defender 让位属正常态，本项开关读数不判定" '' $d
    return
}

$probs = @()
$off = @()
if (-not $av) { $off += '杀毒防护' }
if (-not $rtp) { $off += '实时保护' }
if ($off.Count -gt 0) { $probs += ('Defender 防护被关闭（' + ($off -join '、') + '=False）') }
if ($age -gt 7) { $probs += "病毒库已 $age 天未更新（阈值 7 天）" }

if ($probs.Count -gt 0) {
    $suggestion = "Defender 防护被关闭或病毒库严重过期——这是恶意软件进门前的第一道闸。`n【人工路径】Win+I →「隐私和安全性」→「Windows 安全中心」→「病毒和威胁防护」→ 无「此设置由管理员管理」红字时，把「实时保护」开到「开」；病毒库过期就点「快速扫描」（扫描前会自动拉最新病毒库）。`n【回滚】不适用（恢复为关闭需再走同一路径，改回「关」即可）"
    Out-Result 'FAIL' "$head`n结论：$($probs -join '；')" $suggestion $detail
    return
}

$tail = if ($age -gt 3) { "`n病毒库已 $age 天未更新，建议尽快手动更新" } else { '' }
Out-Result 'PASS' ($head + $tail) '' $detail

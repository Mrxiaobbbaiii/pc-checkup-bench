#Requires -Version 5.1
<#
检查项：sec_defender_exclusions —— Defender 查杀排除项清单（层：defender）
命令：Get-MpPreference（只读；标准用户下排除项内容为占位文本→SKIP admin-required）
判定（安全树规格 v1.6 第一节 2）：查询异常→SKIP(query-error)；任一字段值含占位文本→SKIP(admin-required)；
  四清单全空→PASS；任一非空→FAIL（每个排除项=一个查杀盲区）
出处：https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-exclusions-overview
mock 契约：逐行 `字段=值`（ExclusionPath/ExclusionExtension/ExclusionProcess/ExclusionIpAddress；多条目用 `; ` 分隔；空值=该清单为空）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result { param($Status, $Evidence, $Suggestion, $Detail)
    [PSCustomObject]@{
        name = 'sec_defender_exclusions'; status = $Status; evidence = $Evidence; suggestion = $Suggestion; detail = $Detail
    } | ConvertTo-Json -Depth 5
}

$cmdTag = '[Get-MpPreference]'
$placeholder = 'Must be an administrator to view exclusions'
$order = @('ExclusionPath', 'ExclusionExtension', 'ExclusionProcess', 'ExclusionIpAddress')
$cn = @{ ExclusionPath = '排除路径'; ExclusionExtension = '排除扩展名'; ExclusionProcess = '排除进程'; ExclusionIpAddress = '排除IP' }
$data = @{}
foreach ($k in $order) { $data[$k] = @{ raw = @(); ph = $false } }

if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $i = $ln.IndexOf('=')
        if ($i -le 0) { continue }
        $k = $ln.Substring(0, $i).Trim(); $v = $ln.Substring($i + 1).Trim()
        if (-not $data.ContainsKey($k)) { continue }
        if ($v -eq '') { continue }
        if ($v.Contains($placeholder)) { $data[$k].ph = $true; $data[$k].raw = @($v) }
        else { $data[$k].raw = @(($v -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
    }
} else {
    try {
        $p = Get-MpPreference -ErrorAction Stop
        foreach ($k in $order) {
            $vals = @()
            foreach ($item in @($p.$k)) { if ($null -ne $item) { $vals += ([string]$item).Trim() } }
            $vals = @($vals | Where-Object { $_ -ne '' })
            $hit = @($vals | Where-Object { $_.Contains($placeholder) })
            if ($hit.Count -gt 0) { $data[$k].ph = $true }
            $data[$k].raw = $vals
        }
    } catch {
        Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：$($_.Exception.Message)" '' ([PSCustomObject]@{ reason = 'query-error' })
        return
    }
}

function Fmt-Line { param($k)
    $d = $data[$k]
    if ($d.ph) { return ('{0}: {1}' -f $cn[$k], $placeholder) }
    if ($d.raw.Count -gt 0) { return ('{0}({1}): {2}' -f $cn[$k], $d.raw.Count, ($d.raw -join '; ')) }
    return ('{0}(0): （无）' -f $cn[$k])
}

$anyPh = @($order | Where-Object { $data[$_].ph }).Count -gt 0

if ($anyPh) {
    $lines = @(foreach ($k in $order) { Fmt-Line $k })
    $suggestion = '排除项内容需要管理员权限才能读取（本工具不提权，看不到≠没有）。' + "`n" + '【人工路径】Win+I →「隐私和安全性」→「Windows 安全中心」→「病毒和威胁防护」→「"病毒和威胁防护"设置」下的「管理设置」→ 拉到最底部「排除项」→「添加或删除排除项」——列表是空的就安心；有条目就走「排除项核对」处置卡逐条过目。' + "`n" + '【回滚】不适用（只读核对）'
    Out-Result 'SKIP' "$cmdTag`n$($lines -join "`n")`n结论：排除项内容需要管理员权限才能读取——本工具不提权，看不到≠没有，请按建议人工核对" $suggestion ([PSCustomObject]@{ readable = $false; reason = 'admin-required' })
    return
}

$total = 0
foreach ($k in $order) { $total += $data[$k].raw.Count }
$lines = @(foreach ($k in $order) { Fmt-Line $k })
$head = "$cmdTag`n" + ($lines -join "`n")
$detail = [PSCustomObject]@{
    readable = $true
    paths = @($data['ExclusionPath'].raw)
    extensions = @($data['ExclusionExtension'].raw)
    processes = @($data['ExclusionProcess'].raw)
    ipAddresses = @($data['ExclusionIpAddress'].raw)
}

if ($total -gt 0) {
    $suggestion = "Defender 存在 $total 条查杀排除项——每条排除项都是一个查杀盲区（微软官方口径），不认识的条目=可能是恶意软件或破解工具自己加的免检通道。`n【人工路径】打开「排除项核对」处置卡（修复中心-红卡），逐条核对：自己或可信软件加的保留；不认识的删除。`n【回滚】不适用（删错了重新添加即可）"
    Out-Result 'FAIL' "$head`n结论：Defender 存在 $total 条查杀排除项——每条排除项都是一个查杀盲区（微软官方口径），不认识的条目=可能是恶意软件或破解工具自己加的免检通道" $suggestion $detail
} else {
    Out-Result 'PASS' "$head`n无排除项，防护无盲区" '' $detail
}

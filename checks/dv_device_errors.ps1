#Requires -Version 5.1
<#
检查项：dv_device_errors —— 设备管理器错误码（层：suspect，框架第七节路线图 v0.5 钦点项）
命令：Get-CimInstance Win32_PnPEntity（Name/ConfigManagerErrorCode/DeviceID，只读）；ErrorCode≠0=设备管理器带黄三角设备
软码豁免（官方码表语义）：22=已被禁用、45=上次会话的残留记录→非故障态不进 FAIL
高频码人话（官方码表内置）：10=无法启动、12=资源冲突、28=未安装驱动、31=无法正常工作、43=Windows 已因故障停用它；未收录码=「Code N（详见设备管理器属性页）」
判定（design 十二节 5，施工单 v0.5 条目 5）：存在 ErrorCode∉{0,22,45} ≥1→FAIL 逐台点名；仅软码→PASS 附注；全 0→PASS 附设备总数；查询失败→SKIP
mock 契约：逐行 `设备名 | ErrorCode`；首行 QUERY-ERROR=SKIP；空=SKIP（空结果物理上不可能=无数据非无故障）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$softCodes = @(22, 45)
$codeHuman = @{
    10 = '无法启动'
    12 = '资源冲突'
    28 = '未安装驱动'
    31 = '无法正常工作'
    43 = 'Windows 已因故障停用它'
}

$skipOut = {
    param([string]$Why, [string]$Reason)
    [PSCustomObject]@{
        name = 'dv_device_errors'; status = 'SKIP'
        evidence = "[Win32_PnPEntity ConfigManagerErrorCode≠0]`n$Why——不是「设备全正常」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = $Reason }
    } | ConvertTo-Json -Depth 5
}

$devs = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') { & $skipOut '查询失败（无法判定）：模拟：设备枚举不可读' 'query-error'; return }
    $lines = @($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { & $skipOut '无设备数据（查询无数据——空结果物理上不可能，属查询异常）' 'no-data'; return }
    foreach ($ln in $lines) {
        $f = $ln -split '\s*\|\s*', 2
        if ($f.Count -ge 2) {
            $code = 0
            try { $code = [int]$f[1].Trim() } catch { $code = 0 }
            $devs += [PSCustomObject]@{ name = $f[0].Trim(); code = $code }
        }
    }
} else {
    try {
        $raw = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)
    } catch {
        [PSCustomObject]@{
            name = 'dv_device_errors'; status = 'SKIP'
            evidence = "[Win32_PnPEntity ConfigManagerErrorCode≠0]`n查询失败（无法判定）：$($_.Exception.Message)——不是「设备全正常」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    if ($raw.Count -eq 0) { & $skipOut '无设备数据（查询无数据——空结果物理上不可能，属查询异常）' 'no-data'; return }
    foreach ($d in $raw) {
        $devs += [PSCustomObject]@{ name = [string]$d.Name; code = [int]$d.ConfigManagerErrorCode }
    }
}

$errs = @($devs | Where-Object { $_.code -ne 0 -and $softCodes -notcontains $_.code })
$soft = @($devs | Where-Object { $softCodes -contains $_.code })

$cmdTag = '[Win32_PnPEntity ConfigManagerErrorCode≠0]'

if ($errs.Count -ge 1) {
    $status = 'FAIL'
    $eLines = ($errs | ForEach-Object {
        $h = if ($codeHuman.ContainsKey([string]$_.code)) { $codeHuman[[string]$_.code] } else { '详见设备管理器属性页' }
        'Code {0}: {1}（{2}）' -f $_.code, $_.name, $h
    }) -join "`n"
    $evidence = "$cmdTag`n共 $($errs.Count) 台设备在报错:`n$eLines"
    # suggestion 按码给方向（官方码表语义）
    $dir = @()
    $c28 = @($errs | Where-Object { $_.code -eq 28 }); if ($c28.Count -ge 1) { $dir += 'Code 28=驱动没装（重插设备/装对应驱动）' }
    $c43 = @($errs | Where-Object { $_.code -eq 43 }); if ($c43.Count -ge 1) { $dir += 'Code 43=设备自报故障（换 USB 口/换线试，仍报=设备本体问题）' }
    $c10 = @($errs | Where-Object { $_.code -eq 10 }); if ($c10.Count -ge 1) { $dir += 'Code 10=无法启动（更新驱动或重启后再看）' }
    $etc = @($errs | Where-Object { @(28, 43, 10) -notcontains $_.code })
    if ($etc.Count -ge 1) { $dir += '其余码=在设备管理器属性页看官方说明，方向多为更新驱动或卸载后重插' }
    $suggestion = "$($errs.Count) 台设备带黄三角在报错。$($dir -join '；')。`n【修复命令，请自己执行】无（设备管理器→右键对应设备→更新驱动程序 或 卸载设备后重插）`n【回滚】重插设备即重新枚举；更新驱动可在设备管理器回退"
} elseif ($soft.Count -ge 1) {
    $status = 'PASS'
    $softLines = ($soft | ForEach-Object { 'Code {0}: {1}（{2}）' -f $_.code, $_.name, $(if ($_.code -eq 22) { '已被禁用' } else { '上次会话残留记录' }) }) -join "`n"
    $evidence = "$cmdTag`n无硬故障码。$($soft.Count) 台已禁用/残留设备（非故障）：`n$softLines"
    $suggestion = ''
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n共 $($devs.Count) 台设备全部正常（ConfigManagerErrorCode=0，无黄三角）"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'dv_device_errors'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{
        total = $devs.Count
        errors = @($errs | ForEach-Object { [PSCustomObject]@{ name = $_.name; code = $_.code; human = $(if ($codeHuman.ContainsKey([string]$_.code)) { $codeHuman[[string]$_.code] } else { '详见设备管理器属性页' }) } })
        soft = @($soft | ForEach-Object { [PSCustomObject]@{ name = $_.name; code = $_.code } })
    }
} | ConvertTo-Json -Depth 6

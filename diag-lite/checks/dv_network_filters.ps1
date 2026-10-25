#Requires -Version 5.1
<#
检查项：dv_network_filters —— 网络栈第三方过滤链（层：stack）
命令：Get-NetAdapterBinding -IncludeHidden（NetAdapter 模块 Win8+ 自带，只读）→ Enabled=$true 且 ComponentID 不以 ms_ 开头（ms_ 前缀=微软内置组件口径）→ 按 ComponentID 去重（DisplayName 取首见值；同一过滤驱动绑 3 张网卡≠叠 3 层）
名单标注：可选加载 checks/bs_suspects.json（-SuspectsFile 参数同 bs_suspect_drivers 先例）；ComponentID 或 DisplayName 包含 pattern→evidence 该行附 `<- label`；文件缺失/损坏→不标注不崩（通用文案照常）
判定（design 十二节 4，施工单 v0.5 条目 4）：去重后 ≥3→FAIL；1-2→PASS 附注点名；0→PASS；cmdlet 不可用/无适配器→SKIP。3 层线=工程线
mock 契约：逐行 `ComponentID | DisplayName | Enabled`（Enabled 写 True/False，False 行验证不计数）；首行 NO-CMDLET=SKIP；空=SKIP
交叉锚：nnndisfilter 属 NDIS 过滤驱动，在装则必现于绑定链→与蓝屏树证据一致。
#>
param([string]$MockRaw = '', [string]$MockFile = '', [string]$SuspectsFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# 名单标注可选：缺失/损坏→不标注不崩（与 bs_suspect_drivers 的 SKIP 语义不同——名单在这里只是增强显示）
$labels = @()
if ($SuspectsFile -ne '') {
    $listPath = $SuspectsFile
} else {
    $listPath = Join-Path $PSScriptRoot 'bs_suspects.json'
}
try {
    $sl = (Get-Content -LiteralPath $listPath -Raw -Encoding UTF8 | ConvertFrom-Json).suspects
    if ($sl) { $labels = @($sl) }
} catch { $labels = @() }

$skipOut = {
    param([string]$Why, [string]$Reason)
    [PSCustomObject]@{
        name = 'dv_network_filters'; status = 'SKIP'
        evidence = "[Get-NetAdapterBinding -IncludeHidden]`n$Why——不是「网络栈干净」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = $Reason }
    } | ConvertTo-Json -Depth 5
}

$bindings = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'NO-CMDLET') { & $skipOut 'Get-NetAdapterBinding 不可用（精简系统裁掉了 NetAdapter 模块）' 'no-cmdlet'; return }
    $lines = @($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { & $skipOut '无适配器绑定数据（查询无数据）' 'no-data'; return }
    foreach ($ln in $lines) {
        $f = $ln -split '\s*\|\s*', 3
        if ($f.Count -ge 2) {
            $bindings += [PSCustomObject]@{
                id = $f[0].Trim(); display = $(if ($f.Count -gt 1) { $f[1].Trim() } else { '' })
                enabled = $(if ($f.Count -gt 2) { $f[2].Trim() -ieq 'True' } else { $true })
            }
        }
    }
} else {
    if (-not (Get-Command Get-NetAdapterBinding -ErrorAction SilentlyContinue)) {
        & $skipOut 'Get-NetAdapterBinding 不可用（精简系统裁掉了 NetAdapter 模块）' 'no-cmdlet'; return
    }
    try {
        $raw = @(Get-NetAdapterBinding -IncludeHidden -ErrorAction Stop)
    } catch {
        [PSCustomObject]@{
            name = 'dv_network_filters'; status = 'SKIP'
            evidence = "[Get-NetAdapterBinding -IncludeHidden]`n查询失败（无法判定）：$($_.Exception.Message)——不是「网络栈干净」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    if ($raw.Count -eq 0) { & $skipOut '无适配器绑定数据（查询无数据）' 'no-data'; return }
    foreach ($b in $raw) {
        $bindings += [PSCustomObject]@{ id = [string]$b.ComponentID; display = [string]$b.DisplayName; enabled = [bool]$b.Enabled }
    }
}

# ---------- 过滤：Enabled=True 且非 ms_ 前缀，按 ComponentID 去重（DisplayName 首见） ----------
$third = @{}
$seenMs = 0
foreach ($b in $bindings) {
    if (-not $b.enabled) { continue }
    if ($b.id -like 'ms_*') { $seenMs++; continue }
    if (-not $third.ContainsKey($b.id)) { $third[$b.id] = $b.display }
}
$filters = @($third.GetEnumerator() | Sort-Object Name)

function Get-FilterLabel { param($Id, $Display)
    foreach ($l in $labels) {
        if (($Id -like "*$($l.pattern)*") -or ($Display -like "*$($l.pattern)*")) { return $l.label }
    }
    return ''
}

$cmdTag = '[Get-NetAdapterBinding -IncludeHidden Enabled 第三方绑定去重]'
$msLine = ''
if ($seenMs -gt 0) { $msLine = "`n微软内置组件 $seenMs 项启用（ms_ 前缀豁免，不计数）" }

if ($filters.Count -ge 3) {
    $status = 'FAIL'
    $fLines = ($filters | ForEach-Object {
        $lb = Get-FilterLabel $_.Key $_.Value
        $line = '{0}（{1}）' -f $_.Key, $_.Value
        if ($lb) { $line = "$line <- $lb" }
        $line
    }) -join "`n"
    $evidence = "$cmdTag`n共 $($filters.Count) 层第三方过滤$msLine`n$fLines"
    $suggestion = "网络栈上叠了 $($filters.Count) 层第三方过滤=断网与蓝屏双隐患（每层都能拦包，一层抽风全网断）。按点名 ComponentID 搜所属软件（加速器/杀软/代理类），去 设置→应用 卸载不用的；卸载后绑定层随之消失。`n【修复命令，请自己执行】无（卸载对应加速器/杀软）`n【回滚】需要时重新安装该软件"
} elseif ($filters.Count -ge 1) {
    $status = 'PASS'
    $fLines = ($filters | ForEach-Object {
        $lb = Get-FilterLabel $_.Key $_.Value
        $line = '{0}（{1}）' -f $_.Key, $_.Value
        if ($lb) { $line = "$line <- $lb" }
        $line
    }) -join "`n"
    $evidence = "$cmdTag`n第三方过滤 $($filters.Count) 层（未达 3 层警戒线）$msLine`n$fLines"
    $suggestion = ''
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n第三方过滤 0 层，仅微软内置组件$msLine"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'dv_network_filters'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{
        filters = $filters.Count
        items = @($filters | ForEach-Object {
            $lb = Get-FilterLabel $_.Key $_.Value
            [PSCustomObject]@{ id = $_.Key; display = $_.Value; enabled = $true; hit = [bool]$lb }
        })
    }
} | ConvertTo-Json -Depth 6

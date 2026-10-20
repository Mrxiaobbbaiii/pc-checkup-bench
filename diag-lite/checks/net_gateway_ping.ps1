#Requires -Version 5.1
<#
检查项：net_gateway_ping —— 网关可达性（逐默认网关 ping）
层：网关/路由层。命令：route print -4 + ping -n 1 -w 2000 <网关>（只读）
判定：任一默认网关 ping 通 = PASS；全部不通 = FAIL（网关不可达→链路层/路由器嫌疑）
mock 契约：段1=route print -4；后续段以 '###GW <ip>' 开头=该网关的 ping 原始输出（===PART=== 分隔）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$parts = @()
if ($MockRaw -ne '') {
    $parts = @($MockRaw -split '===PART===' | ForEach-Object { $_.Trim("`r`n") })
} else {
    $routeRaw = (& route print -4 2>&1 | Out-String)
    $gws = @()
    foreach ($line in ($routeRaw -split "`r?`n")) {
        if ($line -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d{1,3}(?:\.\d{1,3}){3})\s+') { $gws += $Matches[1] }
    }
    $gws = @($gws | Select-Object -Unique)
    $parts = @($routeRaw)
    foreach ($g in $gws) {
        $parts += ("###GW $g`n" + ((& ping -n 1 -w 2000 $g 2>&1 | Out-String)))
    }
}

$routePart = $parts[0]
$gws = @()
foreach ($line in ($routePart -split "`r?`n")) {
    if ($line -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d{1,3}(?:\.\d{1,3}){3})\s+') { $gws += $Matches[1] }
}
$gws = @($gws | Select-Object -Unique)

$results = @()
for ($i = 1; $i -lt $parts.Count; $i++) {
    if ($parts[$i] -match '###GW\s+(\d{1,3}(?:\.\d{1,3}){3})') {
        $gw = $Matches[1]
        $pingText = ($parts[$i] -split "`r?`n" | Select-Object -Skip 1) -join "`n"
        $ok = $pingText -match 'TTL=\d+'
        $keyLine = ($pingText -split "`r?`n" | Where-Object { $_ -match 'TTL=|timed out|超时|Unreachable|无法访问|General failure' } | Select-Object -First 1)
        $results += [PSCustomObject]@{ gateway = $gw; reachable = [bool]$ok; pingLine = $keyLine }
    }
}

if ($gws.Count -eq 0) {
    $status = 'SKIP'   # 无网关场景由 net_gateway_conflict 报 FAIL
} elseif ($results.Count -eq 0) {
    $status = 'SKIP'
} elseif (@($results | Where-Object { $_.reachable }).Count -ge 1) {
    $status = 'PASS'
} else {
    $status = 'FAIL'
}

$evidence = "[route print -4 / ping -n 1 -w 2000 <gw>]`n" + (($results | ForEach-Object { "{0} -> {1}  ({2})" -f $_.gateway, $(if ($_.reachable) { 'OK' } else { 'DEAD' }), $_.pingLine }) -join "`n")

$suggestion = if ($status -eq 'FAIL') {
    "默认网关 ping 不通：电脑到路由器这段断了。WiFi 场景先看信号格数/重连一次；有线场景换网线/换口。`n" +
    "路由器若死机：断电 30 秒重启。`n" +
    "【修复命令，请自己执行】无（本项修复是物理操作或重启路由器，无系统命令）`n" +
    "【回滚】不适用"
} elseif (@($results | Where-Object { -not $_.reachable }).Count -gt 0) {
    "部分网关不可达（见证据），存在可用网关，配合 net_gateway_conflict 的结论看是否清理死路由。"
} else { '' }

[PSCustomObject]@{
    name       = 'net_gateway_ping'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ gateways = $results }
} | ConvertTo-Json -Depth 5

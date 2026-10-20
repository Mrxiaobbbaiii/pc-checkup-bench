#Requires -Version 5.1
<#
检查项：net_public_ping —— 强制逐网卡公网 ping（ping -S 源地址）
层：WAN 层。命令：route print -4 + ping -S <源IP> -n 1 -w 2000 223.5.5.5（只读）
判定：任一源地址能 ping 通公网 = PASS；全部不通 = FAIL（网关通+公网不通 → 路由器 WAN 侧/光猫/线路）
mock 契约：段1=route print -4；后续段 '###SRC <ip>' 开头=该源的 ping 输出（===PART=== 分隔）
注：tracert -S 在本机不可用，勿依赖（框架 v0.1 实战结论）。
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
    $srcs = @()
    foreach ($line in ($routeRaw -split "`r?`n")) {
        if ($line -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+\d{1,3}(?:\.\d{1,3}){3}\s+(\d{1,3}(?:\.\d{1,3}){3})\s+\d+\s*$') { $srcs += $Matches[1] }
    }
    $srcs = @($srcs | Select-Object -Unique)
    $parts = @($routeRaw)
    foreach ($s in $srcs) {
        $parts += ("###SRC $s`n" + ((& ping -S $s -n 1 -w 2000 223.5.5.5 2>&1 | Out-String)))
    }
}

$routePart = $parts[0]
$srcs = @()
foreach ($line in ($routePart -split "`r?`n")) {
    if ($line -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+\d{1,3}(?:\.\d{1,3}){3}\s+(\d{1,3}(?:\.\d{1,3}){3})\s+\d+\s*$') { $srcs += $Matches[1] }
}
$srcs = @($srcs | Select-Object -Unique)

$results = @()
for ($i = 1; $i -lt $parts.Count; $i++) {
    if ($parts[$i] -match '###SRC\s+(\d{1,3}(?:\.\d{1,3}){3})') {
        $src = $Matches[1]
        $pingText = ($parts[$i] -split "`r?`n" | Select-Object -Skip 1) -join "`n"
        $ok = $pingText -match 'TTL=\d+'
        $keyLine = ($pingText -split "`r?`n" | Where-Object { $_ -match 'TTL=|timed out|超时|Unreachable|无法访问|General failure|transmit failed' } | Select-Object -First 1)
        $results += [PSCustomObject]@{ source = $src; reachable = [bool]$ok; pingLine = $keyLine }
    }
}

if ($srcs.Count -eq 0 -or $results.Count -eq 0) {
    $status = 'SKIP'   # 无默认路由场景由 net_gateway_conflict 报 FAIL
} elseif (@($results | Where-Object { $_.reachable }).Count -ge 1) {
    $status = 'PASS'
} else {
    $status = 'FAIL'
}

$evidence = "[ping -S <src> -n 1 -w 2000 223.5.5.5]`n" + (($results | ForEach-Object { "src={0} -> {1}  ({2})" -f $_.source, $(if ($_.reachable) { 'OK' } else { 'DEAD' }), $_.pingLine }) -join "`n")

$suggestion = if ($status -eq 'FAIL') {
    "所有网卡都 ping 不通公网（223.5.5.5），但前面网关是通的：问题在路由器往外这一段——光猫死机/光纤线路故障/欠费停机。`n" +
    "【修复命令，请自己执行】无系统命令可修 WAN 侧，按顺序做物理检查：`n" +
    "  1. 看光猫指示灯：LOS 红灯闪=光路故障；`n" +
    "  2. 光猫和路由器都断电 30 秒再上电；`n" +
    "  3. 仍不通=打运营商报修电话（电信10000/联通10010/移动10086）。`n" +
    "【回滚】不适用（均为物理操作）"
} elseif (@($results | Where-Object { -not $_.reachable }).Count -gt 0) {
    "部分源地址出不了公网（见证据）：该网卡的上联链路有问题，但存在可用链路，不算当前断点。"
} else { '' }

[PSCustomObject]@{
    name       = 'net_public_ping'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ sources = $results }
} | ConvertTo-Json -Depth 5

#Requires -Version 5.1
<#
检查项：net_gateway_conflict —— 多默认网关冲突检测
层：网关/路由层。命令：route print -4（只读）
判定：无默认路由 = FAIL(缺网关)；1 条 = PASS；>=2 条且最小跃点并列 = FAIL(冲突，双出口抢道)；
      >=2 条跃点不同 = PASS（低跃点优先，附注）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$cmd = 'route print -4'
$raw = if ($MockRaw -ne '') { $MockRaw } else { (& route print -4 2>&1 | Out-String) }

$routes = @()
foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d+)\s*$') {
        $routes += [PSCustomObject]@{ gateway = $Matches[1]; iface = $Matches[2]; metric = [int]$Matches[3]; rawLine = $line.Trim() }
    }
}

# 本机网段表（On-link 行：网络号+掩码），用于网关跨网段判定（微软官方故障模式：网关必须与网卡同网段）
$subnets = @()
foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\d{1,3}(?:\.\d{1,3}){3})\s+On-link\s+\d{1,3}(?:\.\d{1,3}){3}\s+\d+\s*$') {
        $p = ConvertTo-NetworkPrefix $Matches[1] $Matches[2]
        if ($p) { $subnets += $p }
    }
}
$subnets = @($subnets | Select-Object -Unique)
$orphanGw = @()
if ($subnets.Count -gt 0) {
    # 网段表非空才判跨段（route 输出缺 On-link 行时信息不足，不定罪）
    foreach ($r in $routes) {
        $inAny = $false
        foreach ($s in $subnets) { if (Test-IpInPrefix $r.gateway $s) { $inAny = $true; break } }
        if (-not $inAny) { $orphanGw += $r.gateway }
    }
}

$minMetric = ($routes.metric | Measure-Object -Minimum).Minimum
$tied = @($routes | Where-Object { $_.metric -eq $minMetric })

if ($routes.Count -eq 0) {
    $status = 'FAIL'; $why = 'no-default-route'
} elseif ($orphanGw.Count -ge 1) {
    $status = 'FAIL'; $why = 'gateway-not-in-subnet'
} elseif ($routes.Count -eq 1) {
    $status = 'PASS'; $why = 'single'
} elseif ($tied.Count -ge 2) {
    $status = 'FAIL'; $why = 'conflict'
} else {
    $status = 'PASS'; $why = 'metric-preferred'
}

$routeText = ($routes | ForEach-Object { "gw={0} via-if={1} metric={2}" -f $_.gateway, $_.iface, $_.metric }) -join " | "
$evidence = "[$cmd]`n" + ($routes.rawLine -join "`n")

$suggestion = switch ($why) {
    'no-default-route' {
        "没有默认路由（0.0.0.0）：机器不知道往哪送外网流量，一般是网卡没拿到网关或被人为删了。`n" +
        "【修复命令，请自己执行】ipconfig /renew（DHCP 网卡会重新拿回网关）`n" +
        "【回滚】无需回滚；若原为手动配置：netsh interface ip set address `"<网卡名>`" static <原IP> <原掩码> <原网关>"
    }
    'gateway-not-in-subnet' {
        ($("默认网关 {0} 不在本机任何网卡网段内（微软官方记载的故障模式：网关必须与网卡同网段）——大概率是旧网段残留或手滑配错，出不了网。`n" +
        "本机网段：{1}`n" +
        "【修复命令，请自己执行】netsh interface ip set address `"<网卡名>`" dhcp（让路由器重新派发正确网关）`n" +
        "【回滚】netsh interface ip set address `"<网卡名>`" static <原IP> <原掩码> <原网关>（改回手动配置）") -f (($orphanGw | Select-Object -Unique) -join ' / '), ($subnets -join ', '))
    }
    'conflict' {
        ($("存在 {0} 条跃点相同的默认路由（{1}）：两条出口优先级一样，Windows 会来回切换，网页时通时断的典型元凶。`n" +
        "【修复命令，请自己执行（临时止血）】route delete 0.0.0.0 mask 0.0.0.0 <要放弃的网关IP>`n" +
        "【回滚】route add 0.0.0.0 mask 0.0.0.0 <该网关IP> metric 35 if <接口号>`n" +
        "【持久修法】netsh interface ipv4 set interface `"<该网卡名>`" metric=100（调高备用网卡跃点）`n" +
        "【持久修法回滚】netsh interface ipv4 set interface `"<该网卡名>`" metric=35（改回原值）") -f $tied.Count, (($tied.gateway) -join ' / '))
    }
    default { if ($routes.Count -gt 1) { "多条默认路由但跃点不同，低跃点({0})优先，暂不构成断点。" -f $minMetric } else { '' } }
}

[PSCustomObject]@{
    name       = 'net_gateway_conflict'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ routes = $routes; why = $why }
} | ConvertTo-Json -Depth 5

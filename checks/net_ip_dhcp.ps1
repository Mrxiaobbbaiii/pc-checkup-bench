#Requires -Version 5.1
<#
检查项：net_ip_dhcp —— 各活动网卡 IP/DHCP 状态（含 169.254 APIPA 自分配检测）
层：链路层。命令：netsh interface show interface + netsh interface ip show config（只读）
判定：存在 >=1 张活动网卡拿到正常(非169.254)IP = PASS（坏网卡附备注）；
      所有活动网卡都是 169.254.* 或无 IP = FAIL（DHCP 失败，APIPA 自分配）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

if ($MockRaw -ne '') {
    # mock 模式：MockRaw 即"各活动网卡 show config 输出"的拼接（以 === 分隔多网卡）
    $configs = @($MockRaw -split '===ADAPTER===' | Where-Object { $_.Trim() -ne '' })
} else {
    $adapters = Get-ActiveAdapterNames ((& netsh interface show interface 2>&1 | Out-String))
    $configs = @()
    foreach ($a in $adapters) { $configs += ((& netsh interface ip show config name="$a" 2>&1 | Out-String)) }
    if ($configs.Count -eq 0) { $configs = @('') }
}
$firstCfg = @($configs | Select-Object -First 1)[0]

$good = @(); $bad = @()
foreach ($cfg in $configs) {
    $ifName = if ($cfg -match 'Configuration for interface\s+"(.+?)"') { $Matches[1] } else { '<unknown>' }
    $ip = if ($cfg -match 'IP Address:\s+(\d{1,3}(?:\.\d{1,3}){3})') { $Matches[1] } else { '' }
    $dhcp = if ($cfg -match 'DHCP enabled:\s+(\w+)') { $Matches[1] } else { '?' }
    if ($ip -eq '') {
        $bad += "$ifName : no IP (DHCP=$dhcp)"
    } elseif ($ip -like '169.254.*') {
        $bad += "$ifName : $ip (APIPA self-assigned, DHCP=$dhcp)"
    } else {
        $prefix = if ($cfg -match 'Subnet Prefix:\s+(\S+)') { $Matches[1] } else { '' }
        $gw = if ($cfg -match 'Default Gateway:\s+(\d{1,3}(?:\.\d{1,3}){3})') { $Matches[1] } else { '(none)' }
        $good += [PSCustomObject]@{ adapter = $ifName; ip = $ip; prefix = $prefix; gateway = $gw }
    }
}

if ($firstCfg.Trim().Length -eq 0) {
    $status = 'SKIP'
} elseif ($good.Count -ge 1) {
    $status = 'PASS'
} else {
    $status = 'FAIL'
}

$evidenceLines = foreach ($g in $good) { "OK  {0} ip={1} prefix={2} gw={3}" -f $g.adapter, $g.ip, $g.prefix, $g.gateway }
$evidenceLines += foreach ($b in $bad) { "BAD $b" }
$evidence = "[netsh interface ip show config]`n" + ($evidenceLines -join "`n")

$suggestion = if ($status -eq 'FAIL') {
    "所有活动网卡都只拿到 169.254.* 自分配地址（或没有地址）：DHCP（自动给电脑分 IP 地址的服务）没人应答，通常是没连上路由器，或路由器 DHCP 挂了。`n" +
    "【修复命令，请自己执行】ipconfig /release 然后执行 ipconfig /renew`n" +
    "【回滚】无需回滚（release/renew 只重新要地址，不改配置）；若之前是手动 IP，用原参数 netsh interface ip set address 加回"
} elseif ($bad.Count -gt 0) {
    "有正常网卡可用=问题不在这；异常网卡的记录在证据里备用，现在不用动。"
} else { '' }

[PSCustomObject]@{
    name       = 'net_ip_dhcp'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ good = $good; bad = $bad }
} | ConvertTo-Json -Depth 5

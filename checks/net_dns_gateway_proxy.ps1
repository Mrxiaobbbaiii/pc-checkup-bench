#Requires -Version 5.1
<#
检查项：net_dns_gateway_proxy —— 路由器 DNS 代理测试（nslookup 指向网关）
层：DNS 层。命令：route print -4 + nslookup qq.com <网关>（只读）
判定：任一网关能当 DNS 用 = PASS（路由器代理活着）；全部失败 = FAIL（路由器 DNS 代理挂/禁）
mock 契约：段1=route print -4；后续段 '###GW <ip>' 开头=该网关的 nslookup 输出（===PART=== 分隔）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

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
    foreach ($g in $gws) { $parts += ("###GW $g`n" + ((& nslookup qq.com $g 2>&1 | Out-String))) }
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
        $nsText = ($parts[$i] -split "`r?`n" | Select-Object -Skip 1) -join "`n"
        $v = Get-NslookupVerdict $nsText
        $results += [PSCustomObject]@{ gateway = $gw; mode = $v.mode; ok = $v.ok; keyLine = $v.keyLine }
    }
}

if ($gws.Count -eq 0 -or $results.Count -eq 0) {
    $status = 'SKIP'
} elseif (@($results | Where-Object { $_.ok }).Count -ge 1) {
    $status = 'PASS'
} else {
    $status = 'FAIL'
}

$evidence = "[nslookup qq.com <gw>]`n" + (($results | ForEach-Object { "gw={0} -> {1}  ({2})" -f $_.gateway, $_.mode, $_.keyLine }) -join "`n")

$suggestion = if ($status -eq 'FAIL') {
    "路由器（网关）不提供 DNS 解析：代理功能挂了或被关闭。电脑改为直接问公共 DNS 通常立即可用。`n" +
    "【修复命令，请自己执行】netsh interface ip set dns `"<网卡名>`" static 223.5.5.5`n" +
    "【回滚】netsh interface ip set dns `"<网卡名>`" dhcp（或 static <原DNS>）"
} else { '' }

[PSCustomObject]@{
    name       = 'net_dns_gateway_proxy'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ probes = $results }
} | ConvertTo-Json -Depth 5

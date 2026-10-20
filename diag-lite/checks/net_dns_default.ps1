#Requires -Version 5.1
<#
检查项：net_dns_default —— 默认 DNS 解析测试
层：DNS 层。命令：nslookup qq.com（系统默认 DNS，只读）
判定：解析成功 = PASS；失败细分 timeout / nxdomain / refused / server-error（人话各不同）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$cmd = 'nslookup qq.com'
$raw = if ($MockRaw -ne '') { $MockRaw } else { (& nslookup qq.com 2>&1 | Out-String) }

$v = Get-NslookupVerdict $raw
$status = if ($v.ok) { 'PASS' } elseif ($v.mode -eq 'unknown') { 'SKIP' } else { 'FAIL' }

$evidence = "[$cmd]`n" + $v.keyLine

$suggestion = switch ($v.mode) {
    'timeout' {
        "默认 DNS 应答超时：DNS 服务器没响应（死地址或 DNS 服务挂了）。`n" +
        "【修复命令，请自己执行】netsh interface ip set dns `"<网卡名>`" static 223.5.5.5`n" +
        "【回滚】netsh interface ip set dns `"<网卡名>`" dhcp（或 static <原DNS>）"
    }
    'nxdomain' {
        "默认 DNS 回答 qq.com 不存在——qq.com 必然存在，这是 DNS 劫持/污染或 DNS 缓存投毒的特征。`n" +
        "【修复命令，请自己执行】ipconfig /flushdns（先清缓存试试）`n" +
        "【仍不行则换 DNS】netsh interface ip set dns `"<网卡名>`" static 223.5.5.5`n" +
        "【回滚】netsh interface ip set dns `"<网卡名>`" dhcp（或 static <原DNS>）"
    }
    'refused' {
        "默认 DNS 拒绝应答（Refused）：当前网络（校园网/公司网常见）不允许用这个 DNS，或该 DNS 禁止外部查询。`n" +
        "【修复命令，请自己执行】netsh interface ip set dns `"<网卡名>`" static 223.5.5.5`n" +
        "【回滚】netsh interface ip set dns `"<网卡名>`" dhcp（或 static <原DNS>）"
    }
    'server-error' {
        "默认 DNS 服务器自身报错（Server Failed）：DNS 服务端故障。`n" +
        "【修复命令，请自己执行】netsh interface ip set dns `"<网卡名>`" static 223.5.5.5`n" +
        "【回滚】netsh interface ip set dns `"<网卡名>`" dhcp（或 static <原DNS>）"
    }
    default { '' }
}

[PSCustomObject]@{
    name       = 'net_dns_default'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ mode = $v.mode; server = $v.server }
} | ConvertTo-Json -Depth 4

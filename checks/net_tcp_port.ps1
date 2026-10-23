#Requires -Version 5.1
<#
检查项：net_tcp_port —— 端口级连通（TCP 443）（层：wan；v1.2.0 片4）
命令：[System.Net.Dns]::GetHostAddresses（只读解析）+ .NET TcpClient BeginConnect 3 秒超时（只读连接测试）
判定（知识来源 §一未覆盖域#1：ICMP 不可靠时的权威替代）：域名解不出 → SKIP（断点更可能在 DNS 层，
      不冤枉 WAN）；443 连不上 → FAIL（端口级实锤：能 ping 通也白搭的形态）；连上 → PASS
mock 契约：
  RESOLVED | IP地址        或  RESOLVED | NONE
  TCP | 443 | True/False
首行 QUERY-ERROR=SKIP
官方依据：Test-NetConnection/TCP 连通性语义（learn.microsoft.com）；223.5.5.5/qq.com 443 为常见连通性探针口径。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$probeHost = 'www.qq.com'
$probePort = 443
$resolved = ''
$tcpOk = $false
$queryError = $false

if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：端口连通查询失败'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            $kind = if ($p.Count -ge 1) { $p[0].Trim().ToUpperInvariant() } else { '' }
            if ($kind -eq 'RESOLVED') {
                $v = if ($p.Count -ge 2) { $p[1].Trim() } else { '' }
                if ($v -ieq 'NONE') { $resolved = '' } else { $resolved = $v }
            } elseif ($kind -eq 'TCP') {
                $tcpOk = ($p.Count -ge 3 -and $p[2].Trim() -ieq 'True')
            }
        }
    }
} else {
    try {
        $addrs = @()
        try { $addrs = @([System.Net.Dns]::GetHostAddresses($probeHost) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }) } catch { $addrs = @() }
        if ($addrs.Count -eq 0) {
            $resolved = ''
        } else {
            $resolved = $addrs[0].IPAddressToString
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $ar = $client.BeginConnect($resolved, $probePort, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(3000) -and $client.Connected) { $tcpOk = $true }
                try { $client.Close() } catch { }
            } catch { $tcpOk = $false }
        }
    } catch {
        $queryError = $true
        $errText = "端口连通查询失败：$($_.Exception.Message)"
    }
}

$cmdTag = "[TCP 443 端口连通 × $probeHost]"
if ($queryError) {
    [PSCustomObject]@{
        name = 'net_tcp_port'; status = 'SKIP'
        evidence = "$cmdTag`n查询失败（无法判定）：$errText——不是「端口不通」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}
if ($resolved -eq '') {
    [PSCustomObject]@{
        name = 'net_tcp_port'; status = 'SKIP'
        evidence = "$cmdTag`n域名解不出（$probeHost 解析失败）——断点更可能在 DNS 层，本项不冤枉 WAN"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'dns-unresolved' }
    } | ConvertTo-Json -Depth 5
    return
}

if ($tcpOk) {
    $status = 'PASS'
    $evidence = "$cmdTag`n解析 $resolved → 443 端口 3 秒内连上（TCP 级连通正常）"
    $suggestion = ''
} else {
    $status = 'FAIL'
    $evidence = "$cmdTag`n解析 $resolved 成功，但 443 端口 3 秒内连不上（TCP 级实锤）——ping 通也白搭的形态常见于此：防火墙/安全软件拦端口、运营商或网络策略封 443、目标服务限连"
    $suggestion = "ICMP 能通不代表网页能开，网页走的正是 443 这样的端口。方向：①看装的安全软件/防火墙有没有「联网控制」在拦浏览器；②换一个网络（手机热点）对比——热点下正常=本网络策略问题，报运营商；③热点下也不通=本机软件侧，查最近装过的过滤/加速类软件。`n【回滚】本检查只读，无副作用。"
}

[PSCustomObject]@{
    name = 'net_tcp_port'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ resolved = $resolved; port = $probePort; tcpOk = $tcpOk }
} | ConvertTo-Json -Depth 6

#Requires -Version 5.1
<#
检查项：net_df_ping —— DF 大包探测（路径 MTU / PMTUD 黑洞）（层：wan；v1.2.0 片4）
命令：ping.exe -n 2 -f -l 1472 223.5.5.5（只读；IP 直探不依赖 DNS；1472+28=1500=标准以太网 MTU）
判定：REPLY → PASS（路径 MTU≥1500）；NEED-FRAG（中途设备回「需要分片但 DF 已设」）→ FAIL（MTU 不匹配实锤，
      典型=拨号 1492）；TIMEOUT → FAIL（黑洞嫌疑：小包能过、大包被静默丢，症状=部分网站打不开/微信通网页不通）；
      UNREACH → SKIP（WAN 本身断，前层项已管）；空/QUERY-ERROR → SKIP
mock 契约：`PING | REPLY | TTL=xx` / `PING | NEED-FRAG` / `PING | TIMEOUT` / `PING | UNREACH`；首行 QUERY-ERROR=SKIP；空=SKIP
官方依据：ping 命令参考（learn.microsoft.com windows-commands/ping，-f=-f 不允许分片、-l=length）；
      PMTUD 语义 RFC 1191/1981；223.5.5.5 允许 ICMP 口径同 net_public_ping（知识来源 §一）。
阈值标注：1472=标准 MTU 探针值（工程口径），1492=PPPoE 常见值（工程口径）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$probeIp = '223.5.5.5'
$result = ''
$ttl = ''
$queryError = $false

if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：ping 执行失败'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            if ($p.Count -ge 2 -and $p[0].Trim().ToUpperInvariant() -eq 'PING') {
                $result = $p[1].Trim().ToUpperInvariant()
                if ($p.Count -ge 3) { $ttl = $p[2].Trim() }
            }
        }
        if ($result -eq '') { $queryError = $true; $errText = 'PING 行缺失（查不到探测样本）' }
    }
} else {
    try {
        $raw = (& ping.exe -n 2 -f -l 1472 $probeIp 2>&1 | Out-String)
        if ($raw -match 'TTL[=:]\s*(\d+)') {
            $result = 'REPLY'; $ttl = "TTL=$($Matches[1])"
        } elseif ($raw -match '(?i)需要设置 DF|分片|fragment') {
            $result = 'NEED-FRAG'
        } elseif ($raw -match '(?i)无法访问目标主机|无法访问|unreachable') {
            $result = 'UNREACH'
        } elseif ($raw -match '(?i)超时|timed out') {
            $result = 'TIMEOUT'
        } else {
            $queryError = $true
            $head = (@($raw -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -First 3) -join ' | '
            $errText = "ping 输出不认识（不敢硬判）：$head"
        }
    } catch {
        $queryError = $true
        $errText = "ping 执行失败：$($_.Exception.Message)"
    }
}

$cmdTag = "[DF 大包探测 × $probeIp（1472 字节不分片）]"
if ($queryError -or $result -eq '' -or $result -eq 'UNREACH') {
    $why = if ($queryError) { $errText } elseif ($result -eq 'UNREACH') { '目标不可达（WAN 本身断，问题归前几项管）' } else { '探测数据查不到（无可用样本）' }
    [PSCustomObject]@{
        name = 'net_df_ping'; status = 'SKIP'
        evidence = "$cmdTag`n$why——本项跳过"
        suggestion = ''; detail = [PSCustomObject]@{ reason = $(if ($queryError) { 'query-error' } else { 'unreachable' }) }
    } | ConvertTo-Json -Depth 5
    return
}

if ($result -eq 'REPLY') {
    $status = 'PASS'
    $evidence = "$cmdTag`n1472 字节大包原样到达（$ttl）——路径 MTU≥1500，无分片黑洞"
    $suggestion = ''
} elseif ($result -eq 'NEED-FRAG') {
    $status = 'FAIL'
    $evidence = "$cmdTag`n中途设备明确回话「需要分片但 DF 已设」——路径 MTU 不足 1500 实锤（拨号线路常见 1492）"
    $suggestion = "这是「部分网站打不开/图片加载一半卡死/微信能通网页不行」的经典元凶：大包被路卡住，小包没事。方向：①进路由器管理页把 WAN 口 MTU 改成 1492 试（拨号线路）；②是运营商光猫桥接/企业网的，报修时直接说「路径 MTU 不足，PMTUD 黑洞」。`n【怎么开路由器管理页】浏览器地址栏输入 192.168.1.1 或 192.168.0.1 回车（路由器背面贴纸上有地址和密码），找「WAN 口设置 / 上网设置 / 高级设置」里的 MTU 一栏。`n【看到什么算成功】保存后重启路由器，回来重跑体检本项变绿（网页图片能整页加载）。`n【这步失败了先】管理页里找不到 MTU 一栏 = 机型不同，在 WAN/高级/网络参数里翻；改完没效果就把值改回原来的（默认 1500），打运营商电话说明「PMTUD 黑洞」。`n【回滚】本检查只读无副作用；路由器改动记下原值即可改回。"
} else {
    $status = 'FAIL'
    $evidence = "$cmdTag`n1472 大包两次探测全部超时——PMTUD 黑洞嫌疑：中途有设备把「太大」的大包静默丢弃且不回话"
    $suggestion = "小包能过、大包被静默丢=「部分网站打不开」的经典形态（黑洞型 MTU 问题）。方向：①重启路由器/光猫再测（临时状态多）；②进路由器把 MTU 固定为 1492 或 1480；③VPN/加速器开着先关——它们的隧道也会吃 MTU。`n【回滚】本检查只读，无副作用。"
}

[PSCustomObject]@{
    name = 'net_df_ping'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ probe = $probeIp; size = 1472; result = $result; ttl = $ttl }
} | ConvertTo-Json -Depth 6

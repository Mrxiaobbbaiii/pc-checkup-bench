#Requires -Version 5.1
<#
检查项：net_tcp_stall —— TCP 连接停滞（层：wan；v1.2.0 片4；双采样防瞬时误报，同 pf_disk_saturation 先例）
命令：netstat.exe -n -p tcp 两次采样（间隔 3 秒，只读），数 SYN_SENT/SYN_RCVD（握手发不出去/回不来=连接停滞）
判定：两样本停滞连接数的较小值 ≥5 → FAIL（持续停滞=有软件在反复尝试连接且被挡：失效代理、防火墙/过滤层、
      安全软件联网控制）；较小值 <5 → PASS（单样本高=瞬时高峰附注）；netstat 不可用 → SKIP
mock 契约：每个样本 `SAMPLE | SYN_SENT | n | SYN_RCVD | m`，样本间 `===SAMPLE===`；须两个样本（不足=SKIP）；
      首行 QUERY-ERROR=SKIP
官方依据：netstat 参考（learn.microsoft.com windows-server administration windows-commands/netstat）；
      SYN_SENT=客户端发出连接请求等应答、SYN_RCVD=服务端收到请求等确认（TCP 状态机标准语义）。
阈值标注：≥5=警戒线（工程口径，正常桌面空闲时停滞连接应为 0-2）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$samples = @()
$queryError = $false

function Get-SampleStall([string]$Text) {
    $n = 0
    foreach ($ln in ($Text -split "`r?`n")) {
        if ($ln -match '(?i)\s(SYN_SENT|SYN_RCVD)\s') { $n++ }
    }
    return $n
}

if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：netstat 执行失败'
    } else {
        foreach ($chunk in ($MockRaw -split '===SAMPLE===')) {
            $ss = 0; $sr = 0
            foreach ($ln in ($chunk -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
                $p = $ln -split '\s*\|\s*'
                if ($p.Count -ge 5 -and $p[0].Trim().ToUpperInvariant() -eq 'SAMPLE') {
                    if ($p[1].Trim().ToUpperInvariant() -eq 'SYN_SENT') { [void][int]::TryParse($p[2].Trim(), [ref]$ss) }
                    elseif ($p[1].Trim().ToUpperInvariant() -eq 'SYN_RCVD') { [void][int]::TryParse($p[2].Trim(), [ref]$sr) }
                }
            }
            $samples += ($ss + $sr)
        }
    }
} else {
    try {
        $s1 = Get-SampleStall (& netstat.exe -n -p tcp 2>&1 | Out-String)
        Start-Sleep -Seconds 3
        $s2 = Get-SampleStall (& netstat.exe -n -p tcp 2>&1 | Out-String)
        $samples = @($s1, $s2)
    } catch {
        $queryError = $true
        $errText = "netstat 执行失败：$($_.Exception.Message)"
    }
}

$cmdTag = '[TCP 连接停滞（netstat 双采样，间隔 3 秒）]'
if ($queryError) {
    [PSCustomObject]@{
        name = 'net_tcp_stall'; status = 'SKIP'
        evidence = "$cmdTag`n查询失败（无法判定）：$errText——不是「没有停滞」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}
if ($samples.Count -lt 2) {
    [PSCustomObject]@{
        name = 'net_tcp_stall'; status = 'SKIP'
        evidence = "$cmdTag`n样本不足（须两次采样才敢下结论，防瞬时误报）——本项跳过"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'insufficient-samples' }
    } | ConvertTo-Json -Depth 5
    return
}

$s1 = [int]$samples[0]
$s2 = [int]$samples[1]
$min = [Math]::Min($s1, $s2)
$max = [Math]::Max($s1, $s2)

if ($min -ge 5) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n连接停滞持续：两次采样分别 $s1 / $s2 个连接卡在握手（SYN_SENT/SYN_RCVD）——有软件在反复尝试连接且一直被挡"
    $suggestion = "大量连接发不出去=「网页转圈/软件一直重连」的现场实锤。常见元凶按概率：①失效的系统代理（代理软件退了设置还在）——体检应用层会点名，配套动作一键清；②防火墙/安全软件的「联网控制」在拦；③网络过滤层堆太厚（驱动体检的「网络过滤层」有几层就危险几层）。按报告其他层的点名对照处理。`n【回滚】本检查只读，无副作用。"
} elseif ($max -ge 5) {
    $status = 'PASS'
    $evidence = "$cmdTag`n瞬时高峰：一次采样 $s1、另一次 $s2——只高了一下就回落，属瞬时现象不算停滞"
    $suggestion = ''
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n两次采样分别 $s1 / $s2 个停滞连接——正常（空闲桌面 0-2 个属常态）"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'net_tcp_stall'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ sample1 = $s1; sample2 = $s2; min = $min; max = $max }
} | ConvertTo-Json -Depth 6

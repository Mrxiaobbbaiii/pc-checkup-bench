#Requires -Version 5.1
<#
检查项：net_wlan_signal —— Wi-Fi 信号质量（层：link；v1.2.0 片4）
命令：netsh.exe wlan show interfaces（只读）
判定：无 WLAN 接口/服务没跑/未连接 → SKIP（台式机或没连 WiFi 是常态，不是故障）；
      信号 <40% → FAIL（弱信号：掉线/慢/搜不到网的链路层根因）；40-59% → PASS 附注「偏弱」；≥60% → PASS
mock 契约：`STATE | connected/none/disconnected` + `SIGNAL | 百分比数字`；首行 QUERY-ERROR=SKIP
官方依据：netsh wlan 参考（learn.microsoft.com windows-server networking netsh wlan）。
阈值标注：40/60=警戒线（微软无官方信号百分比谱，百分比为无线网卡驱动自报值）。
语言无关：状态按「已连接/connected」识别连接态，信号按「数字%」提取（信号/Signal 前缀两种都容）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$state = ''
$signal = -1
$queryError = $false

if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：wlan 状态读取失败'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            if ($p.Count -ge 2) {
                $k = $p[0].Trim().ToUpperInvariant()
                if ($k -eq 'STATE') { $state = $p[1].Trim().ToLowerInvariant() }
                elseif ($k -eq 'SIGNAL') { [void][int]::TryParse($p[1].Trim(), [ref]$signal) }
            }
        }
        if ($state -eq '') { $queryError = $true; $errText = '模拟：STATE 行缺失' }
    }
} else {
    try {
        $raw = (& netsh.exe wlan show interfaces 2>&1 | Out-String)
        if ($raw -match '(?i)没有运行无线接口|没有无线接口|no wireless interface|无线自动配置服务.*(没有运行|未运行)|not running') {
            $state = 'none'
        } elseif ($raw -match '(?i)已连接|connected') {
            $state = 'connected'
            if ($raw -match '(?i)(信号|Signal)\s*[:：]\s*(\d+)%') { $signal = [int]$Matches[2] }
            else { $queryError = $true; $errText = '已连接但读不到信号百分比（驱动未上报）' }
        } else {
            $state = 'disconnected'
        }
    } catch {
        $queryError = $true
        $errText = "netsh wlan 执行失败：$($_.Exception.Message)"
    }
}

$cmdTag = '[Wi-Fi 信号质量（netsh wlan show interfaces）]'
$skipOut = {
    param([string]$Why, [string]$Reason)
    [PSCustomObject]@{
        name = 'net_wlan_signal'; status = 'SKIP'
        evidence = "$cmdTag`n$Why——本项跳过（不是故障）"
        suggestion = ''; detail = [PSCustomObject]@{ reason = $Reason }
    } | ConvertTo-Json -Depth 5
}
if ($queryError) {
    [PSCustomObject]@{
        name = 'net_wlan_signal'; status = 'SKIP'
        evidence = "$cmdTag`n读取失败（无法判定）：$errText——不是「信号没问题」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}
if ($state -eq 'none') { & $skipOut '本机没有 WLAN 无线网卡（或无线服务未运行）' 'no-wlan'; return }
if ($state -eq 'disconnected') { & $skipOut 'WLAN 未连接 Wi-Fi（用网线或暂时不用无线）' 'wlan-down'; return }
if ($signal -lt 0) { & $skipOut '信号百分比读不到（驱动未上报）' 'no-signal'; return }

$ev = "当前 Wi-Fi 信号 $signal%（驱动自报值）"
if ($signal -lt 40) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n弱信号：$ev——低于 40% 警戒线，掉线/网慢/搜不到网的链路层根因常见于此"
    $suggestion = "信号弱是物理问题，软件修不了，但可以改善：①把电脑挪近路由器，或把路由器挪到房子中间、离地面高一点；②隔着承重墙/金属柜=信号杀手，换个方向；③双频路由器优先连 5G 频段（快且干扰少，但穿墙更弱——隔墙用 2.4G）；④天线松了拧紧。改完重跑体检看信号百分比涨没涨。`n【回滚】本检查只读，无副作用。"
} elseif ($signal -lt 60) {
    $status = 'PASS'
    $evidence = "$cmdTag`n$ev——偏弱（40-60% 警戒带）：能用，但隔墙/远距离时容易掉速掉线"
    $suggestion = ''
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n$ev——良好"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'net_wlan_signal'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ state = $state; signal = $signal }
} | ConvertTo-Json -Depth 6

#Requires -Version 5.1
<#
检查项：net_proxy_vpn —— 应用层：系统代理 / hosts / VPN 虚拟网卡（层：app）
命令：读 HKCU Internet Settings（ProxyEnable/ProxyServer/AutoConfigURL）+ hosts 文件 + Get-NetAdapter（只读）
判定：系统代理开启（含 PAC）或 hosts 有非默认条目 → FAIL；VPN/虚拟网卡只作提示（PASS 附注），本身不算故障；数据读不到 → SKIP
mock 契约：逐行前缀
  PROXY | 0/1 | 代理地址 | PAC地址
  HOSTS | 非默认条目数
  ADAPTER | 名称 | 描述 | 状态 | 是否虚拟(True/False)
空 mock=全干净；首行 QUERY-ERROR=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$proxyEnabled = $false
$proxyServer = ''
$pacUrl = ''
$hostsCount = 0
$hostLines = @()
$adapters = @()
$vpnNote = ''
$queryError = $false

if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：代理/hosts 读取失败'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            $kind = if ($p.Count -ge 1) { $p[0].Trim().ToUpperInvariant() } else { '' }
            if ($kind -eq 'PROXY') {
                $proxyEnabled = ($p.Count -ge 2 -and $p[1].Trim() -in @('1', 'true', 'True', 'yes'))
                if ($p.Count -ge 3) { $proxyServer = $p[2].Trim() }
                if ($p.Count -ge 4) { $pacUrl = $p[3].Trim() }
            } elseif ($kind -eq 'HOSTS') {
                $n = 0
                if ($p.Count -ge 2) { [void][int]::TryParse($p[1].Trim(), [ref]$n) }
                $hostsCount = $n
            } elseif ($kind -eq 'ADAPTER') {
                $adapters += [PSCustomObject]@{
                    name = if ($p.Count -ge 2) { $p[1].Trim() } else { '' }
                    desc = if ($p.Count -ge 3) { $p[2].Trim() } else { '' }
                    status = if ($p.Count -ge 4) { $p[3].Trim() } else { '' }
                    virtual = ($p.Count -ge 5 -and $p[4].Trim() -in @('1', 'true', 'True', 'yes'))
                }
            }
        }
    }
} else {
    try {
        $reg = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $proxyEnabled = ([int]$reg.ProxyEnable -eq 1)
        if ($null -ne $reg.ProxyServer) { $proxyServer = [string]$reg.ProxyServer }
        if ($null -ne $reg.AutoConfigURL) { $pacUrl = [string]$reg.AutoConfigURL }
    } catch {
        $queryError = $true
        $errText = "注册表 Internet Settings 读取失败：$($_.Exception.Message)"
    }

    if (-not $queryError) {
        $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        try {
            $rawHosts = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
            foreach ($hl in $rawHosts) {
                $t = $hl.Trim()
                if ($t -eq '' -or $t.StartsWith('#')) { continue }
                if ($t -match '^(?i)127\.0\.0\.1\s+localhost(\.localdomain)?\s*$') { continue }
                if ($t -match '^(?i)::1\s+localhost(\.localdomain)?\s*$') { continue }
                $hostsCount++
                if ($hostLines.Count -lt 3) { $hostLines += $t }
            }
        } catch {
            $queryError = $true
            $errText = "hosts 文件读取失败：$($_.Exception.Message)"
        }
    }

    if (-not $queryError) {
        try {
            foreach ($a in @(Get-NetAdapter -ErrorAction Stop)) {
                $adapters += [PSCustomObject]@{
                    name = [string]$a.Name
                    desc = [string]$a.InterfaceDescription
                    status = [string]$a.Status
                    virtual = [bool]$a.Virtual
                }
            }
        } catch {
            $vpnNote = '（Get-NetAdapter 不可用，虚拟网卡这一项没查到）'
        }
    }
}

$cmdTag = '[系统代理 / hosts / VPN 虚拟网卡]'
if ($queryError) {
    [PSCustomObject]@{
        name = 'net_proxy_vpn'; status = 'SKIP'
        evidence = "$cmdTag`n读取失败（无法判定）：$errText——不是「应用层没问题」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}

$isVpn = {
    param($a)
    if ($a.virtual) { return $true }
    return ($a.desc -match '(?i)vpn|tap|wireguard|openvpn|tailscale|zerotier|hyper-v|vmware|virtualbox|wsl')
}
$vpnUp = @($adapters | Where-Object { $_.status -match '^(?i)(Up|已启用|已连接)$' -and (& $isVpn $_) })
$vpnNames = @($vpnUp | ForEach-Object { $_.name }) -join '、'

$proxyOn = ($proxyEnabled -and $proxyServer -ne '') -or ($pacUrl -ne '')
$hostsOn = ($hostsCount -gt 0)
$evidenceLines = @()
if ($proxyOn) {
    $p = @()
    if ($proxyEnabled -and $proxyServer -ne '') { $p += "已启用（$proxyServer）" }
    if ($pacUrl -ne '') { $p += "PAC 自动配置（$pacUrl）" }
    $evidenceLines += ('系统代理：' + ($p -join '；'))
} else {
    $evidenceLines += '系统代理：未启用'
}
if ($hostsOn) {
    $evidenceLines += "hosts：$hostsCount 条非默认条目"
    foreach ($h in $hostLines) { $evidenceLines += "  $h" }
} else {
    $evidenceLines += 'hosts：无自定义条目'
}
if ($vpnUp.Count -gt 0) { $evidenceLines += "VPN/虚拟网卡：$($vpnUp.Count) 个已连接（$vpnNames）——只作提示，有它们不算故障" }
else { $evidenceLines += "VPN/虚拟网卡：未连接$vpnNote" }

if ($proxyOn -or $hostsOn) {
    $status = 'FAIL'
    $why = @()
    if ($proxyOn) { $why += '系统代理开着' }
    if ($hostsOn) { $why += "hosts 有 $hostsCount 条非默认记录" }
    $suggestion = "网络本身可能是通的，但应用层被$($why -join '、')挡着——网页打不开/时好时坏常见于此。`n【修复命令，请自己执行】关系统代理：设置→网络和 Internet→代理→关掉「使用代理服务器」；或只关 WinHTTP：netsh winhttp reset proxy。清 hosts：记事本打开 C:\Windows\System32\drivers\etc\hosts，给不认识的行使前面加 #（或删掉），保存需要管理员。`n【回滚】把代理地址/开关改回原值、删掉 # 注释即可恢复；本检查只读。"
} else {
    $status = 'PASS'
    $suggestion = ''
}
$evidence = "$cmdTag`n" + ($evidenceLines -join "`n")

[PSCustomObject]@{
    name = 'net_proxy_vpn'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{
        proxyEnabled = $proxyEnabled; proxyServer = $proxyServer; pacUrl = $pacUrl
        hostsCount = $hostsCount; hostLines = $hostLines
        vpnUp = @($vpnUp | ForEach-Object { $_.name })
    }
} | ConvertTo-Json -Depth 6

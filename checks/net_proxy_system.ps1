#Requires -Version 5.1
<#
检查项：net_proxy_system —— 系统级代理双通道（WinHTTP + WinINET）（层：app；v1.2.0 片4 优先项①）
命令：netsh winhttp show proxy（只读）+ Get-ItemProperty HKCU Internet Settings（只读）
判定：WinHTTP 配了代理（服务级——代理/加速软件退出后残留的最常见形态，浏览器代理关了也照样断网）
      或 WinINET 用户级代理/PAC 开着 → FAIL 附两通道证据；两路都直连 → PASS；任一读取失败或输出不认识 → SKIP
mock 契约：逐行前缀
  WINHTTP | DIRECT                或  WINHTTP | PROXY | 代理地址
  WININET | 0/1 | 代理地址 | PAC地址(可选)
首行 QUERY-ERROR=SKIP；空 mock=双通道全净
与 net_proxy_vpn 的分工（既有项零碰）：vpn 项=应用层综合体检（代理/hosts/VPN 一把抓，只探 WinINET）；
本项=系统级代理专查，多探 WinHTTP 服务级通道（netsh），两处证据互相印证。
语言无关：netsh 输出按「直接访问/Direct access」识别直连，否则按「代理服务器/Proxy Server(s)」行取地址；
两种都认不出（系统裁剪/未来格式变化）→ SKIP 不硬判。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$winhttpMode = ''      # direct | proxy | ''
$winhttpAddr = ''
$wininetOn = $false
$wininetServer = ''
$wininetPac = ''
$queryError = $false

if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：代理双通道读取失败'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            $kind = if ($p.Count -ge 1) { $p[0].Trim().ToUpperInvariant() } else { '' }
            if ($kind -eq 'WINHTTP') {
                $m = if ($p.Count -ge 2) { $p[1].Trim().ToUpperInvariant() } else { '' }
                if ($m -eq 'DIRECT') { $winhttpMode = 'direct' }
                elseif ($m -eq 'PROXY') { $winhttpMode = 'proxy'; if ($p.Count -ge 3) { $winhttpAddr = $p[2].Trim() } }
            } elseif ($kind -eq 'WININET') {
                $wininetOn = ($p.Count -ge 2 -and $p[1].Trim() -in @('1', 'true', 'True', 'yes'))
                if ($p.Count -ge 3) { $wininetServer = $p[2].Trim() }
                if ($p.Count -ge 4) { $wininetPac = $p[3].Trim() }
            }
        }
        if ($winhttpMode -eq '') { $queryError = $true; $errText = '模拟：WinHTTP 行缺失（双通道须成对给全）' }
    }
} else {
    try {
        $raw = (& netsh.exe winhttp show proxy 2>&1 | Out-String)
        if ($raw -match '(?i)直接访问|Direct access') {
            $winhttpMode = 'direct'
        } elseif ($raw -match '(?im)^\s*(代理服务器|Proxy Server\(s\))\s*[:：]\s*(.+)$') {
            $winhttpMode = 'proxy'
            $winhttpAddr = $Matches[2].Trim()
        } else {
            $queryError = $true
            $head = (@($raw -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -First 3) -join ' | '
            $errText = "netsh winhttp show proxy 输出不认识（不敢硬判）：$head"
        }
    } catch {
        $queryError = $true
        $errText = "netsh winhttp 执行失败：$($_.Exception.Message)"
    }
    if (-not $queryError) {
        try {
            $reg = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
            $wininetOn = ([int]$reg.ProxyEnable -eq 1)
            if ($null -ne $reg.ProxyServer) { $wininetServer = [string]$reg.ProxyServer }
            if ($null -ne $reg.AutoConfigURL) { $wininetPac = [string]$reg.AutoConfigURL }
        } catch {
            $queryError = $true
            $errText = "注册表 Internet Settings 读取失败：$($_.Exception.Message)"
        }
    }
}

$cmdTag = '[WinHTTP 服务级代理 + WinINET 用户级代理]'
if ($queryError) {
    [PSCustomObject]@{
        name = 'net_proxy_system'; status = 'SKIP'
        evidence = "$cmdTag`n读取失败（无法判定）：$errText——不是「代理干净」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}

$evLines = @()
if ($winhttpMode -eq 'direct') { $evLines += 'WinHTTP（服务级）：直接访问，无代理' }
else { $evLines += "WinHTTP（服务级）：被设为代理 $winhttpAddr——浏览器里的代理关了它也照样生效，系统更新/商店走这条路" }
$wi = @()
if ($wininetOn -and $wininetServer) { $wi += "已启用（$wininetServer）" }
if ($wininetPac) { $wi += "PAC 自动配置脚本（$wininetPac）" }
if ($wi.Count -gt 0) { $evLines += 'WinINET（用户级）：' + ($wi -join '；') }
else { $evLines += 'WinINET（用户级）：未启用' }

$winhttpBad = ($winhttpMode -eq 'proxy')
$wininetBad = ($wininetOn -and $wininetServer) -or ($wininetPac -ne '')
if ($winhttpBad -or $wininetBad) {
    $status = 'FAIL'
    $why = @()
    if ($winhttpBad) { $why += 'WinHTTP 服务级代理被设置' }
    if ($wininetBad) { $why += 'WinINET 用户级代理开着' }
    $fix = @()
    if ($winhttpBad) { $fix += '清服务级残留：管理员命令行执行【修复命令，请自己执行】netsh winhttp reset proxy（立即生效，不用重启）' }
    if ($wininetBad) { $fix += '关用户级代理：设置→网络和 Internet→代理→关掉「使用代理服务器」；有 PAC 脚本的一并关掉「使用设置脚本」' }
    $suggestion = "$($why -join '；')——网页打不开/时好时坏/只有个别软件连不上的常见元凶（代理软件退出后开关没还原）。`n$($fix -join '。')。`n【回滚】重置前原代理地址见上方证据：管理员命令行 netsh winhttp set proxy <原地址> 可设回；设置里的开关手动打开即恢复。本检查只读。"
} else {
    $status = 'PASS'
    $suggestion = ''
}
$evidence = "$cmdTag`n" + ($evLines -join "`n")

[PSCustomObject]@{
    name = 'net_proxy_system'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{
        winhttpMode = $winhttpMode; winhttpAddr = $winhttpAddr
        wininetOn = $wininetOn; wininetServer = $wininetServer; wininetPac = $wininetPac
    }
} | ConvertTo-Json -Depth 6

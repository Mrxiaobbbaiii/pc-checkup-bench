#Requires -Version 5.1
<#
检查项：net_dns_deadaddr —— DNS 死地址检测
层：DNS 层。命令：netsh interface ip show dns + 各活动网卡 netsh interface ip show config（只读）
判定：私有地址 DNS(10.x/172.16-31.x/192.168.x) 不属于任何活动网卡网段 = 死地址嫌疑 FAIL；
      公共 DNS（全局单播）不判死地址，可达性交给 nslookup 系列检查项。
mock 契约：段1=netsh interface ip show dns 全量；后续段=各活动网卡 show config（===PART=== 分隔）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$parts = @()
if ($MockRaw -ne '') {
    $parts = @($MockRaw -split '===PART===' | ForEach-Object { $_.Trim("`r`n") } | Where-Object { $_ -ne '' })
} else {
    $dnsRaw = (& netsh interface ip show dns 2>&1 | Out-String)
    $adapters = Get-ActiveAdapterNames ((& netsh interface show interface 2>&1 | Out-String))
    $parts = @($dnsRaw)
    foreach ($a in $adapters) { $parts += ((& netsh interface ip show config name="$a" 2>&1 | Out-String)) }
}

$dnsPart = $parts[0]
# 解析每网卡的 DNS 列表（含缩进续行）
$perAdapterDns = @{}
$curIf = '<unknown>'
foreach ($line in ($dnsPart -split "`r?`n")) {
    if ($line -match 'Configuration for interface\s+"(.+?)"') { $curIf = $Matches[1]; if (-not $perAdapterDns.ContainsKey($curIf)) { $perAdapterDns[$curIf] = @() } ; continue }
    if ($line -match 'DNS servers configured through DHCP:\s+(\d{1,3}(?:\.\d{1,3}){3})') { $perAdapterDns[$curIf] += $Matches[1]; continue }
    if ($line -match 'Statically Configured DNS Servers:\s+(\d{1,3}(?:\.\d{1,3}){3})') { $perAdapterDns[$curIf] += $Matches[1]; continue }
    if ($line -match '^\s+(\d{1,3}(?:\.\d{1,3}){3})\s*$') { $perAdapterDns[$curIf] += $Matches[1]; continue }
}

# 解析各活动网卡网段
$prefixes = @()
for ($i = 1; $i -lt $parts.Count; $i++) {
    $ip = ''; $mask = ''
    if ($parts[$i] -match 'IP Address:\s+(\d{1,3}(?:\.\d{1,3}){3})') { $ip = $Matches[1] }
    if ($parts[$i] -match 'mask\s+(\d{1,3}(?:\.\d{1,3}){3})\)') { $mask = $Matches[1] }
    if ($ip -and $mask) {
        $p = ConvertTo-NetworkPrefix $ip $mask
        if ($p) { $prefixes += $p }
    }
}

# 判定每个 DNS
$findings = @()
foreach ($kv in $perAdapterDns.GetEnumerator()) {
    foreach ($d in ($kv.Value | Select-Object -Unique)) {
        $cls = if (Test-PrivateIp $d) { 'private' } else { 'public' }
        $inSubnet = $false
        foreach ($p in $prefixes) { if (Test-IpInPrefix $d $p) { $inSubnet = $true; break } }
        $verdict = if ($cls -eq 'public') { 'ok-public' }
        elseif ($inSubnet) { 'ok-in-subnet' }
        else { 'DEAD-SUSPECT' }
        $findings += [PSCustomObject]@{ adapter = $kv.Key; dns = $d; class = $cls; inActiveSubnet = $inSubnet; verdict = $verdict }
    }
}

$dead = @($findings | Where-Object { $_.verdict -eq 'DEAD-SUSPECT' })
$status = if ($findings.Count -eq 0) { 'SKIP' } elseif ($dead.Count -ge 1) { 'FAIL' } else { 'PASS' }

$evidence = "[netsh interface ip show dns / show config]`n" +
    (($findings | ForEach-Object { "if=`"{0}`" dns={1} [{2}{3}] -> {4}" -f $_.adapter, $_.dns, $_.class, $(if ($_.class -eq 'private') { $(if ($_.inActiveSubnet) { '/in-subnet' } else { '/NOT-in-subnet' }) }), $_.verdict }) -join "`n") +
    "`nactive-subnets: " + ($prefixes -join ', ')

$suggestion = if ($status -eq 'FAIL') {
    $deadList = ($dead.dns | Select-Object -Unique) -join ' / '
    "发现死地址嫌疑 DNS：$deadList（私有地址但不属于任何活动网卡网段——大概率是旧路由器/旧网段的残留地址，指向它的解析会全部超时）。下面的命令把 DNS 改成阿里公共 DNS（223.5.5.5）。`n" +
    "【修复命令，请自己执行】netsh interface ip set dns `"<网卡名>`" static 223.5.5.5`n" +
    "【回滚】netsh interface ip set dns `"<网卡名>`" dhcp（若原来是 DHCP 自动获取）或 netsh interface ip set dns `"<网卡名>`" static <原DNS>"
} else { '' }

[PSCustomObject]@{
    name       = 'net_dns_deadaddr'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ findings = $findings; activeSubnets = $prefixes }
} | ConvertTo-Json -Depth 6

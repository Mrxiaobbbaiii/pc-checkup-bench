#Requires -Version 5.1
# diag 公共库：IP/网段判断（被各检查项 dot-source，无副作用）
# 本文件自身被直接运行时什么也不做。

function Test-PrivateIp {
    # RFC1918 私有地址：10.x / 172.16-31.x / 192.168.x
    param([string]$Ip)
    if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    $a = [int]$Matches[1]; $b = [int]$Matches[2]
    return ($a -eq 10) -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168)
}

function Test-ValidIpv4 {
    param([string]$Ip)
    if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($g in $Matches[1..4]) { if ([int]$g -gt 255) { return $false } }
    return $true
}

function ConvertTo-NetworkPrefix {
    # ip + 点分掩码 → 网络前缀字符串（如 10.32.76.0/24）；非法输入返回 ''
    param([string]$Ip, [string]$Mask)
    if (-not (Test-ValidIpv4 $Ip) -or -not (Test-ValidIpv4 $Mask)) { return '' }
    $ipB = $Ip.Split('.') | ForEach-Object { [int]$_ }
    $mB = $Mask.Split('.') | ForEach-Object { [int]$_ }
    $net = for ($i = 0; $i -lt 4; $i++) { $ipB[$i] -band $mB[$i] }
    $cidr = ($mB | ForEach-Object { ([convert]::ToString($_, 2) -replace '0', '').Length } | Measure-Object -Sum).Sum
    if ($cidr -eq 0) { return '' }
    return "$($net -join '.')/$cidr"
}

function Test-IpInPrefix {
    # ip 是否属于 192.168.1.0/24 形式的前缀（掩码非连续 1 也按位与处理）
    param([string]$Ip, [string]$Prefix)
    if ($Prefix -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') { return $false }
    $netStr = $Matches[1]; $cidr = [int]$Matches[2]
    if (-not (Test-ValidIpv4 $Ip) -or -not (Test-ValidIpv4 $netStr)) { return $false }
    if ($cidr -lt 0 -or $cidr -gt 32) { return $false }
    $maskInt = if ($cidr -eq 0) { 0 } else { ([uint32]::MaxValue) -shl (32 - $cidr) }
    $ipInt = Ipv4ToUint $Ip; $netInt = Ipv4ToUint $netStr
    return (($ipInt -band $maskInt) -eq ($netInt -band $maskInt))
}

function Ipv4ToUint {
    param([string]$Ip)
    $p = $Ip.Split('.') | ForEach-Object { [uint32]$_ }
    return ($p[0] -shl 24) -bor ($p[1] -shl 16) -bor ($p[2] -shl 8) -bor $p[3]
}

function Get-ActiveAdapterNames {
    # 从 netsh interface show interface 输出提取"已连接"网卡名（兼容中英文表头）
    param([string]$Raw)
    $names = @()
    foreach ($line in ($Raw -split "`r?`n")) {
        if ($line -match '^\s*(Enabled|已启用)\s+(Connected|已连接)\s+\S+\s+(.+?)\s*$') {
            $names += $Matches[3]
        }
    }
    return $names
}

function Get-NslookupVerdict {
    # nslookup 输出文本 -> @{ mode; ok; server; keyLine }
    # mode: ok / timeout / nxdomain / refused / server-error / unknown
    param([string]$Text)
    $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    $server = if ($Text -match '(?m)^\s*(?:Server|服务器):\s*(\S+)') { $Matches[1] } else { '' }
    $mode = 'unknown'
    foreach ($l in $lines) {
        if ($l -match 'timed out|请求超时') { $mode = 'timeout'; break }
        if ($l -match 'Non-existent domain|NXDOMAIN') { $mode = 'nxdomain'; break }
        if ($l -match 'Refused|refused|拒绝') { $mode = 'refused'; break }
        if ($l -match 'Server Failed|server can.t find|UnKnown.*\*\*') { $mode = 'server-error'; break }
    }
    if ($mode -eq 'unknown' -and $Text -match '(?m)^\s*Address(?:es)?:\s*\d{1,3}(?:\.\d{1,3}){3}') { $mode = 'ok' }
    $keyLine = ($lines | Where-Object { $_ -match 'timed out|超时|Non-existent|NXDOMAIN|Refused|refused|Failed|can.t find|Address' } | Select-Object -First 2) -join ' ; '
    return @{ mode = $mode; ok = ($mode -eq 'ok'); server = $server; keyLine = $keyLine }
}

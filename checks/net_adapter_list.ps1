#Requires -Version 5.1
<#
检查项：net_adapter_list —— 多网卡活动状态
层：链路层。命令：netsh interface show interface（只读）
判定：存在 >=1 张"已连接且已启用"网卡 = PASS；全部断开 = FAIL(链路层)
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$cmd = 'netsh interface show interface'
$raw = if ($MockRaw -ne '') { $MockRaw } else { (& netsh interface show interface 2>&1 | Out-String) }

$connected = Get-ActiveAdapterNames $raw
$disconnected = @()
foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '^\s*(Enabled|已启用)\s+(Disconnected|已断开连接|已断开)\s+\S+\s+(.+?)\s*$') { $disconnected += $Matches[3] }
}

if ($raw.Trim().Length -eq 0) {
    $status = 'SKIP'
} elseif ($connected.Count -ge 1) {
    $status = 'PASS'
} else {
    $status = 'FAIL'
}

$evidence = "[$cmd]`n" + (($raw -split "`r?`n" | Where-Object { $_ -match 'Connected|Disconnected|已连接|已断开' }) -join "`n")

$suggestion = if ($status -eq 'FAIL') {
    "没有任何一张网卡处于已连接状态：先查 WiFi 物理开关/飞行模式/网线两端是否插紧。`n" +
    "【修复命令，请自己执行】netsh interface set interface `"<网卡名>`" admin=enable`n" +
    "【回滚】netsh interface set interface `"<网卡名>`" admin=disable（恢复原管理状态）"
} else { '' }

[PSCustomObject]@{
    name       = 'net_adapter_list'
    status     = $status
    evidence   = $evidence.Trim()
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ connected = $connected; disconnected = $disconnected }
} | ConvertTo-Json -Depth 4

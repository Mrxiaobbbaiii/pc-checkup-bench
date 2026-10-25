#Requires -Version 5.1
<#
检查项：sec_firewall_profiles —— 防火墙三个配置文件（层：system_hardening）
命令：Get-NetFirewallProfile（只读）
判定（安全树规格 v1.6 第一节 6）：查询异常→SKIP(query-error)；
  Domain/Private/Public 任一 Enabled=False→FAIL（工程线：三 profile 覆盖全部网络场景，微软防火墙立场为应保持开启）；
  三开→PASS；其中 DefaultOutboundAction=Block→PASS 附注「出站默认拦截=罕见加固态」
出处：https://learn.microsoft.com/en-us/powershell/module/netsecurity/get-netfirewallprofile
mock 契约：逐行 `Name | Enabled | In | Out`（Domain/Private/Public 三行）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result { param($Status, $Evidence, $Suggestion, $Detail)
    [PSCustomObject]@{
        name = 'sec_firewall_profiles'; status = $Status; evidence = $Evidence; suggestion = $Suggestion; detail = $Detail
    } | ConvertTo-Json -Depth 5
}

$cmdTag = '[Get-NetFirewallProfile]'
$profCn = @{ Domain = '域网络'; Private = '专用网络'; Public = '公用网络' }
$profiles = @()

if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -lt 2) { continue }
        $inb = if ($p.Count -ge 3) { $p[2].Trim() } else { '' }
        $outb = if ($p.Count -ge 4) { $p[3].Trim() } else { '' }
        $profiles += [PSCustomObject]@{ name = $p[0].Trim(); enabled = ($p[1].Trim() -ieq 'True'); inbound = $inb; outbound = $outb }
    }
} else {
    try {
        foreach ($pf in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            $profiles += [PSCustomObject]@{
                name = [string]$pf.Name; enabled = [bool]$pf.Enabled
                inbound = [string]$pf.DefaultInboundAction; outbound = [string]$pf.DefaultOutboundAction
            }
        }
    } catch {
        Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：$($_.Exception.Message)" '' ([PSCustomObject]@{ reason = 'query-error' })
        return
    }
}
if ($profiles.Count -eq 0) {
    Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：未读取到任何防火墙配置文件" '' ([PSCustomObject]@{ reason = 'no-profiles' })
    return
}

$lines = @(foreach ($pf in $profiles) {
    $cnm = if ($profCn.ContainsKey($pf.name)) { $profCn[$pf.name] } else { $pf.name }
    $sw = if ($pf.enabled) { '开' } else { '关' }
    '{0}({1}): {2} | 入站默认 {3} | 出站默认 {4}' -f $cnm, $pf.name, $sw, $pf.inbound, $pf.outbound
})
$head = "$cmdTag`n" + ($lines -join "`n")
$detail = [PSCustomObject]@{ profiles = @($profiles | ForEach-Object { [PSCustomObject]@{ name = $_.name; enabled = $_.enabled; inbound = $_.inbound; outbound = $_.outbound } }) }

$dis = @($profiles | Where-Object { -not $_.enabled })
if ($dis.Count -gt 0) {
    $names = (@($dis | ForEach-Object { $_.name }) -join '、')
    $suggestion = "防火墙有配置文件被关（$($dis.Count) 个）——关的那个网络场景下，进站连接不设防。通常是装某些" + '"网络工具"' + "或游戏联机时被引导关闭的。`n【人工路径】Win+R → 输入 wf.msc 回车 → 左侧点「Windows Defender 防火墙属性」（概览页中间链接）→ 三个标签页（域配置文件/专用配置文件/公用配置文件）逐个看「防火墙状态」，被关的改成「启用」→ 点「确定」。`n【回滚】同一路径改回「关闭」即恢复（但建议保持启用）"
    Out-Result 'FAIL' "$head`n结论：有 $($dis.Count) 个防火墙配置文件被关闭（$names）——被关的网络场景下进站连接不设防" $suggestion $detail
    return
}
$block = @($profiles | Where-Object { $_.outbound -ieq 'Block' })
$tail = if ($block.Count -gt 0) { "`n出站默认拦截=罕见加固态，若有软件断网先查这里" } else { '' }
Out-Result 'PASS' ($head + $tail) '' $detail

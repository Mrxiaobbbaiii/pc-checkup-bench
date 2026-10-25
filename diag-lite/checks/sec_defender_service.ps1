#Requires -Version 5.1
<#
检查项：sec_defender_service —— Defender 防护服务状态（层：defender）
命令：Get-Service WinDefend, WdNisSvc, WdNisDrv, SecurityHealthService, wscsvc（只读）
判定（安全树规格 v1.6 第一节 4）：查询异常→SKIP(query-error)；WinDefend 不存在→SKIP(no-windefend，非 Defender 环境或第三方杀软接管)；
  WinDefend≠Running→FAIL（核心反恶意软件服务停摆）；WdNisSvc/WdNisDrv 存在但≠Running→FAIL（网络检测缺口，工程线）；
  仅 SecurityHealthService/wscsvc 非 Running→PASS 附注；全 Running→PASS
出处：https://learn.microsoft.com/en-us/powershell/microsoft.powershell.management/get-service
mock 契约：逐行 `Name | Status | StartType`；不存在服务注入 `WinDefend | MISSING |`（未列出的服务按 MISSING 处理）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result { param($Status, $Evidence, $Suggestion, $Detail)
    [PSCustomObject]@{
        name = 'sec_defender_service'; status = $Status; evidence = $Evidence; suggestion = $Suggestion; detail = $Detail
    } | ConvertTo-Json -Depth 5
}

$cmdTag = '[Get-Service WinDefend, WdNisSvc, WdNisDrv, SecurityHealthService, wscsvc]'
$svcDefs = @(
    @{ key = 'WinDefend'; cn = '反恶意软件服务' }
    @{ key = 'WdNisSvc'; cn = '网络检测服务' }
    @{ key = 'WdNisDrv'; cn = '网络检测驱动' }
    @{ key = 'SecurityHealthService'; cn = '安全中心服务' }
    @{ key = 'wscsvc'; cn = '安全基础服务' }
)
$st = @{}

if ($MockRaw -ne '' -or $MockFile -ne '') {
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $p = $ln -split '\s*\|\s*'
        if ($p.Count -lt 2) { continue }
        $stt = if ($p.Count -ge 3) { $p[2].Trim() } else { '' }
        $st[$p[0].Trim()] = @{ status = $p[1].Trim(); startType = $stt }
    }
} else {
    try {
        $got = @(Get-Service -Name 'WinDefend', 'WdNisSvc', 'WdNisDrv', 'SecurityHealthService', 'wscsvc' -ErrorAction SilentlyContinue)
    } catch {
        Out-Result 'SKIP' "$cmdTag`n查询失败（无法判定）：$($_.Exception.Message)" '' ([PSCustomObject]@{ reason = 'query-error' })
        return
    }
    foreach ($s in $got) {
        if ($null -eq $s) { continue }
        $startType = ''
        if ($s.PSObject.Properties['StartType']) { $startType = [string]$s.StartType }
        $st[$s.Name] = @{ status = [string]$s.Status; startType = $startType }
    }
}
foreach ($d in $svcDefs) { if (-not $st.ContainsKey($d.key)) { $st[$d.key] = @{ status = 'MISSING'; startType = '' } } }

function Svc-Line { param($d)
    '{0}({1}): {2}/{3}' -f $d.cn, $d.key, $st[$d.key].status, $st[$d.key].startType
}
$l1 = Svc-Line $svcDefs[0]
$l2 = (Svc-Line $svcDefs[1]) + ' | ' + (Svc-Line $svcDefs[2])
$l3 = (Svc-Line $svcDefs[3]) + ' | ' + (Svc-Line $svcDefs[4])
$head = "$cmdTag`n$l1`n$l2`n$l3"
$detail = [PSCustomObject]@{ services = @($svcDefs | ForEach-Object { [PSCustomObject]@{ name = $_.key; status = $st[$_.key].status; startType = $st[$_.key].startType } }) }

$suggestion = "Defender 防护服务没有在跑——杀毒引擎停着，等于大门无人值守。若你装了第三方杀软（360/火绒/卡巴等）属正常接管，结合报告里「防护开关」一项一起看：那项 PASS 就不用管本项。`n【人工路径】Win+R → 输入 services.msc 回车 → 找「Windows Defender 反恶意软件服务」（WinDefend）→ 右键「属性」→「启动类型」改「自动」→ 点「启动」→「确定」。`n【回滚】不适用（改回「手动」+「停止」即恢复，但 Defender 服务默认自动启动）"

if ($st['WinDefend'].status -eq 'MISSING') {
    Out-Result 'SKIP' "$head`n结论：WinDefend 服务不存在——非 Defender 环境或第三方杀软接管，本项不判定" '' ([PSCustomObject]@{ reason = 'no-windefend' })
    return
}
if ($st['WinDefend'].status -ne 'Running') {
    Out-Result 'FAIL' "$head`n结论：核心反恶意软件服务(WinDefend)停摆：$($st['WinDefend'].status)" $suggestion $detail
    return
}
$netBad = @()
foreach ($idx in @(1, 2)) {
    $d = $svcDefs[$idx]; $s = $st[$d.key].status
    if ($s -ne 'MISSING' -and $s -ne 'Running') { $netBad += ("{0}={1}" -f $d.key, $s) }
}
if ($netBad.Count -gt 0) {
    Out-Result 'FAIL' "$head`n结论：Defender 网络检测缺口（$($netBad -join '、')）——恶意流量少一道拦（多由第三方杀软卸载残留或驱动损坏造成）" $suggestion $detail
    return
}
$uiBad = @()
foreach ($idx in @(3, 4)) {
    $d = $svcDefs[$idx]
    if ($st[$d.key].status -ne 'Running') { $uiBad += $d.key }
}
$tail = if ($uiBad.Count -gt 0) { "`n安全中心界面服务未运行，Windows 安全中心可能打不开" } else { '' }
Out-Result 'PASS' ($head + $tail) '' $detail

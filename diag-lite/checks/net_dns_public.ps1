#Requires -Version 5.1
<#
检查项：net_dns_public —— 公共 DNS 直连测试（223.5.5.5 阿里 DNS）
层：DNS 层。命令：nslookup qq.com 223.5.5.5（只读）
判定：解析成功 = PASS（公网可达且公共 DNS 活着——是"换 DNS"修复路线可行的前提）；
      失败 = FAIL（公共 DNS 不可达：结合上层结果区分是公网断还是 DNS 端口被封）
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_lib.ps1')

$cmd = 'nslookup qq.com 223.5.5.5'
$raw = if ($MockRaw -ne '') { $MockRaw } else { $(
    # 5.1 下 nslookup 会把 "Non-authoritative answer:" 写 stderr；EAP=Stop + 2>&1 会把它当终止错误。
    # 仅在取原生输出期间放宽 EAP，取完立刻还原；判定逻辑与证据字段不变。
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        (& nslookup qq.com 223.5.5.5 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $oldEap
    }
) }

$v = Get-NslookupVerdict $raw
$status = if ($v.ok) { 'PASS' } elseif ($v.mode -eq 'unknown') { 'SKIP' } else { 'FAIL' }

$evidence = "[$cmd]`n" + $v.keyLine

$suggestion = if ($status -eq 'FAIL') {
    "公共 DNS 223.5.5.5 也解析不了：" + $(if ($v.mode -eq 'timeout') { "应答超时——若公网 ping 是通的，多半是 DNS 查询用的 UDP 53 端口被拦截或运营商问题。" } else { "失败模式=$($v.mode)。" }) + "`n" +
    "可再试备用公共 DNS：`n" +
    "【先试无风险的】nslookup qq.com 119.29.29.29（腾讯公共 DNS，验证是不是单点故障）`n" +
    "【修复命令，请自己执行】netsh interface ip set dns `"<网卡名>`" static 119.29.29.29（仅 223 这一家不通时换；两家都不通但网关通=联系运营商报修）`n" +
    "【回滚】netsh interface ip set dns `"<网卡名>`" dhcp（或 static <原DNS>）"
} else { '' }

[PSCustomObject]@{
    name       = 'net_dns_public'
    status     = $status
    evidence   = $evidence
    suggestion = $suggestion
    detail     = [PSCustomObject]@{ mode = $v.mode; server = $v.server }
} | ConvertTo-Json -Depth 4

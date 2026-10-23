#Requires -Version 5.1
<#
检查项：demo_ext_check —— 开机时长（ext 扩展示例，层：uptime）
命令：Get-CimInstance Win32_OperatingSystem（LastBootUpTime，只读）
判定：连续开机超过 30 天 → FAIL（建议重启）；30 天内 → PASS
mock 契约：单行数字 = 开机天数；空 = SKIP
这是 ext\checks 的示例文件：复制到 ext\checks\ 后，在 ext\trees\ 的某层 checks 里
写上 demo_ext_check 就会被跑。改成你自己的探测逻辑，保持只读、输出同样的 JSON。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Out-Result([string]$status, [string]$evidence, [string]$suggestion) {
    [PSCustomObject]@{
        name = 'demo_ext_check'; status = $status; evidence = $evidence; suggestion = $suggestion
        detail = [PSCustomObject]@{ reason = $status.ToLower() }
    } | ConvertTo-Json -Depth 5
}

$days = -1.0
try {
    if ($MockRaw -ne '' -or $MockFile -ne '') {
        if ($MockRaw.Trim() -eq '') { Out-Result 'SKIP' 'mock 内容为空（按契约跳过）' ''; return }
        $days = [double]($MockRaw.Trim() -split "`r?`n")[0].Trim()
    } else {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $days = [math]::Round(((Get-Date) - $boot).TotalDays, 1)
    }
} catch {
    Out-Result 'SKIP' "查不到开机时间：$($_.Exception.Message)" ''
    return
}
if ($days -lt 0) { Out-Result 'SKIP' '没有可用的开机时长数据' ''; return }

$ev = "连续开机 $days 天（来源：Win32_OperatingSystem.LastBootUpTime）"
if ($days -gt 30) {
    Out-Result 'FAIL' $ev '电脑很久没重启了。保存好手头文件，点「开始」→「电源」→「重启」；很多越用越卡的毛病重启就没了。'
} else {
    Out-Result 'PASS' $ev ''
}

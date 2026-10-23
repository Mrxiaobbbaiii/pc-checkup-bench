#Requires -Version 5.1
<#
检查项：pf_uptime —— 连续开机时长（层：boot；v1.2.0 片4）
命令：Get-CimInstance Win32_OperatingSystem（LastBootUpTime，只读）
判定：连续开机 >30 天 → FAIL（建议重启：内存碎片/泄漏的资源越积越多，很多「越用越卡」重启就好）；
      ≤30 天 → PASS 附天数；查询失败 → SKIP
mock 契约：单行数字=开机天数（支持小数）；空=SKIP
官方依据：Win32_OperatingSystem 官方类文档（learn.microsoft.com windows-win32 cimwin32prov）。
阈值标注：30 天=警戒线（工程口径；与 ext/示例 demo_ext_check 同源口径，2019 立项先例）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$days = -1.0
try {
    if ($MockRaw -ne '' -or $MockFile -ne '') {
        if ($MockRaw.Trim() -eq '') {
            [PSCustomObject]@{
                name = 'pf_uptime'; status = 'SKIP'
                evidence = '[连续开机时长（Win32_OperatingSystem.LastBootUpTime）]' + "`n" + '开机时长查不到（无可用数据）——本项跳过'
                suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data' }
            } | ConvertTo-Json -Depth 5
            return
        }
        $days = [double](($MockRaw.Trim() -split "`r?`n")[0].Trim())
    } else {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $days = [math]::Round(((Get-Date) - $boot).TotalDays, 1)
    }
} catch {
    [PSCustomObject]@{
        name = 'pf_uptime'; status = 'SKIP'
        evidence = "[连续开机时长（Win32_OperatingSystem.LastBootUpTime）]`n查不到开机时间：$($_.Exception.Message)——不是「刚重启过」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}

$ev = "连续开机 $days 天（来源：Win32_OperatingSystem.LastBootUpTime）"
if ($days -gt 30) {
    $status = 'FAIL'
    $evidence = "[连续开机时长（Win32_OperatingSystem.LastBootUpTime）]`n$ev——超过 30 天警戒线"
    $suggestion = "电脑很久没重启了：内存里的碎片和没释放的资源越积越多，「越用越卡/越来越怪」常见于此。保存好手头文件，点「开始」→「电源」→「重启」。很多小毛病重启就没了，重启后这个数清零。`n【回滚】重启不改任何设置和文件，无需回滚。"
} else {
    $status = 'PASS'
    $evidence = "[连续开机时长（Win32_OperatingSystem.LastBootUpTime）]`n$ev——30 天警戒线内"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'pf_uptime'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ days = $days }
} | ConvertTo-Json -Depth 6

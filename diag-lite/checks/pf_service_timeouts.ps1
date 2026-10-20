#Requires -Version 5.1
<#
检查项：pf_service_timeouts —— 服务启动失败/响应超时史（层：startup）
命令：Get-WinEvent System 日志 Provider=Service Control Manager 近 30 天 id=7000/7009/7011（7000=服务启动失败、7009=等待连接超时、7011=事务响应超时；官方默认超时=30000 毫秒，1020 校准勿写 15 秒；只读）
判定（design 十一节 4）：三类合计 ≥3→FAIL（附 top 服务名+各自条数）；1-2 条→PASS 附注；0 条→PASS；System 日志不可读→SKIP
mock 契约：逐行 `EventID | 服务名`（每行一条事件）；空=PASS（0 条）；首行 QUERY-ERROR=SKIP
语言无关：服务名=事件 Properties[0]（SCM 消息首参恒为服务名）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$events = @()
$queryError = $false
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        $queryError = $true
        $errText = '模拟：System 日志不可读'
    } else {
        foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
            $p = $ln -split '\s*\|\s*'
            if ($p.Count -ge 2) { $events += [PSCustomObject]@{ id = [int]$p[0].Trim(); service = $p[1].Trim() } }
        }
    }
} else {
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = @(7000, 7009, 7011); StartTime = (Get-Date).AddDays(-30) } -MaxEvents 300 -ErrorAction Stop)
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'No events|找不到') { $evts = @() } elseif ($m -match '权限|提升|unauthorized|not authorized') { $queryError = $true; $errText = "$m（System 日志该过滤需管理员权限读取——管理员身份运行可复核）" } else { $queryError = $true; $errText = $m }
    }
    if (-not $queryError) {
        foreach ($e in $evts) {
            # 服务名自适应提取：取首个非数字参数（1020 实拍：7000 的 P[0]=服务名；7009 的 P[0]=毫秒数、P[1]=服务名、P[2]=二进制尾巴——按参数位猜会错，自适应两语言皆准）
            $svc = ''
            foreach ($prop in @($e.Properties)) {
                $v = [string]$prop.Value
                if ($v -and $v -notmatch '^[\d\s]*$') { $svc = $v; break }
            }
            $events += [PSCustomObject]@{ id = $e.Id; service = $svc }
        }
    }
}

$cmdTag = '[System 服务控制管理器 7000/7009/7011 近30天]'
if ($queryError) {
    [PSCustomObject]@{
        name = 'pf_service_timeouts'; status = 'SKIP'
        evidence = "$cmdTag`nSystem 日志不可读（无法判定）：$errText——不是「服务健康」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
    return
}

# 聚合：服务名 → 各 ID 条数
$grouped = @($events | Group-Object -Property service | Sort-Object -Property Count -Descending)
$groupLines = ($grouped | Select-Object -First 5 | ForEach-Object {
    $ids = @($_.Group | Group-Object -Property id | ForEach-Object { '{0} ×{1}' -f $_.Name, $_.Count }) -join ' '
    '{1} {0}' -f $_.Name, $ids
}) -join "`n"

if ($events.Count -eq 0) {
    $status = 'PASS'
    $evidence = "$cmdTag`n0 条（近 30 天无服务启动失败/超时记录）"
    $suggestion = ''
} elseif ($events.Count -le 2) {
    $status = 'PASS'
    $evidence = "$cmdTag`n共 $($events.Count) 条（少量，未见系统性迟钝）`n$groupLines"
    $suggestion = ''
} else {
    $status = 'FAIL'
    $evidence = "$cmdTag`n共 $($events.Count) 条（7000=启动失败 7009=连接超时 7011=响应超时，官方默认超时=30000 毫秒）`n$groupLines"
    $suggestion = "近 30 天服务启动失败/响应超时共 $($events.Count) 条——服务层迟钝=开机慢+卡顿双证据。多为安全软件全家桶/驱动类服务。按上面点名的服务名去 设置→应用 卸载对应软件。`n【修复命令，请自己执行】无（按服务名卸载对应软件）`n【回滚】需要时重新安装该软件"
}

[PSCustomObject]@{
    name = 'pf_service_timeouts'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{ total = $events.Count; groups = $grouped | Select-Object -First 10 | ForEach-Object { @{ service = $_.Name; count = $_.Count; ids = @($_.Group | Group-Object -Property id | ForEach-Object { @{ id = [int]$_.Name; count = $_.Count } }) } } }
} | ConvertTo-Json -Depth 6

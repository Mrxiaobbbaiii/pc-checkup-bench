#Requires -Version 5.1
<#
检查项：dv_driver_load_failures —— 驱动加载失败史（层：suspect）
命令：Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-PnP'; Id=219; StartTime=(当日-30天)}（只读），取回后自滤 Level -in 2,3（Warning=2/Error=3，数字判定语言无关）
设备实例路径取法（三段降级，语言无关）：$evt.ToXml() 抓 <Data Name=…> 优先 DeviceInstancePath 类字段→Properties 里首个含 `\` 的字符串值（形如 USB\VID_…）→消息首行
判定：≥3 条→FAIL（按路径聚合 top5：同路径 ≥2 次标「反复」单独点名，单次路径合并「其余 N 条各 1 次」=语境护栏）；1-2 条→PASS 附注；0 条→PASS；日志不可读→SKIP
mock 契约：逐行=设备实例路径（每行一条 219 事件）；首行 QUERY-ERROR=SKIP；空=PASS（0 条）
「找不到与指定的选择条件匹配的事件」=0 条走 PASS 路径（同 pf 先例），真查询错误才 SKIP。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$paths = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        [PSCustomObject]@{
            name = 'dv_driver_load_failures'; status = 'SKIP'
            evidence = "[System Kernel-PnP id=219 近30天 Warning+]`nSystem 日志不可读（无法判定）：模拟：日志查询失败——不是「无加载失败」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    foreach ($ln in ($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })) {
        $paths += $ln.Trim()
    }
} else {
    $evts = @()
    $queryError = $false; $errText = ''
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-PnP'; Id = 219; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 500 -ErrorAction Stop)
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'No events|找不到') { $evts = @() } else { $queryError = $true; $errText = $m }
    }
    if ($queryError) {
        [PSCustomObject]@{
            name = 'dv_driver_load_failures'; status = 'SKIP'
            evidence = "[System Kernel-PnP id=219 近30天 Warning+]`nSystem 日志不可读（无法判定）：$errText——不是「无加载失败」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    $evts = @($evts | Where-Object { $_.Level -in 2, 3 })
    foreach ($e in $evts) {
        # 三段降级取设备实例路径（语言无关）
        $dep = $null
        try {
            $x = [xml]$e.ToXml()
            $datas = @($x.Event.EventData.Data)
            foreach ($d in $datas) {
                if ($d.Name -match 'DeviceInstance') { $dep = [string]$d.'#text'; break }
            }
            if (-not $dep) {
                foreach ($d in $datas) {
                    $v = [string]$d.'#text'
                    if ($v -like '*\*') { $dep = $v; break }
                }
            }
        } catch { $dep = $null }
        if (-not $dep) {
            foreach ($p in @($e.Properties)) {
                $v = [string]$p.Value
                if ($v -and $v -like '*\*') { $dep = $v; break }
            }
        }
        if (-not $dep) { $dep = (($e.Message -split "`r?`n") | Select-Object -First 1) }
        $paths += [string]$dep
    }
}

$cmdTag = '[System Kernel-PnP id=219 近30天 Warning+]'
$grouped = @($paths | Group-Object | Sort-Object Count -Descending)
$repeat = @($grouped | Where-Object { $_.Count -ge 2 })
$once = @($grouped | Where-Object { $_.Count -eq 1 })

if ($paths.Count -eq 0) {
    $status = 'PASS'
    $evidence = "$cmdTag`n0 条（近 30 天无驱动加载失败记录）"
    $suggestion = ''
} elseif ($paths.Count -le 2) {
    $status = 'PASS'
    $evidence = "$cmdTag`n共 $($paths.Count) 条（插拔设备瞬时场景常见，不冤枉）`n" + (($grouped | ForEach-Object { '{0} ×{1}' -f $_.Name, $_.Count }) -join "`n")
    $suggestion = ''
} else {
    $status = 'FAIL'
    $lines = @()
    foreach ($g in ($repeat | Select-Object -First 5)) {
        $lines += '{0} 加载失败 ×{1}（反复）' -f $g.Name, $g.Count
    }
    $repCount = @($repeat | Select-Object -First 5 | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    $restCount = $paths.Count - [int]$repCount
    if ($restCount -gt 0) { $lines += "其余 $restCount 条各 1 次（瞬时插拔类，不点名）" }
    $evidence = "$cmdTag 共 $($paths.Count) 条`n" + ($lines -join "`n")
    $suggestion = "近 30 天驱动加载失败共 $($paths.Count) 条$(if ($repeat.Count -ge 1) { "，其中「（反复）」标记的=$([string]::Join('、', @($repeat | Select-Object -First 5 | ForEach-Object { $_.Name }))) 同一设备反复失败" })=卸载残留或驱动文件损坏。反复项按设备实例路径定位所属软件（USB\…=USB 设备、ROOT\…=虚拟设备残留）。`n【修复命令，请自己执行】无（设备管理器→查看→显示隐藏的设备→卸载灰色残留项）`n【回滚】重新插拔设备或重装驱动即恢复枚举"
}

[PSCustomObject]@{
    name = 'dv_driver_load_failures'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{
        count = $paths.Count
        top = @($grouped | Select-Object -First 5 | ForEach-Object { [PSCustomObject]@{ path = $_.Name; times = $_.Count } })
    }
} | ConvertTo-Json -Depth 6

#Requires -Version 5.1
<#
检查项：dv_driver_age —— 古董驱动年代扫描（层：integrity）
命令：Get-CimInstance Win32_SystemDriver（State=Running，只读）→ PathName 清洗 → (Get-Item).LastWriteTime 作驱动年代代理（Win32_PnPSignedDriver.DriverDate 官方字段不用=拍板 12；文件出厂时间=稳定代理口径）
判定（design 十二节 2，施工单 v0.5 条目 2）：古董线=文件日期 < 2015-07-29（Win10 RTM 官方发布锚）；≥5→FAIL 附升序全清单；1-4→PASS 附注点名；0→PASS 附最早日期一行；枚举失败→SKIP。计数线 5=工程线
mock 契约：逐行 `驱动名 | CompanyName | 文件日期(yyyy-MM-dd) | 路径`；首行 QUERY-ERROR=SKIP；空=SKIP
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$ancientLine = [datetime]'2015-07-29'

# PathName 清洗（三形态，同 dv_driver_signature 内嵌逻辑各自复制不引外部文件）
function Convert-DriverPath {
    param([string]$Raw)
    if ($Raw -eq '') { return '' }
    $p = $Raw -replace '^\s*\\\?\?\\', ''
    if ($p -match '^[Ss]ystemRoot\\') { $p = $p -replace '^[Ss]ystemRoot\\', ($env:SystemRoot + '\') }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $env:SystemRoot $p }
    return $p
}

$skipOut = {
    param([string]$Why)
    [PSCustomObject]@{
        name = 'dv_driver_age'; status = 'SKIP'
        evidence = "[Win32_SystemDriver Running .sys LastWriteTime]`n$Why——不是「驱动都很新」，是查不到"
        suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
    } | ConvertTo-Json -Depth 5
}

$items = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') { & $skipOut '查询失败（无法判定）：模拟：驱动枚举不可读'; return }
    $lines = @($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { & $skipOut '无运行中驱动数据（查询无数据）'; return }
    foreach ($ln in $lines) {
        $f = $ln -split '\s*\|\s*', 4
        if ($f.Count -ge 3) {
            $dt = $null
            try { $dt = [datetime]::ParseExact($f[2].Trim(), 'yyyy-MM-dd', $null) } catch { $dt = $null }
            $items += [PSCustomObject]@{
                name = $f[0].Trim(); company = $f[1].Trim()
                date = $dt; path = $(if ($f.Count -gt 3) { $f[3].Trim() } else { '' })
            }
        }
    }
} else {
    try {
        $raw = @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop | Where-Object { [string]$_.State -ieq 'Running' })
    } catch {
        [PSCustomObject]@{
            name = 'dv_driver_age'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running .sys LastWriteTime]`n查询失败（无法判定）：$($_.Exception.Message)——不是「驱动都很新」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    if ($raw.Count -eq 0) { & $skipOut '无运行中驱动数据（查询无数据）'; return }
    foreach ($d in $raw) {
        $clean = Convert-DriverPath ([string]$d.PathName)
        $dt = $null; $co = ''
        if ($clean -ne '' -and (Test-Path -LiteralPath $clean)) {
            try {
                $fi = Get-Item -LiteralPath $clean -ErrorAction Stop
                $dt = $fi.LastWriteTime
                $co = [string]$fi.VersionInfo.CompanyName
            } catch { $dt = $null }
        }
        $items += [PSCustomObject]@{ name = [string]$d.Name; company = $co; date = $dt; path = $clean }
    }
}

# ---------- 文件级分析（未定位 .sys 不参与，附计数行） ----------
$located = @($items | Where-Object { $null -ne $_.date })
$unresolved = $items.Count - $located.Count
$old = @($located | Where-Object { $_.date -lt $ancientLine } | Sort-Object date)

$cmdTag = '[Win32_SystemDriver Running .sys LastWriteTime<2015-07-29]'
$unresLine = ''
if ($unresolved -gt 0) { $unresLine = "`n未定位 .sys $unresolved 个不参与（路径解析不到文件）" }

function Format-OldLine { param($It)
    '{0} {1} ({2})' -f $It.date.ToString('yyyy-MM-dd'), (Split-Path $It.path -Leaf), $(if ($It.company) { $It.company } else { '无厂商元数据' })
}

if ($old.Count -ge 5) {
    $status = 'FAIL'
    $list = ($old | ForEach-Object { Format-OldLine $_ }) -join "`n"
    $evidence = "$cmdTag`n共 $($old.Count) 个古董驱动在跑（扫描 $($items.Count) 个运行中驱动）:$unresLine`n$list"
    $suggestion = "$($old.Count) 个 Win10 发布（2015-07）之前的驱动还在 2026 年系统上跑=兼容性地雷（蓝屏高发源）。网卡/声卡类走厂商官网或 Windows Update→可选更新 拿新版驱动；点名清单按文件名搜所属软件定位设备。`n【修复命令，请自己执行】无（设备管理器→对应设备→更新驱动程序）`n【回滚】设备管理器→驱动程序→回退驱动程序（或重装原版）"
} elseif ($old.Count -ge 1) {
    $status = 'PASS'
    $list = ($old | ForEach-Object { Format-OldLine $_ }) -join "`n"
    $evidence = "$cmdTag`n$($old.Count) 个年代久远驱动点名（扫描 $($items.Count) 个运行中驱动，未达 5 个工程线）:$unresLine`n$list"
    $suggestion = ''
} else {
    $status = 'PASS'
    $earliest = ($located | Sort-Object date | Select-Object -First 1)
    $eLine = if ($earliest) { "最早文件日期 $($earliest.date.ToString('yyyy-MM-dd'))（无 2015-07-29 前的古董驱动）" } else { '无文件日期数据' }
    $evidence = "$cmdTag`n扫描 $($items.Count) 个运行中驱动，古董计数 0$unresLine`n$eLine"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'dv_driver_age'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{
        old = $old.Count; total = $items.Count; unresolved = $unresolved
        top = @($old | Select-Object -First 10 | ForEach-Object { [PSCustomObject]@{ file = Split-Path $_.path -Leaf; date = $_.date.ToString('yyyy-MM-dd'); company = $_.company } })
    }
} | ConvertTo-Json -Depth 6

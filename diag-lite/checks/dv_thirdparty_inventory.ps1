#Requires -Version 5.1
<#
检查项：dv_thirdparty_inventory —— 第三方驱动体量聚合（层：stack）
命令：Get-CimInstance Win32_SystemDriver（State=Running，只读）→ PathName 清洗 → VersionInfo.CompanyName 聚合（只读元数据不验签=快；与 dv_driver_signature 不做缓存共享=小拍板①）
判定（design 十二节 3，施工单 v0.5 条目 3）：非微软总数（含无厂商元数据桶）>30→FAIL 附聚合表；15-30→PASS 附注「偏厚」；≤15→PASS 附聚合表（微软桶一行）；枚举失败→SKIP。30/15=工程线
mock 契约：逐行 `驱动名 | CompanyName | 路径`（路径列可空）；首行 QUERY-ERROR=SKIP；空=SKIP
注：CompanyName 为空或读取失败→「无厂商元数据」桶（非微软）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

# PathName 清洗（三形态，同 dv_driver_signature 内嵌逻辑各自复制不引外部文件）
function Convert-DriverPath {
    param([string]$Raw)
    if ($Raw -eq '') { return '' }
    $p = $Raw -replace '^\s*\\\?\?\\', ''
    if ($p -match '^[Ss]ystemRoot\\') { $p = $p -replace '^[Ss]ystemRoot\\', ($env:SystemRoot + '\') }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $env:SystemRoot $p }
    return $p
}

$rows = @()
if ($MockRaw -ne '' -or $MockFile -ne '') {
    if ($MockRaw.Trim() -eq 'QUERY-ERROR') {
        [PSCustomObject]@{
            name = 'dv_thirdparty_inventory'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running]`n查询失败（无法判定）：模拟：驱动枚举不可读——不是「第三方驱动不多」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    $lines = @($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) {
        [PSCustomObject]@{
            name = 'dv_thirdparty_inventory'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running]`n无运行中驱动数据（查询无数据）——不是「第三方驱动不多」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data' }
        } | ConvertTo-Json -Depth 5
        return
    }
    foreach ($ln in $lines) {
        $f = $ln -split '\s*\|\s*', 3
        if ($f.Count -ge 2) {
            $rows += [PSCustomObject]@{ name = $f[0].Trim(); company = $f[1].Trim(); path = $(if ($f.Count -gt 2) { $f[2].Trim() } else { '' }) }
        }
    }
} else {
    try {
        $raw = @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop | Where-Object { [string]$_.State -ieq 'Running' })
    } catch {
        [PSCustomObject]@{
            name = 'dv_thirdparty_inventory'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running]`n查询失败（无法判定）：$($_.Exception.Message)——不是「第三方驱动不多」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    if ($raw.Count -eq 0) {
        [PSCustomObject]@{
            name = 'dv_thirdparty_inventory'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running]`n无运行中驱动数据（查询无数据）——不是「第三方驱动不多」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data' }
        } | ConvertTo-Json -Depth 5
        return
    }
    foreach ($d in $raw) {
        $clean = Convert-DriverPath ([string]$d.PathName)
        $co = ''
        if ($clean -ne '' -and (Test-Path -LiteralPath $clean)) {
            try { $co = [string](Get-Item -LiteralPath $clean -ErrorAction Stop).VersionInfo.CompanyName } catch { $co = '' }
        }
        $rows += [PSCustomObject]@{ name = [string]$d.Name; company = $co; path = $clean }
    }
}

# ---------- 聚合：微软桶 / 无厂商元数据桶 / 其余按公司计数（大小写不敏感归一，显示用首见拼写） ----------
$msCount = 0
$noMeta = 0
$companies = @{}
foreach ($r in $rows) {
    if ($r.company -like '*Microsoft*') { $msCount++; continue }
    if ($r.company -eq '') { $noMeta++; continue }
    $kl = $r.company.ToLower()
    if (-not $companies.ContainsKey($kl)) { $companies[$kl] = @{ n = $r.company; c = 0 } }
    $companies[$kl].c++
}
$thirdParty = $rows.Count - $msCount

$cmdTag = '[Win32_SystemDriver Running→VersionInfo.CompanyName 聚合]'
$coLines = ($companies.GetEnumerator() | Sort-Object { -$_.Value.c } | ForEach-Object { '{0} ×{1}' -f $_.Value.n, $_.Value.c })
if ($noMeta -gt 0) { $coLines += @('无厂商元数据 ×' + $noMeta) }
$coTable = $coLines -join "`n"
$msLine = "微软自带 $msCount 个"

if ($thirdParty -gt 30) {
    $status = 'FAIL'
    $evidence = "$cmdTag`n非微软在跑驱动 $thirdParty 个（共 $($rows.Count) 个运行中，$msLine）`n$coTable"
    $suggestion = "第三方驱动体量 $thirdParty 个，超过 30 个工程线——全家桶/加速器/卸载残留的虚拟设备一层层叠出来的，驱动越多冲突面越大（断网/卡顿/蓝屏隐患）。按公司名对号：认识且在用的留着，卸载残留/早就不用的软件去 设置→应用 卸载对应全家桶。`n【修复命令，请自己执行】无（设置→应用 对照卸载）`n【回滚】需要时重新安装该软件"
} elseif ($thirdParty -ge 15) {
    $status = 'PASS'
    $evidence = "$cmdTag`n非微软在跑驱动 $thirdParty 个（$msLine）——偏厚，卸载软件时对照`n$coTable"
    $suggestion = ''
} else {
    $status = 'PASS'
    $evidence = "$cmdTag`n非微软在跑驱动 $thirdParty 个，$msLine`n$coTable"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'dv_thirdparty_inventory'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{
        thirdParty = $thirdParty; microsoft = $msCount; noMeta = $noMeta
        companies = @($companies.GetEnumerator() | Sort-Object { -$_.Value.c } | ForEach-Object { [PSCustomObject]@{ name = $_.Value.n; count = $_.Value.c } })
    }
} | ConvertTo-Json -Depth 6

#Requires -Version 5.1
<#
检查项：dv_driver_signature —— 在跑驱动签名验证（层：integrity）
命令：Get-CimInstance Win32_SystemDriver（State=Running，只读）→ PathName 清洗 → CompanyName 分桶（微软桶跳过验签=性能护栏）→ 非微软子集逐个 Get-AuthenticodeSignature -FilePath（两段式）
判定（design 十二节 1，施工单 v0.5 条目 1）：待验桶 NotSigned/HashMismatch/UnknownError ≥1→FAIL；非微软全 Valid→PASS 附公司聚合；其余非常规状态（NotSupported 等）→PASS 走主判定+evidence 追加登记行（真机实拍见→HANDOFF 登记，不扩判）；枚举失败→SKIP
边界声明（进知识来源.md）：CompanyName 文件元数据≠Authenticode 法律签名，FAIL 只由验签结果定；Get-AuthenticodeSignature 只认内嵌签名，目录签名(catalog)报 NotSigned=已知边界——真机见正规厂商 NotSigned→登记 HANDOFF 待拍板，禁当场改判定
mock 契约：逐行 `驱动名 | CompanyName | SigStatus | 路径`（SigStatus=Valid/NotSigned/HashMismatch/UnknownError/NotSupported，mock 直接信任不真验签）；首行 QUERY-ERROR=SKIP；空=SKIP
注：Win32_SystemDriver 的 State 恒英文；Get-AuthenticodeSignature 的 Status 枚举值恒英文（语言无关）。
#>
param([string]$MockRaw = '', [string]$MockFile = '')
if ($MockFile -ne '' -and $MockRaw -eq '') { $MockRaw = Get-Content -LiteralPath $MockFile -Raw -Encoding UTF8 }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$badSigs = @('NotSigned', 'HashMismatch', 'UnknownError')
$unusualSigs = @('NotSupported', 'CatalogProblem', 'CallerProblem', 'CertExpired', 'FormatError', 'NoSignature', 'SystemDefault', 'WrongSubject', 'PathNotFound', 'Other')

# PathName 清洗（三形态，同 dv_driver_age/dv_thirdparty_inventory 各自内嵌不引外部文件）：
# ①strip `\??\` 前缀；②SystemRoot\ 前缀→$env:SystemRoot\；③仍非 rooted→Join-Path $env:SystemRoot 补全；④Test-Path 不过→未定位不参与文件级分析
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
            name = 'dv_driver_signature'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running]`n查询失败（无法判定）：模拟：驱动枚举不可读——不是「驱动全有签名」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    $lines = @($MockRaw -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) {
        [PSCustomObject]@{
            name = 'dv_driver_signature'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running]`n无运行中驱动数据（查询无数据）——不是「驱动全有签名」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'no-data' }
        } | ConvertTo-Json -Depth 5
        return
    }
    foreach ($ln in $lines) {
        $f = $ln -split '\s*\|\s*', 4
        if ($f.Count -ge 2) {
            $rows += [PSCustomObject]@{
                name = $f[0].Trim(); company = $f[1].Trim()
                sig = $f[2].Trim(); path = $(if ($f.Count -gt 3) { $f[3].Trim() } else { '' })
            }
        }
    }
} else {
    try {
        $raw = @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction Stop | Where-Object { [string]$_.State -ieq 'Running' })
    } catch {
        [PSCustomObject]@{
            name = 'dv_driver_signature'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running]`n查询失败（无法判定）：$($_.Exception.Message)——不是「驱动全有签名」，是查不到"
            suggestion = ''; detail = [PSCustomObject]@{ reason = 'query-error' }
        } | ConvertTo-Json -Depth 5
        return
    }
    if ($raw.Count -eq 0) {
        [PSCustomObject]@{
            name = 'dv_driver_signature'; status = 'SKIP'
            evidence = "[Win32_SystemDriver Running]`n无运行中驱动数据（查询无数据）——不是「驱动全有签名」，是查不到"
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
        $rows += [PSCustomObject]@{ name = [string]$d.Name; company = $co; sig = ''; path = $clean }
    }
}

# ---------- 分桶：微软桶跳过验签（性能护栏），非微软=待验桶 ----------
$msCount = 0
$pending = @()
$unresolved = 0
foreach ($r in $rows) {
    if ($r.company -like '*Microsoft*') { $msCount++; continue }
    if (-not $MockRaw -and -not $MockFile) {
        # 真实模式：未定位文件无法验签→登记不参与（清洗④）
        if ($r.path -eq '' -or -not (Test-Path -LiteralPath $r.path)) { $unresolved++; continue }
    }
    $pending += $r
}

# ---------- 非微软子集验签（mock 模式直接信任 SigStatus 列） ----------
$bad = @()
$valid = 0
$unusual = @()
$otherStatus = @()
foreach ($r in $pending) {
    $st = $r.sig
    if (-not ($MockRaw -or $MockFile)) {
        try { $st = [string](Get-AuthenticodeSignature -FilePath $r.path -ErrorAction Stop).Status } catch { $st = 'UnknownError' }
    }
    if ($badSigs -contains $st) {
        $bad += [PSCustomObject]@{ file = Split-Path $r.path -Leaf; dir = $(Split-Path $r.path -Parent); sig = $st }
    } elseif ($st -eq 'Valid') {
        $valid++
    } elseif ($unusualSigs -contains $st) {
        $unusual += [PSCustomObject]@{ file = Split-Path $r.path -Leaf; sig = $st }
    } else {
        $otherStatus += [PSCustomObject]@{ file = Split-Path $r.path -Leaf; sig = $st }
    }
}

$cmdTag = '[Win32_SystemDriver Running→非微软子集 Get-AuthenticodeSignature]'
$statLine = "共验 $($pending.Count) 个非微软在跑驱动，$valid 个 Valid"
$extra = ''
if ($msCount -gt 0) { $extra += "`n微软自带 $msCount 个（跳过验签=性能护栏，必过）" }
if ($unresolved -gt 0) { $extra += "`n未定位 .sys $unresolved 个不参与验签（路径解析不到文件）" }
if ($otherStatus.Count -gt 0) { $extra += "`n非常规验签状态 $($otherStatus.Count) 个: " + (($otherStatus | ForEach-Object { '{0} ({1})' -f $_.file, $_.sig }) -join '、') }

if ($bad.Count -ge 1) {
    $status = 'FAIL'
    $badLines = ($bad | ForEach-Object { '{0}: {1} ({2})' -f $_.sig, $_.file, $_.dir }) -join "`n"
    $evidence = "$cmdTag`n$statLine$extra`n$badLines"
    $suggestion = "有 $($bad.Count) 个来路不明的驱动正在内核运行（未签名/签名损坏）=蓝屏高发源。按点名文件名搜所属软件，去 设置→应用 卸载对应软件（已知对照：nnndisfilter.sys=给梨加速器捆绑驱动，公开收录的蓝屏嫌疑驱动；目录签名类正规厂商驱动被判 NotSigned 属已知边界）。`n【修复命令，请自己执行】无（设置→应用 卸载对应软件）`n【回滚】需要时重新安装该软件"
} elseif ($unusual.Count -ge 1) {
    $status = 'PASS'
    $unLines = ($unusual | ForEach-Object { '{0} ({1})' -f $_.file, $_.sig }) -join '、'
    $evidence = "$cmdTag`n$statLine$extra`n非常规验签状态 $($unusual.Count) 个: $unLines（不判 FAIL 走登记制：NotSupported 等=系统未给出常规结论，非验签失败）"
    $suggestion = ''
} else {
    $status = 'PASS'
    $grp = @{}
    foreach ($r in $pending) {
        $k = if ($r.company -ne '') { $r.company } else { '无厂商元数据' }
        $kl = $k.ToLower()
        if (-not $grp.ContainsKey($kl)) { $grp[$kl] = @{ n = $k; c = 0 } }
        $grp[$kl].c++
    }
    $coLines = ($grp.GetEnumerator() | Sort-Object { -$_.Value.c } | ForEach-Object { '{0} ×{1}' -f $_.Value.n, $_.Value.c }) -join '，'
    $evidence = "$cmdTag`n$statLine$extra`n$coLines"
    $suggestion = ''
}

[PSCustomObject]@{
    name = 'dv_driver_signature'; status = $status; evidence = $evidence; suggestion = $suggestion
    detail = [PSCustomObject]@{
        running = $rows.Count; verified = $pending.Count; valid = $valid
        bad = $bad; unusual = $unusual; unresolved = $unresolved; microsoft = $msCount
    }
} | ConvertTo-Json -Depth 6

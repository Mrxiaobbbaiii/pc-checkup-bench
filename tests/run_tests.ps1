#Requires -Version 5.1
<#
diag 模拟故障测试 runner（铁律 3）
用法：pwsh -NoProfile -File tests/run_tests.ps1
覆盖：① 每检查项 -MockRaw 注入模拟故障（正例+负例+证据/建议关键词断言；支持注入损坏 JSON 验证 SKIP 路径）
      ② 全树场景（engine 断点链：网络树 3 场景 + v0.2 蓝屏树 2 场景，场景可带 tree/full 参数）
断言附加铁律：FAIL 必附非空 suggestion（修复建议命令文本+回滚）。
退出码 0=全绿。
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$diagPs = (Get-Process -Id $PID).Path
. (Join-Path $PSScriptRoot 'cases.ps1')
. (Join-Path $PSScriptRoot 'scenarios.ps1')
. (Join-Path $PSScriptRoot 'cases_b.ps1')
. (Join-Path $PSScriptRoot 'cases_repair.ps1')
. (Join-Path $PSScriptRoot 'cases_ext.ps1')
. (Join-Path $PSScriptRoot 'cases_dataroot.ps1')
. (Join-Path $PSScriptRoot 'cases_i18n.ps1')

$results = @()

function Add-Result { param($Cat, $Name, $Note, $Ok, $Why = '')
    $script:results += [PSCustomObject]@{ cat = $Cat; name = $Name; note = $Note; ok = [bool]$Ok; why = $Why }
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} :: {2} {3}" -f $mark, $Name, $Note, $(if (-not $Ok) { "-- $Why" } else { '' }))
}

# ---------- ① 单检查项用例 ----------
$global:DiagCaseIdx = 1
foreach ($case in $global:DiagCases) {
    $scriptFile = Join-Path $root ("checks/" + $case.check + ".ps1")
    $mockTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-mock-unit-$PID-" + $global:DiagCaseIdx + '.txt')
    Set-Content -Path $mockTmp -Value $case.mock -Encoding UTF8
    # 可选：注入损坏的码书/名单 JSON，验证检查项 SKIP 路径
    $exArgs = @(); $tmpJsons = @()
    if ($case.mockCodesJson) {
        $cj = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-mock-codes-$PID-" + $global:DiagCaseIdx + '.json')
        Set-Content -Path $cj -Value $case.mockCodesJson -Encoding UTF8
        $exArgs += @('-CodesFile', $cj); $tmpJsons += $cj
    }
    if ($case.mockSuspectsJson) {
        $sj = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-mock-suspects-$PID-" + $global:DiagCaseIdx + '.json')
        Set-Content -Path $sj -Value $case.mockSuspectsJson -Encoding UTF8
        $exArgs += @('-SuspectsFile', $sj); $tmpJsons += $sj
    }
    $global:DiagCaseIdx++
    $job = Start-Job -ScriptBlock {
        param($ps, $s, $mf, $ex)
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $a = @()
        if ($mf) { $a += @('-MockFile', $mf) }
        if ($ex) { $a += $ex }
        & $ps -NoProfile -ExecutionPolicy Bypass -File $s @a 2>&1 | Out-String
    } -ArgumentList $diagPs, $scriptFile, $mockTmp, $exArgs
    if (-not (Wait-Job $job -Timeout 60)) { Stop-Job $job -Force; $outText = '' }
    else { $outText = (Receive-Job $job) | Out-String }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item $mockTmp -Force -ErrorAction SilentlyContinue
    foreach ($tj in $tmpJsons) { Remove-Item $tj -Force -ErrorAction SilentlyContinue }
    try {
        $j = $outText | ConvertFrom-Json
    } catch {
        Add-Result 'unit' $case.check $case.note $false ("output unparsable: " + (($outText -split "`r?`n") | Select-Object -First 2))
        continue
    }
    if ($j.status -ne $case.expectStatus) {
        Add-Result 'unit' $case.check $case.note $false ("expect $($case.expectStatus) got $($j.status)")
        continue
    }
    if ($case.expectEvidenceKeyword -and ($j.evidence -notmatch [regex]::Escape($case.expectEvidenceKeyword))) {
        Add-Result 'unit' $case.check $case.note $false ("evidence missing keyword: $($case.expectEvidenceKeyword)")
        continue
    }
    if ($case.expectSuggestionKeyword -and ($j.suggestion -notmatch [regex]::Escape($case.expectSuggestionKeyword))) {
        Add-Result 'unit' $case.check $case.note $false ("suggestion missing keyword: $($case.expectSuggestionKeyword)")
        continue
    }
    if ($j.status -eq 'FAIL' -and [string]::IsNullOrWhiteSpace($j.suggestion)) {
        Add-Result 'unit' $case.check $case.note $false 'FAIL without suggestion (rule: fix text mandatory)'
        continue
    }
    Add-Result 'unit' $case.check $case.note $true
}

# ---------- ② 全树场景（engine 断点链） ----------
foreach ($scen in $global:DiagScenarios) {
    $mockDir = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-scen-" + $scen.name + "-" + $PID)
    New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
    foreach ($kv in $scen.mocks.GetEnumerator()) {
        Set-Content -Path (Join-Path $mockDir ($kv.Key + '.txt')) -Value $kv.Value -Encoding UTF8
    }
    $engineOut = ''
    $exitCode = -1
    $treeArgs = @(); if ($scen.tree) { $treeArgs = @('-TreeName', $scen.tree) }
    $fullArgs = @(); if ($scen.full) { $fullArgs = @('-Full') }
    try {
        $engineOut = (& $diagPs -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'engine/run.ps1') @treeArgs @fullArgs -MockDir $mockDir -NoSaveReport 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } catch {
        Add-Result 'scenario' $scen.name '' $false ("engine crashed: $($_.Exception.Message)")
        continue
    } finally {
        Remove-Item $mockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $bad = @()
    if ($exitCode -ne $scen.expectExit) { $bad += "exitcode expect $($scen.expectExit) got $exitCode" }
    foreach ($kw in $scen.keywords) {
        if ($engineOut -notmatch [regex]::Escape($kw)) { $bad += "report missing keyword: $kw" }
    }
    if ($bad.Count -gt 0) { Add-Result 'scenario' $scen.name '' $false ($bad -join '; ') }
    else { Add-Result 'scenario' $scen.name '' $true }
}

# ---------- ③ 输出层用例（-ProgressFile/-JsonReport；临时仓跑 engine，主仓 reports 零污染） ----------
foreach ($bc in $global:DiagBCases) {
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-b-" + $bc.name + "-" + $PID)
    if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'reports') -Force | Out-Null
    Copy-Item -Recurse -Force (Join-Path $root 'engine') (Join-Path $tmpRoot 'engine')
    Copy-Item -Recurse -Force (Join-Path $root 'checks') (Join-Path $tmpRoot 'checks')
    Copy-Item -Recurse -Force (Join-Path $root 'trees') (Join-Path $tmpRoot 'trees')
    $mockDir = Join-Path $tmpRoot 'mocks'
    New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
    foreach ($kv in $bc.mocks.GetEnumerator()) {
        Set-Content -Path (Join-Path $mockDir ($kv.Key + '.txt')) -Value $kv.Value -Encoding UTF8
    }
    $progFile = Join-Path $tmpRoot 'progress.jsonl'
    $engineArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tmpRoot 'engine/run.ps1'), '-TreeName', $bc.tree, '-MockDir', $mockDir, '-NoMenu')
    if ($bc.json) { $engineArgs += '-JsonReport' }
    if ($bc.full) { $engineArgs += '-Full' }
    $engineArgs += @('-ProgressFile', $progFile)
    $engineOut = ''
    $exitCode = -1
    try {
        # 用例 5（默认关）不带 -ProgressFile/-JsonReport：重跑一次无两参数版本
        if ($bc.name -eq 'b_default_off') {
            $engineArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tmpRoot 'engine/run.ps1'), '-TreeName', $bc.tree, '-MockDir', $mockDir, '-NoMenu', '-Full')
        }
        $engineOut = (& $diagPs @engineArgs 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } catch {
        Add-Result 'engine-b' $bc.name '' $false ("engine crashed: $($_.Exception.Message)")
        continue
    } finally {
        # 断言跑完再清临时仓
    }
    $bad = @()
    if ($exitCode -ne $bc.expectExit) { $bad += "exitcode expect $($bc.expectExit) got $exitCode" }
    $ctx = [PSCustomObject]@{ Root = $tmpRoot; Out = $engineOut; Prog = $progFile }
    $vbad = & $bc.verify $ctx
    if ($vbad) { $bad += @($vbad) }
    if ($bad.Count -gt 0) { Add-Result 'engine-b' $bc.name '' $false ($bad -join '; ') }
    else { Add-Result 'engine-b' $bc.name '' $true }
    Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- ④ 修复动作用例（v0.8.1：四断言+每绿级动作实测；临时仓跑 repair.ps1，主仓 reports/ 零污染） ----------
$silentElev = Test-SilentElevatable
# 已提权宿主（CI/管理员壳）：repair.ps1 对已提权进程预检不构成阻断，skipOnElevated 用例断言前提失效 → 转 SKIP（1025 拍板）
$curElevated = Test-CurElevated
foreach ($rc in $global:DiagRepairCases) {
    if ($curElevated -and $rc.skipOnElevated) {
        Add-Result 'repair' $rc.name 'SKIP: 已提权宿主，真动作用例不真跑' $true
        continue
    }
    if ($rc.kind -eq 'schema') {
        $ctx = @{ Root = $root; TmpRoot = ''; SilentElev = $silentElev }
        $bad = & $rc.assert $null $ctx
        if ($bad) { Add-Result 'repair' $rc.name '' $false (($bad | Select-Object -First 3) -join '; ') }
        else { Add-Result 'repair' $rc.name '' $true }
        continue
    }
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-repaircase-" + $rc.name + "-" + $PID)
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'reports') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'repair\actions') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'repair\repair.ps1') -Destination (Join-Path $tmpRoot 'repair\repair.ps1') -Force
    if ($rc.kind -eq 'fixture') {
        foreach ($kv in $rc.fixtures.GetEnumerator()) {
            [System.IO.File]::WriteAllText((Join-Path $tmpRoot ("repair\actions\" + $kv.Key)), $kv.Value, (New-Object System.Text.UTF8Encoding($true)))
        }
    } else {
        Copy-Item -LiteralPath (Join-Path $root ("repair\actions\" + $rc.actionId + '.json')) -Destination (Join-Path $tmpRoot ("repair\actions\" + $rc.actionId + '.json')) -Force
    }
    Copy-Item -Recurse -Force (Join-Path $root 'checks') (Join-Path $tmpRoot 'checks')
    foreach ($mk in @($rc.clean | Where-Object { $_ })) { Remove-Item -LiteralPath (Join-Path $env:TEMP $mk) -Force -ErrorAction SilentlyContinue }
    $useNever = [bool]$rc.neverElevate
    if ($rc.forceNever) { $useNever = $true }   # 黄级真动作单测专用：绝不真跑，预检挡下
    if ($rc.requireSilent -and -not $silentElev) { $useNever = $true }   # 黄级 fixture：不可静默提权的机器转挡下
    if ($rc.kind -eq 'real' -and -not $silentElev) { $useNever = $true }
    $repairArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tmpRoot 'repair\repair.ps1'), '-ActionId', $rc.actionId)
    if ($useNever) { $repairArgs += '-NeverElevate' }
    foreach ($xa in @($rc.extraArgs)) { $repairArgs += [string]$xa }
    $outText = ''
    $exitCode = -1
    try {
        $outText = (& $diagPs @repairArgs 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } catch {
        Add-Result 'repair' $rc.name '' $false ("repair crashed: $($_.Exception.Message)")
        continue
    }
    $res = $null
    try { $res = $outText | ConvertFrom-Json } catch { $res = $null }
    $ctx = @{ Root = $root; TmpRoot = $tmpRoot; SilentElev = $silentElev; ExitCode = $exitCode }
    $bad = @()
    if ($null -eq $res) { $bad += ("repair output unparsable: " + (($outText -split "`r?`n") | Select-Object -First 2)) }
    else { $bad = & $rc.assert $res $ctx }
    if ($bad) { Add-Result 'repair' $rc.name '' $false (($bad | Select-Object -First 3) -join '; ') }
    else { Add-Result 'repair' $rc.name '' $true }
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- ⑤ ext 扩展口子用例（v1.1.0：ext 树/检查加载、内置优先冲突忽略、缺脚本契约；临时仓跑，主仓零污染） ----------
foreach ($xc in $global:DiagExtCases) {
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-ext-" + $xc.name + "-" + $PID)
    if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'reports') -Force | Out-Null
    Copy-Item -Recurse -Force (Join-Path $root 'engine') (Join-Path $tmpRoot 'engine')
    Copy-Item -Recurse -Force (Join-Path $root 'checks') (Join-Path $tmpRoot 'checks')
    Copy-Item -Recurse -Force (Join-Path $root 'trees') (Join-Path $tmpRoot 'trees')
    foreach ($rel in $xc.extFiles.Keys) {
        $dst = Join-Path $tmpRoot ($rel -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($dst, $xc.extFiles[$rel], (New-Object System.Text.UTF8Encoding($true)))
    }
    $engineArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tmpRoot 'engine/run.ps1'), '-TreeName', $xc.tree, '-NoSaveReport', '-NoMenu')
    if ($xc.useMock) {
        # mock 空目录契约：engine mock 模式下缺 mock 文件的检查=SKIP（missing-mock）
        $mockDir = Join-Path $tmpRoot 'mocks'
        New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
        foreach ($kv in $xc.mocks.GetEnumerator()) { Set-Content -Path (Join-Path $mockDir ($kv.Key + '.txt')) -Value $kv.Value -Encoding UTF8 }
        $engineArgs += @('-MockDir', $mockDir)
    }
    $errFile = Join-Path $tmpRoot 'stderr.tmp'
    $engineOut = ''; $errText = ''; $exitCode = -1
    try {
        # native stderr 重定向在 EAP=Stop 下会把 stderr 首行变成终止错误（同 v1.0.1 DNS 检查坑）：
        # 外层降 Continue + finally 恢复，2> 才是纯文件重定向
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $engineOut = (& $diagPs @engineArgs 2> $errFile | Out-String)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    } catch {
        Add-Result 'ext' $xc.name '' $false ("engine crashed: $($_.Exception.Message)")
        continue
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    $bad = @()
    if ($exitCode -ne $xc.expectExit) { $bad += "exitcode expect $($xc.expectExit) got $exitCode" }
    foreach ($kw in $xc.expectOut) { if ($engineOut -notmatch [regex]::Escape($kw)) { $bad += "stdout missing: $kw" } }
    foreach ($kw in $xc.expectErr) { if ("$errText" -notmatch [regex]::Escape($kw)) { $bad += "stderr missing: $kw" } }
    foreach ($kw in $xc.expectNotOut) { if ($engineOut -match [regex]::Escape($kw)) { $bad += "stdout must NOT contain: $kw" } }
    if ($bad.Count -gt 0) { Add-Result 'ext' $xc.name '' $false ($bad -join '; ') }
    else { Add-Result 'ext' $xc.name '' $true }
    Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- ⑥ 数据根用例（MSIX 写路径外移；临时仓跑 engine，主仓 reports 零污染） ----------
$drCleanMocks = ($global:DiagScenarios | Where-Object { $_.name -eq 'full_pass_all_green' }).mocks
foreach ($dc in $global:DiagDataRootCases) {
    $prevDataRoot = $env:DIAG_DATA_ROOT
    $prevLad = $env:LOCALAPPDATA
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-dataroot-" + $dc.name + "-" + $PID)
    if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    # kind=windowsapps：仓造在 ...\WindowsApps\Diag.Health\ 下并临时改 LOCALAPPDATA（子进程继承），验证只读安装目录探测外移
    $appRoot = $tmpRoot
    if ($dc.kind -eq 'windowsapps') { $appRoot = Join-Path $tmpRoot 'WindowsApps\Diag.Health' }
    $fakeLad = Join-Path $tmpRoot 'fake-LocalAppData'
    $dataRoot = Join-Path $fakeLad '电脑体检台'
    New-Item -ItemType Directory -Path (Join-Path $appRoot 'reports') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $appRoot 'mocks') -Force | Out-Null
    Copy-Item -Recurse -Force (Join-Path $root 'engine') (Join-Path $appRoot 'engine')
    Copy-Item -Recurse -Force (Join-Path $root 'checks') (Join-Path $appRoot 'checks')
    Copy-Item -Recurse -Force (Join-Path $root 'trees') (Join-Path $appRoot 'trees')
    foreach ($kv in $drCleanMocks.GetEnumerator()) {
        Set-Content -Path (Join-Path $appRoot ('mocks/' + $kv.Key + '.txt')) -Value $kv.Value -Encoding UTF8
    }
    if ($dc.kind -eq 'env') {
        $env:DIAG_DATA_ROOT = Join-Path $tmpRoot 'fake-LocalAppData\电脑体检台'
        Remove-Item Env:\LOCALAPPDATA -ErrorAction SilentlyContinue; $env:LOCALAPPDATA = $prevLad
    } else {
        Remove-Item Env:\DIAG_DATA_ROOT -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = $fakeLad
    }
    $engineOut = ''
    $exitCode = -1
    try {
        $engineOut = (& $diagPs -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appRoot 'engine/run.ps1') -TreeName network -MockDir (Join-Path $appRoot 'mocks') -NoMenu -JsonReport 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } catch {
        Add-Result 'dataroot' $dc.name '' $false ("engine crashed: $($_.Exception.Message)")
        continue
    } finally {
        $env:DIAG_DATA_ROOT = $prevDataRoot
        if ($null -eq $prevDataRoot) { Remove-Item Env:\DIAG_DATA_ROOT -ErrorAction SilentlyContinue }
        $env:LOCALAPPDATA = $prevLad
    }
    $bad = @()
    if ($exitCode -ne 0) { $bad += "exitcode expect 0 got $exitCode" }
    $dataReports = @(Get-ChildItem -LiteralPath (Join-Path $dataRoot 'reports') -Filter 'diag-network-*.json' -ErrorAction SilentlyContinue)
    if ($dataReports.Count -lt 1) { $bad += 'json report NOT in data root' }
    $appReports = @(Get-ChildItem -LiteralPath (Join-Path $appRoot 'reports') -Filter 'diag-network-*.json' -ErrorAction SilentlyContinue)
    if ($appReports.Count -gt 0) { $bad += 'json report leaked into app root reports' }
    $j = $null
    if ($dataReports.Count -ge 1) {
        try { $j = Get-Content $dataReports[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $j = $null }
        if ($null -eq $j) { $bad += 'data-root json unparsable' }
        elseif ($j.engine -ne '电脑体检台 v1.7.1') { $bad += 'engine field: ' + $j.engine }
    }
    if ($bad.Count -gt 0) { Add-Result 'dataroot' $dc.name '' $false ($bad -join '; ') }
    else { Add-Result 'dataroot' $dc.name '' $true }
    Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- ⑦ i18n suggestions 模板静态校验（1026 方案 B M1：跑真检查脚本取实况 detail） ----------
$enJs = Get-Content -LiteralPath (Join-Path $root 'ui/i18n/en-US.js') -Raw -Encoding UTF8
$zhJs = Get-Content -LiteralPath (Join-Path $root 'ui/i18n/zh-CN.js') -Raw -Encoding UTF8
# guard: zh pack must NOT carry a suggestions table (zh = engine original, double layer banned)
if ($zhJs -match '(?m)^\s*suggestions\s*:') {
    Add-Result 'i18n' 'zh_no_suggestions_table' '' $false 'zh-CN.js gained a suggestions table (double layer banned)'
} else {
    Add-Result 'i18n' 'zh_no_suggestions_table' '' $true
}
# guard: every suggestions key maps to a real check script (after variant suffix strip)
$sugBlock = ''
if ($enJs -match '(?ms)suggestions:\s*\{(.*?)\n\s*\},') { $sugBlock = $Matches[1] }
$blockKeys = @([regex]::Matches($sugBlock, "(?m)^\s*'([A-Za-z0-9_]+)':") | ForEach-Object { $_.Groups[1].Value })
$badKeys = @()
foreach ($k in $blockKeys) {
    # full key first (e.g. net_dns_gateway_proxy ends in a registered suffix yet IS a check id),
    # then strip exactly one registered suffix
    $base = $k
    if (-not (Test-Path -LiteralPath (Join-Path $root ("checks/" + $base + ".ps1")))) {
        foreach ($sfx in $global:DiagI18nVariantSuffixes) {
            if ($base.EndsWith($sfx)) { $base = $base.Substring(0, $base.Length - $sfx.Length); break }
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root ("checks/" + $base + ".ps1")))) { $badKeys += $k }
}
if ($badKeys.Count -gt 0) { Add-Result 'i18n' 'sug_keys_map_to_checks' ('keys=' + $blockKeys.Count) $false ('orphan keys: ' + ($badKeys -join ',')) }
else { Add-Result 'i18n' 'sug_keys_map_to_checks' ('keys=' + $blockKeys.Count) $true }

foreach ($ic in $global:DiagI18nCases) {
    $scriptFile = Join-Path $root ("checks/" + $ic.check + ".ps1")
    # mock 来源：用例自带 mock（M1 范式），或 mockFrom='note 片段' 引用 cases.ps1 的既有 FAIL 用例
    # （M2 起：挑 check 相同 + note 含片段 + expectStatus=FAIL 的第一条；找不到=显性 FAIL 不静默）
    $mockRaw = $ic.mock
    $codesJson = $ic.mockCodesJson; $suspJson = $ic.mockSuspectsJson
    if (-not $mockRaw -and $ic.mockFrom) {
        $src = @($global:DiagCases | Where-Object { $_.check -eq $ic.check -and $_.expectStatus -eq 'FAIL' -and $_.note -like ('*' + $ic.mockFrom + '*') })
        if ($src.Count -lt 1) {
            Add-Result 'i18n' $ic.name '' $false ('mockFrom not found in cases.ps1: ' + $ic.mockFrom)
            continue
        }
        $mockRaw = $src[0].mock; $codesJson = $src[0].mockCodesJson; $suspJson = $src[0].mockSuspectsJson
    }
    if (-not $mockRaw) {
        Add-Result 'i18n' $ic.name '' $false 'case has neither mock nor mockFrom'
        continue
    }
    $mockTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-mock-i18n-$PID-" + $ic.name + '.txt')
    Set-Content -Path $mockTmp -Value $mockRaw -Encoding UTF8
    $exArgs = @(); $tmpJsons = @()
    if ($codesJson) {
        $cj = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-i18n-codes-$PID-" + $ic.name + '.json')
        Set-Content -Path $cj -Value $codesJson -Encoding UTF8
        $exArgs += @('-CodesFile', $cj); $tmpJsons += $cj
    }
    if ($suspJson) {
        $sj = Join-Path ([System.IO.Path]::GetTempPath()) ("diag-i18n-susp-$PID-" + $ic.name + '.json')
        Set-Content -Path $sj -Value $suspJson -Encoding UTF8
        $exArgs += @('-SuspectsFile', $sj); $tmpJsons += $sj
    }
    $job = Start-Job -ScriptBlock {
        param($ps, $s, $mf, $ex)
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $a = @()
        if ($mf) { $a += @('-MockFile', $mf) }
        if ($ex) { $a += $ex }
        & $ps -NoProfile -ExecutionPolicy Bypass -File $s @a 2>&1 | Out-String
    } -ArgumentList $diagPs, $scriptFile, $mockTmp, $exArgs
    if (-not (Wait-Job $job -Timeout 60)) { Stop-Job $job -Force; $outText = '' }
    else { $outText = (Receive-Job $job) | Out-String }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item $mockTmp -Force -ErrorAction SilentlyContinue
    foreach ($tj in $tmpJsons) { Remove-Item $tj -Force -ErrorAction SilentlyContinue }
    $bad = @()
    $j = $null
    try { $j = $outText | ConvertFrom-Json } catch { $j = $null }
    if ($null -eq $j) { $bad += 'check output unparsable' }
    else {
        if ($j.status -ne 'FAIL') { $bad += ('expect FAIL got ' + $j.status) }
        if ([string]::IsNullOrWhiteSpace($j.suggestion)) { $bad += 'FAIL without zh suggestion' }
        $liveFields = @()
        if ($null -ne $j.detail) { $liveFields = @($j.detail.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($src in $ic.detailSources) {
            if ($liveFields -notcontains $src) { $bad += ('detail source missing in live run: ' + $src) }
        }
    }
    # template extraction: single-line quoted value (write templates one-per-line in en-US.js)
    $tpl = $null
    $m = [regex]::Match($enJs, "(?m)^\s*'" + [regex]::Escape($ic.tplKey) + "':\s*'(.*)',\s*$")
    if ($m.Success) { $tpl = $m.Groups[1].Value }
    if (-not $tpl) { $bad += ('template not found / not single-line: ' + $ic.tplKey) }
    else {
        $ph = @([regex]::Matches($tpl, '\{([A-Za-z0-9_]+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $exp = @($ic.placeholders | Sort-Object -Unique)
        if (($ph -join ',') -ne ($exp -join ',')) { $bad += ('placeholders expect [' + ($exp -join ',') + '] got [' + ($ph -join ',') + ']') }
        foreach ($kw in $ic.keywords) {
            if ($tpl -notmatch [regex]::Escape($kw)) { $bad += ('template missing keyword: ' + $kw) }
        }
    }
    if ($bad.Count -gt 0) { Add-Result 'i18n' $ic.name '' $false ($bad -join '; ') }
    else { Add-Result 'i18n' $ic.name '' $true }
}

# ---------- ⑧ 修复卡 en 映射静态对齐（1026 方案 B·M3：node 断言 33 键双侧字段对齐+warn 语义零） ----------
# en-US.js actions 与 repair/actions/*.json（执行层真源，只读）按 actField/actSteps/actSource
# 真实消费语义对齐：键集双向/六字段非空/steps 逐键长度+desc/how 对齐/sources 对齐/CJK 零残留/
# warn 触发条件模拟=0。fail-closed：node 起不来=FAIL（验证类无程序级证据不放行）。
$nodeCheck = Join-Path $PSScriptRoot 'i18n_actions_check.mjs'
try {
    $nodeOut = (& node $nodeCheck 2>&1 | Out-String)
    $nodeExit = $LASTEXITCODE
} catch { $nodeOut = [string]$_.Exception.Message; $nodeExit = 1 }
if ($nodeExit -eq 0) {
    if ($nodeOut -match 'i18n_actions_check: (\d+)/(\d+) PASS') {
        Add-Result 'i18n' 'en_actions_alignment' ('checks=' + $Matches[1] + '/' + $Matches[2]) $true
    } else {
        Add-Result 'i18n' 'en_actions_alignment' '' $false 'node ran but summary line not parsed'
    }
} else {
    $failLines = @($nodeOut -split "`r?`n" | Where-Object { $_ -match '^FAIL' } | Select-Object -First 3)
    Add-Result 'i18n' 'en_actions_alignment' '' $false (($failLines -join ' ; ') + ' (exit=' + $nodeExit + ')')
}

# ---------- 汇总 ----------
$failCount = @($results | Where-Object { -not $_.ok }).Count
Write-Host ""
Write-Host ("================ 模拟测试汇总: {0}/{1} 绿 ================" -f ($results.Count - $failCount), $results.Count)
if ($failCount -gt 0) {
    $results | Where-Object { -not $_.ok } | Format-Table cat, name, note, why -AutoSize | Out-String | Write-Host
    exit 1
}
exit 0

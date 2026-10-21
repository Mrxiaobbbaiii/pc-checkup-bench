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
    # 可选：注入损坏的码书/名单 JSON，验证检查项 SKIP 路径（施工单 v0.2 完工问 1）
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

# ---------- ③ B 案输出层用例（v0.6：-ProgressFile/-JsonReport；临时仓跑 engine，主仓 reports 零污染） ----------
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
foreach ($rc in $global:DiagRepairCases) {
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
    if ($rc.kind -eq 'real' -and -not $silentElev) { $useNever = $true }
    $repairArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tmpRoot 'repair\repair.ps1'), '-ActionId', $rc.actionId)
    if ($useNever) { $repairArgs += '-NeverElevate' }
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

# ---------- 汇总 ----------
$failCount = @($results | Where-Object { -not $_.ok }).Count
Write-Host ""
Write-Host ("================ 模拟测试汇总: {0}/{1} 绿 ================" -f ($results.Count - $failCount), $results.Count)
if ($failCount -gt 0) {
    $results | Where-Object { -not $_.ok } | Format-Table cat, name, note, why -AutoSize | Out-String | Write-Host
    exit 1
}
exit 0

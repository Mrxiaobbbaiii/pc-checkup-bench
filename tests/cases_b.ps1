#Requires -Version 5.1
# 输出层用例（-ProgressFile 事件流 + -JsonReport 结构化报告；默认关回归）
# 结构：name / tree / json（是否带 -JsonReport）/ full / expectExit / mocks（复用既有场景集）/ verify（断言 scriptblock，返回失败原因数组）
# 执行方式：临时仓（engine/checks/trees 复制到 temp）跑 engine，reports 落盘零污染主仓（run_tests.ps1 ③ 节）。

# 按树/层序展开 checks 全序（tree/layer/check 形式，事件序与 JSON 层序共用的期望源）
function Get-TreeCheckSeq {
    param([string]$TreesRoot, [string[]]$TreeNames)
    $seq = @()
    foreach ($t in $TreeNames) {
        $td = Get-Content (Join-Path $TreesRoot "$t.yaml") -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($l in $td.layers) { foreach ($c in $l.checks) { $seq += "$t/$($l.name)/$c" } }
    }
    return $seq
}

function Get-TreeDef {
    param([string]$TreesRoot, [string]$TreeName)
    return (Get-Content (Join-Path $TreesRoot "$TreeName.yaml") -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# 读事件流（跳过空行；UTF8 兼容 5.1 Add-Content 首行 BOM）
function Read-ProgressLines {
    param([string]$ProgFile)
    if (-not (Test-Path $ProgFile)) { return $null }
    return @(Get-Content -LiteralPath $ProgFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
}

# 取临时仓 reports/ 内 diag-*.json
function Get-LatestJson {
    param([string]$Root)
    return @(Get-ChildItem -LiteralPath (Join-Path $Root 'reports') -Filter 'diag-*.json' -ErrorAction SilentlyContinue)
}

$netDnsMocks = ($global:DiagScenarios | Where-Object { $_.name -eq 'dns_deadaddr_breakpoint' }).mocks
$netCleanMocks = ($global:DiagScenarios | Where-Object { $_.name -eq 'full_pass_all_green' }).mocks
$bsLocalMocks = ($global:DiagScenarios | Where-Object { $_.name -eq 'bs_local_case' }).mocks
$allCleanMocks = ($global:DiagScenarios | Where-Object { $_.name -eq 'all_trees_merge' }).mocks

$global:DiagBCases = @(
    # 1. 单树断点：JSON 报告结构与事件流全量断言
    @{ name = 'b_json_single_break'; tree = 'network'; json = $true; full = $false; expectExit = 2; mocks = $netDnsMocks
       verify = {
           param($ctx)
           $bad = @()
           $jfiles = Get-LatestJson $ctx.Root
           if ($jfiles.Count -ne 1) { $bad += "json files expect 1 got $($jfiles.Count)"; return $bad }
           $j = Get-Content $jfiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
           if ($j.engine -ne '电脑体检台 v1.8.4') { $bad += "engine field: $($j.engine)" }
           if (@($j.trees).Count -ne 1) { $bad += "trees expect 1 got $(@($j.trees).Count)" }
           $t0 = $j.trees[0]
           if ($t0.tree -ne 'network') { $bad += "tree name: $($t0.tree)" }
           if ($t0.break_layer -ne 'dns') { $bad += "break_layer: $($t0.break_layer)" }
           $def = Get-TreeDef "$($ctx.Root)\trees" 'network'
           if (@($t0.layers).Count -ne @($def.layers).Count) { $bad += "layers count mismatch json vs yaml" }
           $i = 0
           foreach ($l in $t0.layers) {
               if ($l.name -ne $def.layers[$i].name) { $bad += "layer order at $i" }
               if ($l.state -eq 'SKIPPED-AFTER-BREAK') {
                   if (@($l.checks).Count -ne 0) { $bad += "layer $($l.name) skipped layer has checks" }
               } elseif (@($l.checks).Count -ne @($def.layers[$i].checks).Count) { $bad += "layer $($l.name) checks count mismatch" }
               foreach ($c in @($l.checks)) {
                   if ($c.status -notin @('PASS', 'FAIL', 'SKIP')) { $bad += "bad status $($c.status)" }
                   if ($c.status -eq 'FAIL' -and [string]::IsNullOrWhiteSpace($c.suggestion)) { $bad += "FAIL $($c.name) without suggestion" }
               }
               $i++
           }
           $dnsLayer = $t0.layers | Where-Object { $_.name -eq 'dns' }
           if ($dnsLayer.state -ne 'BREAK') { $bad += "dns layer state: $($dnsLayer.state)" }
           # 事件流：9 check + 1 break + 1 tree_done + 1 done，序=树层序
           $ev = Read-ProgressLines $ctx.Prog
           if ($null -eq $ev) { $bad += 'progress file missing'; return $bad }
           $evs = @($ev | ForEach-Object { $_ | ConvertFrom-Json })
           $checks = @($evs | Where-Object { $_.event -eq 'check' })
           $expect = @(Get-TreeCheckSeq (Join-Path $ctx.Root 'trees') @('network') | Where-Object { $_ -notmatch '^network/app/' })
           if ($checks.Count -ne $expect.Count) { $bad += "check events expect $($expect.Count) got $($checks.Count)" }
           for ($k = 0; $k -lt [Math]::Min($checks.Count, $expect.Count); $k++) {
               $got = "$($checks[$k].tree)/$($checks[$k].layer)/$($checks[$k].check)"
               if ($got -ne $expect[$k]) { $bad += "event order at $($k): $got"; break }
           }
           if (@($evs | Where-Object { $_.event -eq 'break' }).Count -ne 1) { $bad += 'break events expect 1' }
           if (@($evs | Where-Object { $_.event -eq 'tree_done' }).Count -ne 1) { $bad += 'tree_done events expect 1' }
           $done = $evs | Where-Object { $_.event -eq 'done' }
           if (-not $done -or $done.exit -ne 2) { $bad += 'done event missing or exit != 2' }
           if ($done -and -not (Test-Path $done.jsonReport)) { $bad += "done.jsonReport not found: $($done.jsonReport)" }
           if ($ctx.Out -notmatch [regex]::Escape('[报告已保存]')) { $bad += 'stdout missing report-saved line (regression)' }
           return $bad
       } },

    # 2. 单树全通：break_layer=null + 层全 PASS + done.exit=0
    @{ name = 'b_json_single_fullpass'; tree = 'network'; json = $true; full = $true; expectExit = 0; mocks = $netCleanMocks
       verify = {
           param($ctx)
           $bad = @()
           $jfiles = Get-LatestJson $ctx.Root
           if ($jfiles.Count -ne 1) { $bad += "json files expect 1 got $($jfiles.Count)"; return $bad }
           $j = Get-Content $jfiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
           $t0 = $j.trees[0]
           if ($null -ne $t0.break_layer) { $bad += "break_layer expect null got $($t0.break_layer)" }
           $breakStates = @($t0.layers | Where-Object { $_.state -eq 'BREAK' })
           if ($breakStates.Count -ne 0) { $bad += 'unexpected BREAK layer in clean pass' }
           $evs = @(Read-ProgressLines $ctx.Prog | ForEach-Object { $_ | ConvertFrom-Json })
           $done = $evs | Where-Object { $_.event -eq 'done' }
           if (-not $done -or $done.exit -ne 0) { $bad += 'done exit != 0' }
           if (@($evs | Where-Object { $_.event -eq 'break' }).Count -ne 0) { $bad += 'unexpected break event' }
           return $bad
       } },

    # 3. all 多树：JSON trees=6 按序（内置六树）+ 事件全量 44 check/6 tree_done/1 done
    @{ name = 'b_json_all_clean'; tree = 'all'; json = $true; full = $true; expectExit = 0; mocks = $allCleanMocks
       verify = {
           param($ctx)
           $bad = @()
           $jfiles = Get-LatestJson $ctx.Root
           if ($jfiles.Count -ne 1) { $bad += "json files expect 1 got $($jfiles.Count)"; return $bad }
           $j = Get-Content $jfiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
           $order = @('network', 'bluescreen', 'hardware', 'performance', 'drivers', 'security')
           if (@($j.trees).Count -ne 6) { $bad += "trees expect 6 got $(@($j.trees).Count)"; return $bad }
           for ($i = 0; $i -lt 6; $i++) {
               if ($j.trees[$i].tree -ne $order[$i]) { $bad += "tree order at $($i): $($j.trees[$i].tree)" }
               if ($null -ne $j.trees[$i].break_layer) { $bad += "tree $($j.trees[$i].tree) break_layer not null" }
           }
           $evs = @(Read-ProgressLines $ctx.Prog | ForEach-Object { $_ | ConvertFrom-Json })
           $checks = @($evs | Where-Object { $_.event -eq 'check' })
           $expect = Get-TreeCheckSeq (Join-Path $ctx.Root 'trees') $order
           if ($checks.Count -ne $expect.Count) { $bad += "check events expect $($expect.Count) got $($checks.Count)" }
           for ($k = 0; $k -lt [Math]::Min($checks.Count, $expect.Count); $k++) {
               $got = "$($checks[$k].tree)/$($checks[$k].layer)/$($checks[$k].check)"
               if ($got -ne $expect[$k]) { $bad += "event order at $($k): $got"; break }
           }
           if (@($evs | Where-Object { $_.event -eq 'tree_done' }).Count -ne 6) { $bad += 'tree_done events expect 6' }
           $done = $evs | Where-Object { $_.event -eq 'done' }
           if (-not $done -or $done.exit -ne 0) { $bad += 'done exit != 0' }
           return $bad
       } },

    # 4. 快速模式（无 -Full）断点即停：蓝屏树 history 层断点 → 仅 2 项事件 + 后续层 SKIPPED-AFTER-BREAK 空 checks
    @{ name = 'b_progress_faststop'; tree = 'bluescreen'; json = $true; full = $false; expectExit = 2; mocks = $bsLocalMocks
       verify = {
           param($ctx)
           $bad = @()
           $evs = @(Read-ProgressLines $ctx.Prog | ForEach-Object { $_ | ConvertFrom-Json })
           $checks = @($evs | Where-Object { $_.event -eq 'check' })
           if ($checks.Count -ne 2) { $bad += "fast-stop check events expect 2 got $($checks.Count)" }
           if ($checks.Count -ge 1 -and $checks[0].check -ne 'bs_event_history') { $bad += 'first event not bs_event_history' }
           $brk = $evs | Where-Object { $_.event -eq 'break' }
           if (-not $brk -or $brk.layer -ne 'history') { $bad += 'break event missing or wrong layer' }
           $td = $evs | Where-Object { $_.event -eq 'tree_done' }
           if (-not $td -or $td.status -ne 'FAIL') { $bad += 'tree_done status != FAIL' }
           $jfiles = Get-LatestJson $ctx.Root
           if ($jfiles.Count -ne 1) { $bad += "json files expect 1 got $($jfiles.Count)"; return $bad }
           $j = Get-Content $jfiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
           $t0 = $j.trees[0]
           if ($t0.break_layer -ne 'history') { $bad += "break_layer: $($t0.break_layer)" }
           $skipped = @($t0.layers | Where-Object { $_.state -eq 'SKIPPED-AFTER-BREAK' })
           if ($skipped.Count -ne 2) { $bad += "SKIPPED-AFTER-BREAK layers expect 2 got $($skipped.Count)" }
           foreach ($l in $skipped) { if (@($l.checks).Count -ne 0) { $bad += "skipped layer $($l.name) has checks" } }
           return $bad
       } },

    # 5. 默认关回归：不带两参数 → 无 JSON 文件、无进度副作用、stdout 基线照常
    @{ name = 'b_default_off'; tree = 'network'; json = $false; full = $true; expectExit = 0; mocks = $netCleanMocks
       verify = {
           param($ctx)
           $bad = @()
           $jfiles = Get-LatestJson $ctx.Root
           if ($jfiles.Count -ne 0) { $bad += "default-off produced $($jfiles.Count) json file(s)" }
           if (Test-Path $ctx.Prog) { $bad += 'progress file should not exist (param not given)' }
           if ($ctx.Out -notmatch [regex]::Escape('五组全通')) { $bad += 'stdout baseline keyword missing' }
           return $bad
       } },

    # 6. v1.6.1 多选组合：network,security 两树合并（stdout 合并标题、JSON trees=2 按勾选序、事件全序、done=0）
    @{ name = 'b_json_multi_merge'; tree = 'network,security'; json = $true; full = $true; expectExit = 0; mocks = $allCleanMocks
       verify = {
           param($ctx)
           $bad = @()
           if ($ctx.Out -notmatch [regex]::Escape('合并体检报告')) { $bad += 'stdout missing merged title' }
           if ($ctx.Out -match [regex]::Escape('全面体检报告')) { $bad += 'stdout must not claim full-scope title for a partial combo' }
           $jfiles = Get-LatestJson $ctx.Root
           if ($jfiles.Count -ne 1) { $bad += "json files expect 1 got $($jfiles.Count)"; return $bad }
           $j = Get-Content $jfiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
           $order = @('network', 'security')
           if (@($j.trees).Count -ne 2) { $bad += "trees expect 2 got $(@($j.trees).Count)"; return $bad }
           for ($i = 0; $i -lt 2; $i++) {
               if ($j.trees[$i].tree -ne $order[$i]) { $bad += "tree order at $($i): $($j.trees[$i].tree)" }
               if ($null -ne $j.trees[$i].break_layer) { $bad += "tree $($j.trees[$i].tree) break_layer not null" }
           }
           $evs = @(Read-ProgressLines $ctx.Prog | ForEach-Object { $_ | ConvertFrom-Json })
           $checks = @($evs | Where-Object { $_.event -eq 'check' })
           $expect = Get-TreeCheckSeq (Join-Path $ctx.Root 'trees') $order
           if ($checks.Count -ne $expect.Count) { $bad += "check events expect $($expect.Count) got $($checks.Count)" }
           for ($k = 0; $k -lt [Math]::Min($checks.Count, $expect.Count); $k++) {
               $got = "$($checks[$k].tree)/$($checks[$k].layer)/$($checks[$k].check)"
               if ($got -ne $expect[$k]) { $bad += "event order at $($k): $got"; break }
           }
           if (@($evs | Where-Object { $_.event -eq 'tree_done' }).Count -ne 2) { $bad += 'tree_done events expect 2' }
           $done = $evs | Where-Object { $_.event -eq 'done' }
           if (-not $done -or $done.exit -ne 0) { $bad += 'done exit != 0' }
           return $bad
       } }
)

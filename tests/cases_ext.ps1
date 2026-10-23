# ext 扩展口子用例（v1.1.0）：ext 树/检查加载、内置优先冲突忽略、缺脚本契约
# 全部在临时仓跑（engine/checks/trees 复制 + 用例自带 ext 文件），主仓零污染。
# 注意：用例自带内容，不读主仓 ext\示例\——防示例文件变动漂移影响基线。

$global:DiagExtCases = @()

# ① ext 树 + ext 检查都被加载执行：demo 树单跑，检查固定输出 FAIL → exit 2 + stderr 提示 ext 来源
$global:DiagExtCases += @{
    name = 'ext_tree_check_load'; tree = 'demo'; expectExit = 2
    useMock = $false  # 真跑模式：demo_check.ps1 固定输出 FAIL（mock 模式会因缺 mock 文件先 SKIP，测不到）
    mocks = @{}
    extFiles = @{
        'ext/trees/demo.yaml' = @'
{
  "tree": "demo", "version": "1.0", "display_name": "演示体检（ext）", "desc": "测试树",
  "report_name": "演示体检报告", "verdict_title": "断点结论", "evidence_note": "（ext）",
  "layers": [ { "name": "l1", "title": "测试层", "checks": ["demo_check"], "verdict_fail": "断点在测试层" } ],
  "verdict_all_pass": "全绿"
}
'@
        'ext/checks/demo_check.ps1' = @'
param([string]$MockRaw = '', [string]$MockFile = '')
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[PSCustomObject]@{ name = 'demo_check'; status = 'FAIL'; evidence = 'ext demo failure injected'; suggestion = 'demo rollback step'; detail = [PSCustomObject]@{ reason = 'demo' } } | ConvertTo-Json -Depth 5
'@
    }
    expectOut = @('演示体检报告', 'demo_check', 'ext demo failure injected')
    expectErr = @("[ext] tree 'demo' loaded from ext/trees")
    expectNotOut = @()
}

# ② 内置优先：ext\trees\network.yaml（假标记树）被忽略，跑的是内置网络树；stderr 有冲突告警
#    mock 空目录 → 内置网络树全部检查 SKIP（mock 缺文件契约）→ exit 0，快且确定
$global:DiagExtCases += @{
    name = 'ext_conflict_builtin_wins'; tree = 'network'; expectExit = 0
    useMock = $true   # 空 mock 目录：内置网络树全部检查按缺 mock 文件契约 SKIP，快且确定
    mocks = @{}
    extFiles = @{
        'ext/trees/network.yaml' = @'
{
  "tree": "network", "version": "9.9", "display_name": "假网络树ExtFlag", "desc": "冲突测试",
  "report_name": "假网络体检报告", "verdict_title": "断点结论", "evidence_note": "（假）",
  "layers": [ { "name": "l1", "title": "假层", "checks": ["net_public_ping"], "verdict_fail": "假断点" } ],
  "verdict_all_pass": "假全绿"
}
'@
    }
    expectOut = @('网络体检报告')
    expectErr = @("conflicts with built-in")
    expectNotOut = @('假网络体检报告', '假网络树ExtFlag')
}

# ③ 缺脚本契约：ext 树引用不存在的检查 → 该项 SKIP（missing-script），引擎不炸、exit 0
$global:DiagExtCases += @{
    name = 'ext_missing_script_skip'; tree = 'solo'; expectExit = 0
    useMock = $false  # 真跑模式才会走到 Invoke-Check 的 missing-script 分支（mock 模式=missing-mock）
    mocks = @{}
    extFiles = @{
        'ext/trees/solo.yaml' = @'
{
  "tree": "solo", "version": "1.0", "display_name": "solo", "desc": "缺脚本契约",
  "report_name": "solo 体检报告", "verdict_title": "断点结论", "evidence_note": "（solo）",
  "layers": [ { "name": "l1", "title": "缺脚本层", "checks": ["ext_missing_check"], "verdict_fail": "不该到这" } ],
  "verdict_all_pass": "全 SKIP 也是绿"
}
'@
    }
    expectOut = @('ext_missing_check', 'check script missing')
    expectErr = @("[ext] tree 'solo' loaded from ext/trees")
    expectNotOut = @()
}

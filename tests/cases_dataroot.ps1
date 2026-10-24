#Requires -Version 5.1
# 数据根用例（1024 轮1-B：MSIX 写路径外移；run_tests.ps1 ⑥ 节执行）
# 覆盖：① DIAG_DATA_ROOT 环境变量注入（server/测试通道）② WindowsApps 只读安装目录探测自动外移
# 默认场景（不设 env、路径不含 WindowsApps）行为零变化由 ③ 节 b_json_* 既有用例回归覆盖，不重复造。
# 用例结构：name / kind（'env' | 'windowsapps'）— ⑥ 节按 kind 造布局与断言。

$global:DiagDataRootCases = @(
    @{ name = 'dataroot_env_override'; kind = 'env' }
    @{ name = 'dataroot_windowsapps_detect'; kind = 'windowsapps' }
)

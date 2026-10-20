# diag 设计文档 design.md（v0.1 定稿 · 2026-10-19）

> 本文档=第一片（v0.1 网络模块）设计定稿。已实现+真机验收毕，本档为反向提炼的正式设计真源。
> 后续版本改设计先改这里、拍板后才动代码。

## 一、拍板记录（2026-10-19 20:21，用户逐条拍过）

| # | 决策点 | 拍板结果 |
|---|---|---|
| 1 | 树文件格式 | JSON 语法（=合法 YAML 1.2 子集），零依赖（diag 必须断网可用，不依赖 powershell-yaml 模块） |
| 2 | 层内粒度 | 整层跑完才停（保留交叉证据）；默认断点即停，`-Full` 全取证 |
| 3 | 多网卡部分坏语义 | 存在 ≥1 可用链路即 PASS，异常网卡记备注（断点=网络不通的原因，不误报） |
| 4 | DNS 死地址口径 | 仅"私有地址 DNS 不在活动网卡网段"判死地址；公共 DNS 不判（可达性交给 nslookup 系列检查） |
| 5 | 普及版节奏 | 今晚干（1019 晚拍板）：Windows 自带 PowerShell 5.1 兼容+双击 .bat 启动+txt 报告自动弹出 |

## 二、总体架构

```
diag/
├── engine/run.ps1      推进器：读树→逐层执行检查项→FAIL 定位断点→出报告
├── checks/             探测层：一个文件一个检查项，只读；_lib.ps1=公共判定库
├── trees/network.yaml  决策层：排查树（声明式）；加新故障域=加一棵树，不改引擎
├── tests/              模拟故障测试（铁律 3）：cases.ps1 单项用例+scenarios.ps1 全树场景+run_tests.ps1 runner
├── reports/            体检报告（带时间戳落盘，txt 格式记事本直开）
└── CHANGELOG.md        切片记账
```

技术栈：PowerShell（5.1 自带版 + 7 双兼容）。文件编码 UTF-8 带 BOM（5.1 读中文字面量的硬要求）。
engine 调用检查项=Start-Job 子进程 + 单项 60 秒超时（超时=SKIP 不阻塞整树）；子进程解释器用 `(Get-Process -Id $PID).Path` 自引用（5.1/7 通吃）。

## 三、检查项统一接口（所有检查项遵守）

每个 checks/*.ps1：
- `param([string]$MockRaw = '')`——MockRaw 非空=模拟模式（喂伪造命令输出，跳过真实取证，走同一条判定路径；模拟测试用）
- 真实模式：执行只读命令取证（铁律 1：只读；grep 审计命令白名单=show/print/ping/nslookup/ipconfig）
- stdout 输出单 JSON 对象（铁律 2：evidence 必附原始输出摘录；FAIL 必附 suggestion）：

```json
{
  "name":       "检查项名（=文件名）",
  "status":     "PASS | FAIL | SKIP",   // SKIP=无法判定（超时/输出不可解析），≠PASS
  "evidence":   "[命令] + 原始输出关键行摘录",
  "suggestion": "人话修复建议：【修复命令，请自己执行】…【回滚】…",  // FAIL 必附，仅文本
  "detail":     { }                      // 结构化补充，报告不直接展示
}
```

## 四、树 schema（trees/network.yaml）

```
{ tree, version,
  layers: [ { name, title, checks: [检查项名...], verdict_fail: 一句人话断点结论 } ... ],
  verdict_all_pass: 全通时人话结论（应用层排查指引） }
```

v0.1 四层：link（链路）→ gateway（网关/路由）→ wan（公网）→ dns（域名解析）。
映射框架第七节判定主干：网关不通→链路层嫌疑；网关通+公网不通→WAN 侧；公网通+DNS 不通→DNS 层；全通+浏览器坏→应用层（写在 verdict_all_pass）。

## 五、断点推进流程

```
读树 → 按层序逐层：
  层内逐检查项子进程执行（超时=SKIP）
  层末有 FAIL → 记断点=该层 → 默认后续层全 SKIP / -Full 照跑攒证据
四层全过 → 结论=verdict_all_pass
```
退出码：0=全通 / 2=有断点 / 3=引擎错误。报告=stdout+落盘 txt，结构：断点结论（一句人话）→修复建议（命令文本+回滚）→证据链（按层逐项附原始输出）。

## 六、三铁律落地机制

1. 探测只读：检查项命令白名单（新检查项过 grep 审计）；修复命令只进 suggestion 文本，diag 永不执行
2. 证据必附：evidence 字段机器生成（原始输出摘录），测试断言关键词命中
3. 模拟测试：tests/run_tests.ps1 全绿才许发版；FAIL 无 suggestion、证据缺关键词=测试挂

## 七、普及版（diag-lite）设计

目标：群友 Windows（Win10/11 自带 5.1）解压→双击"网络体检.bat"→黑框跑完→记事本自动弹报告。
- 启动器：ASCII 内容 .bat，`powershell -NoProfile -ExecutionPolicy Bypass -File engine\run.ps1 -OpenReport`（Bypass 绕群友机器默认 Restricted 策略）
- 兼容层：全部 ps1 UTF-8 BOM；`#Requires -Version 5.1`；解释器自引用；报告 txt+记事本
- 分发：zip（engine/checks/trees/bat/使用说明.txt）；使用说明含只读声明+杀软误报提示
- 状态：**已交付（1019 20:33）**——双版本 26/26 全绿；diag-lite-v0.1.zip 打包+真机全链验收通过（解压到中文空格路径→bat→报告弹出）；5.1 传参吃引号坑已用 -MockFile 文件传输根治

## 八、v0.2 蓝屏树设计（2026-10-19 设计稿；同晚施工单拍板，实现片当夜完成、真机验收三层全中）

素材实证（1019 本机只读取证）：3 次同码蓝屏 0x139（KERNEL_SECURITY_CHECK_FAILURE，09-04/10-10/10-13），Minidump 存活 1 个（10-13 的 3.2MB，其余被清但事件日志在）；41 事件多于 1001（多出=非蓝屏断电）；WHEA 10-04 一条；嫌疑驱动 nnndisfilter.sys（给梨加速器捆绑）运行中。

### 树层（bluescreen.yaml，三层取证聚合型，非网络树的线性推进）

| 层 | 检查项 | 层语义（verdict_fail 人话） |
|---|---|---|
| history 蓝屏史 | bs_event_history, bs_powerloss_distinction | 近 90 天有没有真蓝屏；41 无 1001 伴随=掉电/死机不是蓝屏，另查电源 |
| attribution 归因 | bs_code_frequency, bs_whea_hardware | 同码复发=慢性驱动/硬件病；WHEA 有记录=硬件层嫌疑 |
| evidence 现场 | bs_minidump_inventory, bs_suspect_drivers | dump 在不在（深度分析素材）；已知嫌疑驱动有没有在跑 |

断点语义与网络树不同：蓝屏树 FAIL≠"网络断了这种当前故障"，而是"发现蓝屏隐患"。engine 无需改（层+FAIL 机制通用）；报告标题按树名渲染即可。

### 检查项规格（6 项）

1. **bs_event_history**：`Get-WinEvent System/1001(WER-SystemErrorReporting)` 近 90 天。≥1 次→FAIL(有蓝屏史，附码+日期清单)；0 次→PASS；无权限→SKIP。正则提 `0x[0-9A-Fa-f]{8}` 码与 dump 路径。
2. **bs_code_frequency**：对 1001 码聚合。同码 ≥2 次→FAIL（慢性病，附码人话对照：0x139=内核安全检查失败/驱动栈损坏高发）；单次→PASS 附注。
3. **bs_powerloss_distinction**：41(Kernel-Power) 与 1001 时间配对（±2 分钟=同一次）。孤立 41 ≥2 次→FAIL（频繁掉电/死机：电源/过热/强制关机嫌疑，建议查电源与散热）；几乎无孤立 41→PASS。
4. **bs_whea_hardware**：`Get-WinEvent WHEA-Logger` 近 30 天。≥1 条→FAIL（硬件层事件：内存/CPU/PCIe 报错，建议 memtest）；0→PASS。
5. **bs_minidump_inventory**：枚举 C:\Windows\Minidump\*.dmp 与 MEMORY.DMP。1001 记录说有 dump 但文件缺失→PASS 附 WARN 备注（证据被清理）；无任何蓝屏史→SKIP。
6. **bs_suspect_drivers**：`Get-CimInstance Win32_SystemDriver` 对照嫌疑名单数据文件（checks/bs_suspects.json，代码数据分离可增长）。命中且 Running→FAIL（附名单里的人话+卸载建议）；无命中→PASS。v0.2 初始名单：nnndisfilter（给梨加速器捆绑 NDIS 过滤驱动，1013 蓝屏案主嫌疑）。

### 修复建议口径（只给文本）

卸载给梨加速器本体（控制面板/设置→应用）/ 更新或回滚网卡驱动 / 内存跑 memtest86+ / dump 送深度分析（v0.2 只枚举不解析，kd 无头分析等真样本积攒后升 v0.3+）。

### 预期真机验收读数

本机跑 bluescreen 树应命中：history FAIL（3 次蓝屏史）、attribution FAIL（0x139 ×3 同码）、evidence FAIL（nnndisfilter 运行中）——三层全中=设计贴合现实的证明。

**1019 实测兑现（非管理员账户，-Full）**：history FAIL（0x00000139×3：09-04/10-10/10-13；另 41 共 34 条=配对 5+孤立 29，掉电压迫判定 FAIL 比 design 预期多中一项）+attribution FAIL（0x139×3 慢性病+WHEA 10-04 英文消息一条）+evidence 半中（dump 3196KB 存活 PASS 附清单+nnndisfilter Running FAIL）。

### 实现拍板记录（2026-10-19 晚，用户逐项拍板，施工单执行中上浮）

| # | 决策点 | 拍板结果 |
|---|---|---|
| 6 | engine 报告头硬编码（施工单 0 只写 verdict_title，另有 4 处网络树专属文案） | 按树渲染+升 v0.2：树可选 `report_name`（大标题）、「N 层全通」动态层数、蓝屏树证据链副标=聚合取证、版本号 v0.1→v0.2；network 树 yaml 不动、报告文案除版本号外逐字不变（依据 design 第八节"报告标题按树名渲染即可"） |
| 7 | lite 蓝屏入口（施工单 9"bat 无需改" vs 路书第 3 步"双击出蓝屏层报告"验收矛盾） | 新增第二个启动器「蓝屏体检.bat」（ASCII+CRLF，-TreeName bluescreen -Full -OpenReport），原网络 bat 一字不动 |
| 8 | bs_code_frequency 层归属（design 表格=attribution vs 施工单条目头=history） | 归 attribution（design 表格+design 预期读数+施工单第 7 节"照表格"三处互证；条目头判笔误） |

## 九、版本与切片

- 切片=一个可验收单元（框架第一节）；每切片走：设计（改本档）→拍板→实现→模拟测试全绿→真机验收→CHANGELOG 记账
- v0.1 切片验收记录：26/26 绿（pwsh7）+真机断点报告（双默认网关同跃点冲突，reports/diag-network-20261019-*.md/.txt）+4 拍板点全过
- **知识底盘审计片（1019 晚完成）**：对微软官方文档逐项校准（详见 知识来源.md）——2 处建议文案补官方口径（网关禁 ping 交叉验证/ICMP 拦截说明）、1 处判定增强（网关跨网段=官方故障模式，27/27 双版本绿）、蓝屏码书 `checks/bugcheck_codes.json`（29 高频码，官方总表取材指针制）+嫌疑名单 `checks/bs_suspects.json`（实证收录制）落盘
- 下一片候选：v0.2 蓝屏实现片**已于 1019 当夜完成**（施工单 0-10 全条目，46/46 双版本绿+真机三层全中+diag-lite-v0.2.zip 双入口彩排毕）；v0.2.1 HTML 报告片**已于 1020 完成**（渲染层 txt→HTML 单文件：内嵌 CSS 零 JS、`-OpenReport` 走默认浏览器、证据链 `<details>` 原生折叠断点层默认展开、修复建议按检查项分段、evidence/suggestion 全量转义；**stdout 文本逐字不动=测试基线锚**，判定/检查项/树/码书/名单零改动，46/46 不动一兵；拍板 5 条与验收明细=CHANGELOG 第五切片）；**v0.3 硬件树设计片 1020 毕**（第十节；1019 下放制 AI 终审两补=SMART 非管理员 Access denied→SKIP/热区 ACPI 假值→SKIP，阈值定线电池 40%·盘温 60℃·热区 75℃·Wear 10%）；**v0.3 实现片 1020 毕**（66/66 双版本绿〔59 单测+7 场景，FAIL evidence 补人话结论行〕+真机 memory_board 双 FAIL 与蓝屏树证据一致+diag-lite-v0.3.zip 三入口实跑毕；明细=CHANGELOG 第六切片）；**v0.4 性能树设计片 1020 毕**（第十一节；无新样本闸已标注，7 检查项+三层聚合，1020 用户当轮确认拍板）；**v0.4 性能实现片 1020 毕**（101/101 双版本绿〔92 单测+9 场景〕+真机 startup 层 93 条服务超时真命中+diag-lite-v0.4.zip 四入口实跑毕；实测读数与三处实况坑修记=第十一节+CHANGELOG 第七切片）；**v0.5 驱动树设计片 1020 毕**（第十二节；素材口径=样本簿无驱动域新样本已标注，三层聚合+新 6 检查项+跨树复用 1，用户当轮拍板）；**v0.5 驱动实现片 1020 毕**（130/130 双版本绿〔118 单测+12 场景〕+engine 多树 all+中文菜单+reports 50 份裁剪三拍板落地+真机 stack 层真命中断点（34 家+4 层过滤带给梨标注）+suspect 层 nnndisfilter 必中与蓝屏树证据一致+单树 stdout/HTML 与 v0.4 基线锚逐字一致+diag-lite-v0.5.zip 六入口实跑毕；明细=CHANGELOG 第八切片）；**v0.6 图形界面设计片 1020 毕**（第十三节：WinForms 壳+engine 进程隔离，判定/检查项/树零改动，窗体规格 F1-F8 逐条；同晚用户拍板 9-11=B 案数据通路·bat 一闪·深色主题，待实现片）；**v0.6 图形界面实现片 1020 毕**（135/135 双版本绿〔130 既有零改动+5 B 案新增〕+真机手测十条过九条半〔150% DPI 负例无高 DPI 真机挂账〕+diag-lite-v0.6.zip 七入口彩排毕；明细=CHANGELOG 第九切片）；发群收样本已挂起（1019 用户拍板"有成品了再说"，解挂条件见路书第 0 步）
- **知识文件三件套（改判定必同步）**：知识来源.md（口径账本）/ bugcheck_codes.json（码书）/ bs_suspects.json（嫌疑名单）

## 十、v0.3 硬件树设计（2026-10-20 设计稿；同日按 1019 下放制 AI 自我迭代终审毕=视同拍板通过，待实现片）

树型=**三层聚合取证型**（同蓝屏树先例：FAIL=「发现硬件隐患」非当前断故障；engine 零改动，报告标题走 v0.2 拍板 6 的 report_name 机制）。素材口径=无新真实样本（样本簿无硬件域条目），凭微软官方命令域实证设计（路书 v0.3 闸：无新样本需标注）。

### 树层（hardware.yaml）

| 层 | 检查项 | 层语义（verdict_fail 人话） |
|---|---|---|
| storage 存储 | hw_disk_health, hw_smart_predict | 磁盘健康+SMART 预警——硬件里最常见的死件；FAIL=先备份数据再谈别的 |
| power_thermal 供电散热 | hw_battery_wear, hw_thermal | 电池损耗/过热——意外断电、降频死机的根 |
| memory_board 内存主板 | hw_memdiag_history, bs_whea_hardware（**跨树复用**，检查项零改动） | 内存硬件报错史+WHEA 机器检查——无解死机/蓝屏的硬件侧证据 |

### 检查项规格（新 5 项，命令全只读、PS 5.1 兼容；完整 JSON 样例=施工单阶段补）

1. **hw_disk_health**（storage）：`Get-PhysicalDisk`（FriendlyName/MediaType/HealthStatus/OperationalStatus）。判定：任一盘 HealthStatus≠Healthy→FAIL（Warning=坏块/磨损征兆，人话=备份数据+观察；Unhealthy=濒死，人话=立即备份换盘）；全 Healthy→PASS 附盘清单；cmdlet 不可用或无盘→SKIP。负例：mock HealthStatus=Warning→FAIL。
2. **hw_smart_predict**（storage）：`Get-StorageReliabilityCounter`（Wear/ReadErrorsUncorrected/Temperature）＋`root\wmi MSStorageDriver_FailurePredictStatus`（PredictFailure）。判定：PredictFailure=true / ReadErrorsUncorrected>0 / SSD Wear>10% / 盘温>60℃ 任一→FAIL（附人话：哪块盘哪个指标在报警）；全部计数器 null→SKIP（家用盘常见=诚实缺口，不装懂）；**root\wmi SMART 类非管理员常 Access denied→SKIP 附注「管理员身份可复核」**（终审补：lite 用户多非管理员，禁把权限问题误读成健康）；否则 PASS。负例：mock Wear=25→FAIL、mock PredictFailure=true→FAIL、mock Access denied→SKIP。
3. **hw_battery_wear**（power_thermal）：`Win32_Battery` ＋ `root\wmi BatteryStaticData(DesignedCapacity)/BatteryFullChargedCapacity`。判定：损耗=(设计−满充)/设计 ≥40%→FAIL（重度损耗：续航崩/鼓包风险，建议换电池，附损耗百分比）；<40%→PASS 附损耗数；无电池（台式）→SKIP。负例：mock 损耗 55%→FAIL。
4. **hw_thermal**（power_thermal）：`root\wmi MSAcpi_ThermalZoneTemperature`（0.1K，转℃=/10−273.15）。判定：任一热区 >75℃→FAIL（过热：清灰/风扇/硅脂，附各区读数）；全 ≤75℃→PASS 附读数；无热区暴露（台式常见）→SKIP；**读数无效（≤0℃ 或 >120℃=ACPI 假值机型）→SKIP 附注「热区读数不可信」**（终审补）。负例：mock 85℃→FAIL。
5. **hw_memdiag_history**（memory_board）：`Get-WinEvent Microsoft-Windows-MemoryDiagnostics-Results`（1101=检测到硬件问题/1102=无问题）。判定：有 1101→FAIL（Windows 内存诊断已报硬件问题：跑 memtest86+ 复核/送修）；仅 1102→PASS；无任何事件（从未跑过系统内存诊断，常态）→SKIP。负例：mock 1101→FAIL。

### 修复建议口径（只给文本，铁律 1）

备份重要数据→（换盘/换电池/清灰换风扇各对应）；memtest86+ 复核内存；硬件怀疑高=送修，**工具自身对硬件零写操作**。

### 实现注意（施工单阶段项，本片不决）

lite 增第三个启动器「硬件体检.bat」（同 v0.2 拍板 7 模式：ASCII+CRLF，-TreeName hardware -Full -OpenReport），原两 bat 不动；复用 bs_whea_hardware 时树 yaml 只挂名不改 checks；SKIP 语义在报告里显式标「计数器不暴露，非无问题」（防 SKIP 被读成 PASS）。

### 预期真机验收读数（本机）

storage：盘 Healthy→PASS（SMART 计数器若 null→该子项 SKIP 半态）；power_thermal：电池/热区视机型（无则 SKIP）；memory_board：**WHEA 10-04 那条在蓝屏树已实证→复用项 FAIL 必中**+memdiag 大概率无事件 SKIP。验收判据=至少 memory_board 层命中且与蓝屏树证据一致，其余层读数与机型常识相符即算设计贴合。

## 十一、v0.4 性能树设计（2026-10-20 设计稿；1020 用户当轮确认拍板，同日实现片完成）

树型=**三层聚合取证型**（同蓝屏/硬件先例：FAIL=「发现性能瓶颈/隐患」非系统断故障；engine 零改动，报告走 v0.2 拍板 6 的 report_name 机制，lite 入口带 -Full 同拍板 7 模式）。素材口径=**无新真实样本**（样本簿 1020 核=仅 1019 网络域一条，无性能域条目），凭微软官方命令域实证设计（1019 闸拍板：无新样本标注继续，禁发群）。

### 树层（performance.yaml）

| 层 | 检查项 | 层语义（verdict_fail 人话） |
|---|---|---|
| boot 开机慢 | pf_boot_duration, pf_boot_degradation_events | 开机慢不是玄学：Windows 官方日志记着每次开机时长+拖后腿点名名单 |
| startup 启动负担 | pf_startup_items, pf_service_timeouts | 自启清单+服务超时史——开机慢的常驻侧证据 |
| runtime 卡顿现场 | pf_disk_space, pf_memory_pressure, pf_disk_saturation | 磁盘水位/内存压力/磁盘 IO 堵塞——卡顿三现场 |

verdict_title=性能瓶颈结论（同蓝屏「隐患结论」先例）；verdict_all_pass=未发现明显性能瓶颈；体感仍卡的方向=具体应用自身/浏览器多标签/杀毒扫描进行中，隔几天再体检看趋势。

### 检查项规格（新 7 项，全只读、PS 5.1 兼容；样例=mock 构造形态，实现片以真机样张校准）

1. **pf_boot_duration**（boot）
- 命令：`Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational'` 过滤 EventID=100（Windows 每次开机自动记一条，EventData 含 BootTime 毫秒；慢启动时 Level 由 Windows 按官方内部阈值自动升 Warning/Critical），取近 5 次
- 判定：近 5 次 Warning/Critical ≥2→FAIL（微软自己的慢启动判定，附每次秒数+日期清单）；无 Warning 但均值 >60000ms→FAIL（60s=工程线）；均值 30000-60000ms→PASS 附注「偏慢，配合启动负担层看」；<30000ms→PASS；日志不存在/无 100 事件→SKIP
- 样例（mock 构造）：`{ "name": "pf_boot_duration", "status": "FAIL", "evidence": "[Diagnostics-Performance id=100 近5次]\n10-20 Warning BootTime=95300ms(95秒)\n10-19 Warning BootTime=88210ms(88秒)\n10-18 Information 41200ms\n10-17 Information 38900ms\n10-16 Information 44500ms", "suggestion": "近 5 次开机 2 次被 Windows 自动标记慢启动…【修复命令，请自己执行】无（任务管理器→启动应用 手动禁用，操作文本另附）", "detail": { "samples": 5, "warnCount": 2, "avgMs": 61622 } }`
- 负例：mock 2×Warning→FAIL；mock 全 Information 均值 75s→FAIL；mock 无 100 事件→SKIP

2. **pf_boot_degradation_events**（boot）
- 命令：同日志近 30 天 EventID=101/103（101=应用拖慢启动、103=服务拖慢启动，微软点名事件，消息自带文件/服务名+耗时毫秒），Level≥Warning
- 判定：≥3 条→FAIL（附点名 top5：谁、拖了多少毫秒）；1-2 条→PASS 附注清单；0 条→PASS；日志不可读→SKIP。真机若实拍见 102/106/108/110 同类降级事件→实现片扩收（只收实拍确认过的 ID，防凭记忆编造）
- 样例（mock 构造）：`{ "name": "pf_boot_degradation_events", "status": "FAIL", "evidence": "[Diagnostics-Performance id=101/103 近30天 Warning+]\n101 拖慢启动: WeChat.exe 3200ms\n101 拖慢启动: 360Safe.exe 2800ms\n103 拖慢启动: 服务 XxxGuard 4100ms", "suggestion": "近 30 天被 Windows 点名拖慢开机 3 次…对上号的自启按任务管理器禁用…【修复命令，请自己执行】无（手动禁用）", "detail": { "count": 3, "top": [ { "id": 101, "who": "WeChat.exe", "ms": 3200 } ] } }`
- 负例：mock 3×101→FAIL；mock 1×101→PASS 附注；mock 0 条→PASS

3. **pf_startup_items**（startup）
- 命令：`Get-CimInstance Win32_StartupCommand`（Name/Command/Location/User——官方 WMI 类一次拉全注册表 Run 键+启动文件夹）
- 判定：命中嫌疑名单 checks/pf_suspects.json（实证收录制同 bs_suspects 先例，v0.4 初始空名单）→FAIL 附人话；总数 >20→FAIL（启动负担过重，附全清单+识别指引）；≤20→PASS 附清单+人话（逐个识别，不认识的不急着自己动，对照任务管理器启动页）；查询失败→SKIP
- 注：该类不反映任务管理器「已禁用」状态（StartupApproved 二进制无官方文档口径，不解读）——报告注明以任务管理器→启动应用页实际状态为准
- 样例（mock 构造）：`{ "name": "pf_startup_items", "status": "PASS", "evidence": "[Win32_StartupCommand] 共 12 项\n[HKCU Run] WeChat\n[HKLm Run] SecurityGuard\n[Startup 文件夹] OneDrive", "suggestion": "", "detail": { "total": 12, "locations": { "HKCU Run": 5, "HKLM Run": 6, "Startup": 1 } } }`
- 负例：mock 25 项→FAIL；mock 命中名单→FAIL；mock 8 项→PASS；mock 类查询失败→SKIP

4. **pf_service_timeouts**（startup）
- 命令：`Get-WinEvent -LogName System`，Provider=Service Control Manager，EventID=7000/7009/7011 近 30 天（7000=服务启动失败、7009=等待连接超时、7011=事务响应超时；消息自带 30000 毫秒口径与服务名——1020 校准：默认超时=30 秒，勿写 15 秒）
- 判定：三类合计 ≥3→FAIL（服务启动/响应迟钝=开机慢+卡顿双证据，附 top 服务名+各自条数）；1-2 条→PASS 附注；0→PASS；System 日志不可读→SKIP
- 样例（mock 构造）：`{ "name": "pf_service_timeouts", "status": "FAIL", "evidence": "[System 服务控制管理器 7000/7009/7011 近30天] 共 5 条\n7011 等待 XxxGuard 服务事务响应超时(30000 毫秒) ×3\n7000 XxxSvc 服务启动失败 ×2", "suggestion": "多个服务启动失败/响应超时…多为安全软件全家桶/驱动类服务…【修复命令，请自己执行】无（按服务名卸载对应软件）", "detail": { "total": 5, "top": [ { "id": 7011, "service": "XxxGuard", "count": 3 } ] } }`
- 负例：mock 5×7011→FAIL；mock 1×7000→PASS 附注；mock 0 条→PASS

5. **pf_disk_space**（runtime）
- 命令：`Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"`（Size/FreeSpace；系统盘按 %SystemDrive% 匹配）
- 判定：系统盘剩余 <10% 或 <20GB 任一→FAIL（磁盘将满=SSD 掉速+更新失败元凶，附全盘水位表；建议=存储感知/设置→系统→存储 清理操作文本）；系统盘 10-15%→PASS 附注「偏紧」；非系统盘 <10% 且 <20GB→PASS 附 WARN 备注；其余→PASS；无本地盘→SKIP
- 定线：10%=SSD 高位掉速工程线；20GB=更新预留工程线（微软 Win11 要求页最低 64GB 存储，无官方「保留多少」明文——工程线同 v0.3 电池/温度先例）
- 样例（mock 构造）：`{ "name": "pf_disk_space", "status": "FAIL", "evidence": "[Win32_LogicalDisk DriveType=3]\nC: 总 237GB 剩 11.2GB (4.7%) ← 系统盘\nD: 总 931GB 剩 512GB (55%)", "suggestion": "系统盘只剩 4.7%…磁盘将满会让固态掉速、系统更新失败…【修复命令，请自己执行】无（设置→系统→存储→清理建议 手动清理）", "detail": { "disks": [ { "drive": "C:", "freeGB": 11.2, "pct": 4.7, "system": true } ] } }`
- 负例：mock 系统盘 5%→FAIL；mock 系统盘剩 18GB（比例够但绝对值不够）→FAIL；mock 全盘充足→PASS；mock 无本地盘→SKIP

6. **pf_memory_pressure**（runtime）
- 命令：`Get-CimInstance Win32_OperatingSystem`（TotalVisibleMemorySize/TotalVirtualMemorySize/FreeVirtualMemory）+ `Win32_ComputerSystem`（TotalPhysicalMemory）
- 判定：物理 <4GB→FAIL（低于 Win11 官方最低内存要求，2026 年日常使用必卡）；commit 率=(TotalVirtualMemorySize−FreeVirtualMemory)/TotalVirtualMemorySize >90%→FAIL（内存+页面文件双吃紧=卡顿进行时）；4-8GB 且 commit≤90%→PASS 附注「规格贴最低线，多开必卡，加内存条是根治方向」；≥8GB→PASS 附容量+commit 率；查询失败→SKIP
- 设计要点：不用「空闲物理内存低」判 FAIL（Windows 拿空闲内存做缓存=正常设计，空闲低≠故障）
- 样例（mock 构造）：`{ "name": "pf_memory_pressure", "status": "FAIL", "evidence": "[Win32_ComputerSystem/Win32_OperatingSystem]\n物理内存 3.9GB (Win11 官方最低线 4GB)\ncommit 28.5/32GB (89%)", "suggestion": "内存 3.9GB 低于 Windows 11 官方最低要求…浏览器多开必卡…根治=加内存条；过渡=少开程序…【修复命令，请自己执行】无（硬件升级）", "detail": { "physicalGB": 3.9, "commitPct": 89 } }`
- 负例：mock 2GB→FAIL；mock 16GB+commit 95%→FAIL；mock 16GB+commit 40%→PASS；mock 查询失败→SKIP

7. **pf_disk_saturation**（runtime）
- 命令：`Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk`（排除 _Total 实例）取 CurrentDiskQueueLength/AvgDiskSecPerTransfer；**间隔 2 秒双采样**（单次快照误报高——瞬时 IO 高峰人人有）
- 判定：两次采样系统盘队列均 >2→FAIL（磁盘 IO 堵塞=「磁盘 100%」卡顿现场，附两次采样值+AvgDiskSecPerTransfer 换算毫秒读数）；仅一次 >2→PASS 附注「瞬时高峰，未见持续」；均 ≤2→PASS 附队列值；计数器类查询失败/空→SKIP（精简系统常见，诚实缺口）
- 定线：队列 >2=Windows 性能监视经典工程线（微软无单一明文阈值页）；AvgDiskSecPerTransfer 官方 SQL I/O 排障文以 15ms 为延迟提示线→本工具只附读数不单独立 FAIL 判据。工程定线先例同 v0.3（电池 40%/盘温 60℃/热区 75℃）
- 样例（mock 构造）：`{ "name": "pf_disk_saturation", "status": "FAIL", "evidence": "[Win32_PerfFormattedData_PerfDisk_PhysicalDisk 双采样(间隔2s)]\n第1次 C: 队列=5 平均响应=38ms\n第2次 C: 队列=6 平均响应=41ms", "suggestion": "系统盘 IO 持续堵塞（队列 5/6）…常见元凶=磁盘将满/杀毒全盘扫描/机械盘老化…配合磁盘水位与启动负担层证据定位…【修复命令，请自己执行】无", "detail": { "queue": [5, 6], "avgSec": [0.038, 0.041] } }`
- 负例：mock 双采样队列 5/6→FAIL；mock 4/1→PASS 附注；mock 均 ≤2→PASS；mock 类查询空→SKIP

### 修复建议口径（只给文本，铁律 1）

任务管理器→启动应用 手动禁用（操作路径文本）／设置→系统→存储→清理建议+存储感知／加内存条（4GB 线机器）／按点名服务名卸载对应全家桶软件／**工具自身零写操作、零禁用动作**。

### 实现注意（施工单阶段项，本片不决）

lite 第四启动器「性能体检.bat」（同拍板 7 模式：ASCII+CRLF，-TreeName performance -Full -OpenReport，原三 bat 不动）；pf_suspects.json 空名单起步+损坏→SKIP（同 bs_suspects 完工问 1 先例）；SKIP 反话术显式标「数据不可用/计数器不暴露，非无问题」；engine 版本随片升 v0.4（1020 惯例）；知识来源.md 补性能树校准表（含 7011=30s 校准、工程线三条标注、Win11 4GB/64GB 官方线）。

### 预期真机验收读数（本机）

boot 层：出真实开机时长清单即算贴合（本机开机时长未知，Warning 命中与否以实跑为准，不预定罪）；startup 层：给梨加速器在装（1019 实证）→若挂自启则与蓝屏树 nnndisfilter 证据交叉一致；runtime 层：本机 NVMe 队列应低（PASS），水位/内存以实跑为准。验收判据=全树零崩溃+每检查项产出真读数或诚实 SKIP+若 startup 命中给梨则与既有证据链一致。

**1020 实测兑现（非管理员账户，-Full，EXIT=2）**：startup 层真命中=pf_service_timeouts FAIL 93 条（7000 AndrowsSvr ×63+Steam Client Service 7000×15/7009×15）+pf_startup_items PASS 12 项真清单（Steam/OneDrive/Epic/quark 等；给梨不在自启清单——其为驱动服务非自启项，与蓝屏树 nnndisfilter 驱动证据不矛盾）；runtime 层全 PASS 真读数（6 盘水位/15.8GB commit 44%/队列 0 双采样）；boot 层诚实半态（Diagnostics-Performance 日志本机无 id=100 事件→no-data SKIP；101/103 近 30 天 0 条→PASS）。实拍未见 102/106/108/110→未扩收（铁则遵守）。实现片修掉三处实况坑：中文无事件消息匹配/7009 服务名参数位错位（自适应提取）/性能日志权限提示（细节=CHANGELOG 第七切片）。101/101 双版本绿+diag-lite-v0.4.zip 四入口彩排毕。

## 十二、v0.5 驱动树设计（2026-10-20 设计稿；同日用户拍板+实现片完成）

树型=**三层聚合取证型**（同蓝屏/硬件/性能先例：FAIL=「发现驱动域隐患」非当前断故障；engine 零改动，报告走 v0.2 拍板 6 的 report_name 机制，lite 入口带 -Full 同拍板 7 模式）。素材口径=**无新真实样本**（样本簿 1020 核=仅 1019 网络域一条，无驱动域条目），凭微软官方命令域实证设计（1019 闸拍板：无新样本标注继续，禁发群）；既有驱动域实证锚=1019 蓝屏案 nnndisfilter.sys（给梨加速器捆绑）运行中+0x139×3——蓝屏树取证所得，作本树交叉验收锚、不冒充新样本。本片对齐框架第七节路线图 v0.5 钦点方向（设备管理器错误码 ConfigManagerErrorCode 解读=dv_device_errors 项）。

### 树层（drivers.yaml）

| 层 | 检查项 | 层语义（verdict_fail 人话） |
|---|---|---|
| integrity 签名年代 | dv_driver_signature, dv_driver_age | 驱动来路正不正：无签名/损坏签名/古董驱动在跑——蓝屏高发源 |
| stack 叠加体量 | dv_thirdparty_inventory, dv_network_filters | 第三方驱动叠了多厚：全家桶/加速器过滤链——断网卡顿双隐患 |
| suspect 点名证据 | dv_device_errors, dv_driver_load_failures, bs_suspect_drivers（**跨树复用**，检查项零改动） | 系统自己点名的证据：设备黄三角/驱动加载失败/已知嫌疑名单 |

verdict_title=驱动隐患结论（同聚合树先例）；verdict_all_pass=未发现驱动域隐患，体感仍异常的方向=设备管理器人工复核（操作路径文本附报告尾）。

### 检查项规格（新 6 项+复用 1 项，全只读、PS 5.1 兼容；样例=mock 构造形态，实现片以真机样张校准）

1. **dv_driver_signature**（integrity）
- 命令：`Get-CimInstance Win32_SystemDriver`（State=Running，PathName 定位 .sys）两段式：`(Get-Item).VersionInfo.CompanyName` 元数据初筛（读文件属性，快）→ 非微软子集逐个 `Get-AuthenticodeSignature` 验签（慢但子集小）；微软自带驱动跳过验签（数量大且必过=性能护栏，60 秒单项超时兜底走引擎既有机制）
- 判定：在跑驱动 NotSigned 或验签失败（HashMismatch/UnknownError）→FAIL（无名氏驱动在内核运行=蓝屏高发源，附点名：驱动名+路径+签名状态）；非微软但全 Valid→PASS 附公司聚合清单（NVIDIA/Realtek 等正规第三方=常态不报）；枚举失败→SKIP
- 设计要点：CompanyName 文件元数据≠Authenticode 法律签名——初筛只分「微软/待验」两桶，FAIL 只由验签结果定
- 样例（mock 构造）：`{ "name": "dv_driver_signature", "status": "FAIL", "evidence": "[Win32_SystemDriver Running→非微软子集 Get-AuthenticodeSignature]\n共验 23 个非微软在跑驱动，21 个 Valid\nNotSigned: nnndisfilter.sys (C:\\Windows\\System32\\drivers\\)\nHashMismatch: xxgamedrv.sys (C:\\Windows\\System32\\drivers\\)", "suggestion": "有 2 个来路不明的驱动正在内核运行（未签名/签名损坏）=蓝屏高发源…按文件名搜所属软件卸载（nnndisfilter=给梨加速器捆绑，蓝屏树已实证）…【修复命令，请自己执行】无（设置→应用 卸载对应软件）", "detail": { "checked": 23, "valid": 21, "bad": [ { "file": "nnndisfilter.sys", "sig": "NotSigned" } ] } }`
- 负例：mock NotSigned→FAIL；mock HashMismatch→FAIL；mock 非微软全 Valid→PASS 附聚合；mock 枚举失败→SKIP

2. **dv_driver_age**（integrity）
- 命令：同源 `Win32_SystemDriver`（Running）→ .sys 文件 LastWriteTime 作驱动年代代理（PS 5.1 VersionInfo 不暴露 DriverDate 官方字段，文件出厂时间=稳定代理口径；Win32_PnPSignedDriver.DriverDate 有官方字段但枚举慢且非 PNP 服务驱动缺——主路径文件时间，交叉参照留实现片议）
- 判定：在跑驱动文件日期 <2015-07-29（Win10 RTM 官方发布日=官方锚）计数：≥5→FAIL（古董驱动队：Win7 时代驱动跑在 2026 年系统=兼容性地雷，附 top 清单带年代）；1-4→PASS 附注点名；0→PASS；枚举失败→SKIP。计数线 5=工程线（无官方明文，先例同 v0.3 电池 40%/盘温 60℃）
- 样例（mock 构造）：`{ "name": "dv_driver_age", "status": "FAIL", "evidence": "[Win32_SystemDriver Running .sys LastWriteTime<2015-07-29]\n共 6 个古董驱动在跑:\n2012-03-14 Rt630x64.sys (Realtek 网卡)\n2013-08-02 nnndisfilter.sys\n2014-01-20 xxguard.sys …", "suggestion": "6 个 Win7 时代驱动还在 2026 年系统上跑=兼容性地雷…网卡/声卡类走厂商官网或 Windows Update 更新…【修复命令，请自己执行】无（设备管理器→对应设备→更新驱动程序）", "detail": { "old": 6, "top": [ { "file": "Rt630x64.sys", "date": "2012-03-14" } ] } }`
- 负例：mock 7 个 2013 年文件→FAIL；mock 2 个 2014 年→PASS 附注；mock 全 2019 后→PASS；mock 枚举失败→SKIP

3. **dv_thirdparty_inventory**（stack）
- 命令：`Get-CimInstance Win32_SystemDriver` → VersionInfo.CompanyName 公司聚合（Microsoft 归一桶，其余按公司计数，只读元数据不验签=快）
- 判定：非微软运行中驱动 >30→FAIL（第三方体量过大：全家桶/加速器/虚拟设备遗留叠加，附公司聚合表+人话）；15-30→PASS 附注「偏厚，卸载软件时对照」；≤15→PASS 附聚合；枚举失败→SKIP。30/15=工程线（无官方明文，先例同 v0.3/v0.4）
- 注：与 dv_driver_signature 同取证源不同判定（CompanyName 初筛两边共享、验签只 signature 做）；实现片可议缓存共享，判定互不依赖
- 样例（mock 构造）：`{ "name": "dv_thirdparty_inventory", "status": "FAIL", "evidence": "[Win32_SystemDriver Running→VersionInfo.CompanyName 聚合]\n非微软在跑驱动 35 个:\nNVIDIA ×8\n360 ×6\n给梨 ×3\nVMware ×4 …", "suggestion": "第三方驱动体量过大（35 个）…按公司名对号卸载对应全家桶/加速器/卸载残留虚拟设备…【修复命令，请自己执行】无（设置→应用 对照卸载）", "detail": { "thirdParty": 35, "companies": [ { "name": "NVIDIA", "count": 8 } ] } }`
- 负例：mock 35 个非微软→FAIL；mock 20 个→PASS 附注；mock 8 个→PASS 附聚合；mock 枚举失败→SKIP

4. **dv_network_filters**（stack）
- 命令：`Get-NetAdapterBinding -IncludeHidden`（NetAdapter 模块 Win8+ 自带，5.1 兼容）取 Enabled=$true 且 ComponentID 非 `ms_` 前缀的第三方绑定，按组件去重计数（同一过滤驱动绑 3 张网卡≠叠 3 层）
- 判定：去重后第三方启用绑定 ≥3→FAIL（网络栈过滤链叠太厚：加速器/杀软/代理各挂一层——断网+蓝屏双隐患，附绑定点名）；1-2→PASS 附注点名（给梨类单独人话）；0→PASS；cmdlet 不可用/无适配器→SKIP
- 交叉锚：给梨 nnndisfilter 属 NDIS 过滤驱动，在装则必现于绑定链→与蓝屏树证据一致
- 样例（mock 构造）：`{ "name": "dv_network_filters", "status": "FAIL", "evidence": "[Get-NetAdapterBinding -IncludeHidden Enabled 第三方绑定去重]\n共 4 层第三方过滤:\nnnndisfilter（给梨加速器 NDIS 过滤）\n360Firewall（杀软网络过滤）\nxxproxy（代理过滤）\nvNanoAdapter（虚拟网卡）", "suggestion": "网络栈上叠了 4 层第三方过滤=断网与蓝屏双隐患…卸载对应软件…【修复命令，请自己执行】无（卸载对应加速器/杀软）", "detail": { "filters": 4, "items": [ { "id": "nnndisfilter", "enabled": true } ] } }`
- 负例：mock 4 层第三方→FAIL；mock 1 层（给梨）→PASS 附注点名；mock 0 层→PASS；mock cmdlet 缺失→SKIP

5. **dv_device_errors**（suspect，框架第七节路线图 v0.5 钦点项）
- 命令：`Get-CimInstance Win32_PnPEntity`（Name/ConfigManagerErrorCode/DeviceID）；ErrorCode≠0=设备管理器带黄三角设备
- 判定：存在 ErrorCode∉{22,45} 的非 0 码→FAIL（22=已被禁用、45=上次会话的残留记录=非故障态；其余码表全算硬故障，附设备名+码人话对照：28=未安装驱动、43=Windows 已因故障停用它、10=无法启动、12=资源冲突、31=无法正常工作；高频码人话内置，未收录码显码号+「详见设备管理器属性页」）；仅软码→PASS 附注；全 0→PASS 附设备总数；查询失败→SKIP
- 码表口径：微软官方 Device Manager error codes 文档；知识来源.md 补校准行
- 样例（mock 构造）：`{ "name": "dv_device_errors", "status": "FAIL", "evidence": "[Win32_PnPEntity ConfigManagerErrorCode≠0]\nCode 28: 未知 USB 设备（未安装驱动）\nCode 43: USB 大容量存储设备（Windows 已因故障停用）", "suggestion": "2 台设备在报错：Code28=驱动没装（重插/装驱动）；Code43=设备自报故障（换 USB 口试/换线）…【修复命令，请自己执行】无（设备管理器→右键→更新驱动程序或卸载后重插）", "detail": { "errors": 2, "items": [ { "name": "未知 USB 设备", "code": 28 } ] } }`
- 负例：mock 一台 Code28+一台 Code43→FAIL；mock 仅 Code22→PASS 附注；mock 全 0→PASS；mock 查询失败→SKIP

6. **dv_driver_load_failures**（suspect）
- 命令：`Get-WinEvent -LogName System` Provider=Kernel-PnP EventID=219 近 30 天 Level≥Warning（219=驱动加载失败，消息自带设备实例路径）
- 判定：≥3 条→FAIL（驱动反复加载失败：卸载残留/驱动文件损坏，附点名 top5）；1-2 条→PASS 附注（插拔设备瞬时场景常见，不冤枉）；0 条→PASS；日志不可读→SKIP
- 语境护栏：同一设备实例路径出现 ≥2 次才单独点名（瞬时插拔类不点名）
- 样例（mock 构造）：`{ "name": "dv_driver_load_failures", "status": "FAIL", "evidence": "[System Kernel-PnP id=219 近30天 Warning+]\n共 4 条:\nUSB\\VID_1234 加载失败 ×3（反复）\nROOT\\XXSYS ×1", "suggestion": "有驱动反复加载失败=卸载残留或文件损坏…【修复命令，请自己执行】无（设备管理器→查看→显示隐藏的设备→卸载灰色残留项）", "detail": { "count": 4, "top": [ { "path": "USB\\VID_1234", "times": 3 } ] } }`
- 负例：mock 同路径 4×219→FAIL；mock 1×219→PASS 附注；mock 0 条→PASS；mock 日志不可读→SKIP

7. **bs_suspect_drivers**（suspect，跨树复用）
- 检查项零改动挂名（先例=v0.3 硬件树复用 bs_whea_hardware）；bs_suspects.json 实证收录制名单随本树继续生长；规格见第八节第 6 条，不重抄

### 修复建议口径（只给文本，铁律 1）

设备管理器（devmgmt.msc）→带黄三角设备右键「更新驱动程序/卸载设备后重插」（操作路径文本）／按点名公司名卸载对应全家桶软件（给梨先例）／驱动更新走厂商官网或 Windows Update→可选更新／**工具自身零写操作、零卸载动作**。

### 实现注意（施工单阶段项，本片不决）

lite 第五启动器「驱动体检.bat」（同拍板 7 模式：ASCII+CRLF，-TreeName drivers -Full -OpenReport，原四 bat 不动）；**统一入口已拍板（1020 用户当轮）**：五 bat 不动＋新增「全面体检.bat」总入口（菜单选树/连跑五树出合并报告，原四 bat 零改动）——挂账①收口，实现片纳入；PathName 前缀清洗（`\??\` 前缀与相对路径两种形态）；两段式验签的性能护栏（微软桶跳过+非微软子集验签）；engine 版本随片升 v0.5（惯例）；知识来源.md 补驱动树校准表（ConfigManagerErrorCode 官方码表/219 事件/Get-NetAdapterBinding 前缀口径/Authenticode 签名状态语义）。**reports/ 保留策略必做**（50 份上限口径已定，实现片施工单纳入——1020 v0.4 自问"下片必做"线）。

### 预期真机验收读数（本机）

suspect 层：bs_suspect_drivers FAIL（nnndisfilter Running，1019 实证）**必中**；dv_device_errors 与 219 以实跑为准不预定罪。stack 层：dv_network_filters 若给梨绑定在→点名与蓝屏树证据交叉一致；公司聚合表应见 NVIDIA/Realtek 类正规第三方（PASS 常态读数）。integrity 层：品牌机正规驱动全 Valid→PASS 附清单为常态；古董驱动以实跑为准。验收判据=全树零崩溃+每检查项产出真读数或诚实 SKIP+suspect 层与既有证据链一致。

**1020 实测兑现（非管理员账户，-Full，EXIT=2）**：suspect 层 bs_suspect_drivers FAIL 必中兑现（nnndisfilter Running）+dv_driver_load_failures 真命中 130 条（PCI VEN_8086/ROOT\DISPLAY 各 ×65「反复」）+dv_device_errors PASS（235 台全 0）；stack 层双 FAIL 断点=dv_thirdparty_inventory 34 个非微软超 30 线+dv_network_filters 4 层过滤（**nt_nnndisfilter 带给梨名单标注=与蓝屏树证据交叉一致兑现**；另见 NPCAP×2+Realtek——比 design 预期多中一层断点）；integrity 层诚实 PASS=34 个非微软全 Valid（给梨驱动本身有签名，靠名单层报它=分工正确）+古董 0（最早 2021-11-30）+未见目录签名形态 NotSigned（无需登记）。

## 十三、v0.6 图形界面设计（2026-10-20 设计稿；同晚用户拍板 9-11 毕，待实现片）

定位：界面路线第 2 阶段收官片（路书「图形界面窗体」行；1019 用户令「抵触 bat 黑框、要高级观感」的根治；触发线=五树铺毕已到，v0.5 自问③黑框挂账由本片收口）。**本片=纯呈现层：判定逻辑、检查项、树、engine 推进机制零改动**（对齐 v0.2.1 原则「只改怎么显示，不改怎么判」）；130/130 测试基线锚不动。无新树、无新检查项；素材闸不适用（界面域非故障域）；GUI 消费五棵既有树。

### 架构：GUI=壳、engine=脑（进程隔离）

```
gui/run_gui.ps1（WinForms 窗体进程，STA）
  └─ System.Diagnostics.Process 起 engine/run.ps1 子进程（CreateNoWindow 无窗，
     参数=-TreeName <名|all> -Full -NoMenu，对齐既有参数面零新增）
       └─ engine 照常：读树→Start-Job 逐项→断点→落盘 HTML 报告（现有行为一字不动）
  GUI 只消费数据渲染窗体（数据通路=拍板点①）
```

- GUI 绝不 import engine 函数、绝不自己跑检查项——防「壳里长出第二个脑」
- engine 退出码 0/2/3 原样透传显示，GUI 不重新解读判定
- 取消=杀 GUI 自己派生的子进程树（taskkill /T 或等价，杀的是本会话派生进程无系统面影响）；取消态如实标「已取消，无报告」，禁装完成态
- 子进程必带 `-NoMenu`（all 模式弹交互菜单会卡死 GUI 死等输入）

### 窗体规格（逐条；颗粒度对齐检查项规格的命令/判定/负例式，每条=构成→行为→负例）

1. **F1 主窗体**
- 构成：Form，Text=「diag 电脑体检台」，起始 900×640（MinimumSize 800×520），FormStartPosition=CenterScreen；入口先调 SetProcessDPIAware()（Add-Type P/Invoke user32，进程级声明非系统设置）防 125%/150% 缩放糊字
- 行为：跑批中点 X=确认弹窗「体检没跑完，确定退出？」；空闲/完成态直接关
- 负例：150% 缩放真机窗体文字不糊=过；跑批中 X 弹确认不直接杀=过
2. **F2 树选择面板**（顶部 GroupBox）
- 构成：6 个 CheckBox=「全面体检（五树连跑，推荐）」+五单树，勾选文案对齐 engine 菜单原文（网络体检〔上不了网/网页打不开〕/蓝屏体检〔蓝屏过/莫名重启〕/硬件体检〔磁盘/电池/温度年检〕/性能体检〔开机慢/用着卡〕/驱动体检〔驱动来路/设备黄三角〕，engine/run.ps1 menuNames 同源）；ToolTip=各树层语义一句话；默认=全面体检勾选
- 行为：勾「全面」=五单树联动勾选并禁用单改；「开始体检」只认两种形态——全勾（-TreeName all）或恰好一勾（-TreeName <名>）；勾 2-4 棵=开始按钮禁用+状态栏提示「只支持单项或全面体检」（engine 只有单树/all 语义，GUI 禁造 engine 没有的组合形态）；跑批中整面板禁用，「再跑一次」后才解禁
- 负例：勾网络+硬件两棵→开始钮灰+提示出现=过；全跑中断点树后续层不因 GUI 加戏=过
3. **F3 进度面板**（中部，跑批态显示）
- 构成：ProgressBar+当前动作 Label（「第 2/3 层·启动负担：pf_startup_items 取证中」级）+运行日志 ListBox 逐行滚动（三态着色：PASS 绿/FAIL 红/SKIP 黄灰）
- 数据源（拍板①）：B 案=engine -ProgressFile 事件流逐项驱动，进度条真值=已完成/总项数（总项数=GUI 启动时 ConvertFrom-Json 读 trees/*.yaml 数 checks 名单，只读树文件不自算判定）；A 案=跑马灯+计时，Label 明示「引擎在跑，无逐项进度数据」（诚实降级，禁假装逐项）
- 断点即停模式（快速勾选项）下：断点后剩余整层项以灰色 SKIP 行补齐显示
- 负例：全树跑完进度条 100% 且日志行数=总项数=过；跑马灯态不显示逐项假行=过
4. **F4 结果面板**（完成态显示，与进度面板同区切换）
- 构成：左 TreeView（根=报告标题〔树名+时间戳〕；二级=层带断点色；三级=检查项带三态图标）+右详情面板（选中检查项→完整 evidence 等宽字体+suggestion；FAIL 项 suggestion 区带「复制修复建议」按钮=Clipboard.SetText，进程级剪贴板无实害）
- 行为：层节点选中=显示该层 verdict_fail 人话断点；根节点=总结论（verdict_title/verdict_all_pass）+退出码人话；数据源（拍板①）：B 案=diag-\<树\>-\<时间戳\>.json 结构化报告；A 案=降级摘要卡（总结论+断点层名+「浏览器看完整报告」按钮），无逐项树——**禁解析 HTML 文件充数**（人看格式非机器契约）
- 负例：蓝屏单树跑完结果树三层状态与 CLI 版报告逐项一致（nnndisfilter FAIL 必现）=过；复制按钮贴出文本与 suggestion 逐字一致=过
5. **F5 操作按钮区**（底部）
- 构成：「开始体检」⇄跑批中变「取消」⇄完成态变「再跑一次」；「浏览器看完整报告」（完成态可用=Invoke-Item 落盘 HTML，复用 v0.2.1 渲染 GUI 不重造报告）；「打开报告文件夹」（explorer reports/，只读打开）
- 负例：完成前浏览器钮灰=过；取消后 reports/ 无新文件=过
6. **F6 状态栏**（StatusStrip）
- 构成：左=一句话状态（就绪/跑批中·第 N 项/完成·断点在 X 层/已取消/引擎异常）；右=engine 子进程 PID+耗时 mm:ss（WinForms Timer 每秒刷）
- 行为：引擎异常态（子进程异常退出/退出码 3）=红字+「请把 reports/ 最新文件发给维护者」——GUI 不吞错（诚实原则）
- 负例：人为断掉子进程→异常态红字出现且窗体不死=过
7. **F7 状态机**（全窗统一，按钮/面板可用性由此驱动）
```
选择态 →开始→ 跑批态 →正常退→ 完成态 →再跑→ 选择态
                →取消→ 取消态 →重选→ 选择态
                →异常退→ 异常态（红字+引导发报告）
```
8. **线程模型**（实现规格，违反=实现 bug）
- engine 子进程 RedirectStandardOutput/Error，输出到达回调在线程池线程——一切 UI 更新必须 Control.Invoke 封送回 UI 线程，禁直接碰控件

### 数据通路（拍板点①；1020 拍板=B 案）

| 案 | engine 改动 | GUI 体验 | 代价 |
|---|---|---|---|
| A 零改动壳 | 一字不动（130/130 原样锚） | 进度=跑马灯+计时；结果=摘要卡+浏览器看 HTML，无逐项树 | 「进度/结果面板」两件套缩水为观感件；真进度数据不存在 |
| B 事件流+JSON 报告 | 新增两个**默认关**的可选参数：`-ProgressFile <路径>`（每完成一检查项追加一行 JSON 事件：树/层/项名/状态/耗时；断点与收尾同出事件）+`-JsonReport`（HTML 落盘同时多落一份 diag-\<树\>-\<时间戳\>.json：树→层→项 status/evidence/suggestion/detail 全量，与 HTML 同源结构） | 三面板全量：真逐项进度+逐项结果树 | engine 输出层约 30 行新增型代码；判定/推进/既有输出逐字不动，130/130 不动（默认关=现有行为不变） |

推荐 B：新增输出流先例=v0.2.1 加 HTML 渲染（stdout/txt 基线锚不动）；JSON 落盘顺便给远期 Web 面板/趋势统计留口。

### 启动器与黑框口径（拍板点②；1020 拍板=bat 一闪版。现有六 bat 一字不动，拍板 7 先例）

- bat 一闪版：「全面体检（图形版）.bat」——`start` 调 powershell -STA -WindowStyle Hidden -File gui\run_gui.ps1，cmd 宿主一闪（半秒内）后只剩窗体；解压双击认知与既有入口一致
- lnk 版：zip 附 .lnk 快捷方式（目标同上）彻底零闪；部分系统对解压出的 lnk 弹安全提示（分发面新变量）
- 两版可双带（zip 多一个文件，成本近零）

### 界面主题（拍板点③；1020 拍板=深色主题）

- 深色主题：BackColor/ForeColor 手绘（WinForms 无系统暗色 API），配色与 v0.2.1 HTML 报告拉齐（实现片从 HTML CSS 取样）——「高级观感」诉求直给
- 系统默认亮色：原生控件零手绘，工作量最小，观感=标准 Windows 程序

### 只读铁律落地（铁律 1 在 GUI 层）

GUI 自身唯一写动作=剪贴板复制（用户主动点）；报告/进度/JSON 文件全在 reports/ 域内由 engine 子进程写；修复命令永远只显示+复制、禁执行（suggestion 文本口径不变）。

### 测试与真机验收

- 回归锚：130/130 现有测试零改动全绿；B 案新增单测=mock 跑树断言 JSON 报告结构与事件序（铁律 3 适配到输出层）；GUI 窗体本体=真机手测清单（WinForms 自动化测试不在本期射程，不装）
- 真机手测清单十条：①双击启动窗体居中、无黑框（或一闪）②默认全面体检→进度真动、日志逐项滚 ③结果树五树红绿黄正确 ④蓝屏单树结果与 CLI 版报告逐项一致（nnndisfilter FAIL 必中=交叉锚）⑤FAIL 项 suggestion 完整+复制逐字 ⑥浏览器钮开 HTML（v0.2.1 不回归）⑦跑批中取消→任务管理器无残留 powershell ⑧中文空格路径解压跑通（lite 彩排惯例）⑨5.1 主测+pwsh7 兼容过一遍（双版本惯例）⑩跑批中 X→确认弹窗
- 预期真机验收读数：全面体检结果树应见——蓝屏树三层全中（1019 锚）+驱动树 nnndisfilter 必中+性能树 startup 层超时类记录在案+网络树按当下网态；与 CLI 版报告逐树对照一致=判定零改动证明

### 实现注意（施工单阶段项，本片不决）

取消杀树后 engine 孙进程（Start-Job）残留实测；DPI 125%/150% 实测；图标资源形态（内嵌 ico vs 系统 Shell32）；进度事件文件清理口径（跑完即删 vs 留 debug）；B 案时 engine 版本随片升 v0.6（惯例）+GUI 标题版本同步；lite 重打包 v0.6 增图形入口；知识来源.md 补 WinForms 域校准行（STA/双版本 WinForms 可用性实测口径）；树选择勾 2-4 棵的禁用交互实现形态。
## 十四、v0.7 WPF 重写壳层设计（2026-10-20 设计稿；路线=1020 用户拍板"WPF 重写壳层（推荐）"；同夜实现主体毕：P1-P9 修复+文案大白话+三态/复制/再跑真机验证过；**1021 v0.7.1 美化收尾毕**：背景图=fan1 若娜瓦二创（画师 MrDogcc，米游社帖 78917212，自用非商用）裁剪 920:660+压暗 40%+面板 80% 半透明+无图回退纯色；修复 v0.7 真 bug=跑批中点 X 确认弹窗死锁假死（Closing 内同步 MessageBox 永不弹，修=一次性 DispatcherTimer 延迟弹窗）+taskkill stderr 转终止错误两处；复测=X/取消 UIA 7/7+135/135 全绿+三查清场复核过；lite v0.7.1 重打包不带图——明细=CHANGELOG 第十切片）

定位：界面路线第 3 阶段——观感跃迁片。**WinForms 壳整体退役换 WPF（XAML）**：功能面=F1-F8 规格零变化（判定零改动原则延续），呈现层重写+文案大白话化。触发=用户实锤反馈「右上角文本缺斤少两+文案对小白不友好」+guicheck 验收（figcheck-flash 代岗）坐实 9 项问题（P1-P9，明细=CHANGELOG 第十切片）。

### 技术选型（用户拍板记录，2026-10-20 晚）

| 候选 | 结论 |
|---|---|
| **WPF（PowerShell 跑 XAML）** | ✅ 拍板采用：系统自带 .NET（Win10/11 全有）零新依赖零安装，解压即用分发不变；XAML 样式系统=圆角/悬停/渐变/矢量观感可及"精品共享软件"级；代价=GUI 层重写一遍，engine/判定/测试零改动（B 案数据通路就是为换壳准备的） |
| WebView2 壳 | 否：观感上限最高但 PS 互操作坑深+老 Win10 覆盖打折，小作坊救不动风险真实 |
| 本地网页模式 | 否：形态=浏览器标签页非独立软件窗，"付费软件感"打折 |
| 继续 WinForms 打磨 | 否：深色原生控件天花板明显 |

冒烟实证（1020）：5.1+pwsh7 双版本跑通 XAML 深色窗+事件绑定+DispatcherTimer+ShowDialog 收口（4.5s 干净退出）。三处低级坑前置换掉：ps1 中文必 BOM（R3 旧坑复发一次）/XamlReader 用 Parse 而非 Load(StringReader)（无此重载）/收口用 ShowDialog 而非 Show+Dispatcher.Run（Close 不停 Dispatcher）。

### 验收问题对策（P1-P9 逐项）

| # | WinForms 实锤问题 | WPF 对策 |
|---|---|---|
| P1 | 顶部复选框文字断行残尾（用户实锤"右上角缺斤少两"） | WrapPanel 自动布局+每项自然宽，窗口缩放文字永不截断 |
| P2 | 完成态右侧详情整行被剪 | TextBlock/TextBox TextWrapping=Wrap 自动换行；超宽行显式省略号（TextTrimming） |
| P3-P6 | 黑话文案（五树连跑/PID/取证/层/断点/PASS/FAIL/SKIP/evidence） | 文案全面大白话化（对照表见下） |
| P7 | 禁用按钮灰字与深底对比度不足 | 样式显式定义 IsEnabled=False 前景 #8FA3B8（可辨） |
| P8 | 结果树时间戳技术格式 | 2026-10-20 21:16（去秒）+节点文案中文化 |
| P9 | 空闲态详情区空盒子无占位 | 占位文案「查完的结果会显示在这里」 |

### 文案大白话对照表（验收清单合并；原则=不懂电脑的中年人一眼懂、不废话）

| 原文（v0.6） | 改文（v0.7） |
|---|---|
| 全面体检（五树连跑，推荐） | 全面体检（推荐，查得最全） |
| 快速模式（断点即停，不跑断点后的层） | 快速模式（查到问题就停，更快） |
| 就绪——选好体检项目后点「开始体检」 | 选好后点「开始体检」 |
| 跑批中 · 共 35 项 | 正在检查（共 35 项）… |
| 第 4/4 层 DNS 层（域名解析）：xxx 取证中 | 正在查：域名解析（第 4 步，共 4 步） |
| [PASS]/[FAIL]/[SKIP] 日志行 | ✓ 正常 / ✗ 有问题 / – 没查成（+检查名保留英文原名=机器可对号） |
| ▶ 断点：xxx | ✗ 问题出在这一步：xxx |
| -- 树 性能体检 完成（FAIL）-- | —— 性能体检完成：发现问题 —— |
| == 开始 全面体检 · 引擎 PID xxx == | —— 开始全面体检 ——（PID 只留状态栏右侧） |
| 完成 · 耗时 00:28 · 有断点 / 发现隐患 | 检查完成（28 秒）·发现问题，点左边看哪里坏了 |
| 未发现断点（全通） | 全部正常 |
| 已取消 · 耗时 00:25 | 已取消，本次没有报告 |
| 体检完成——左侧查看结果，或点「浏览器看完整报告」 | 查完了。左边看每项结果，也可以点「浏览器看完整报告」 |
| 证据（evidence，原始输出摘录） | 检查依据（原始记录） |
| 修复建议（命令文本，请自己执行——工具永不代跑） | 怎么修（工具只给步骤，不会替你改电脑） |
| 复制修复建议 | 复制修复方法 |
| （选中左侧节点查看详情） | 查完的结果会显示在这里 |
| 引擎异常（代码 x）——请把 reports/ 最新文件发给维护者 | 程序出错了（代码 x）。请把 reports 文件夹里最新的文件发给维护者 |
| 树节点「第1 层 ▶断点 签名与年代」 | ① 签名与年代 —— 有问题 / ① 签名与年代 ✓ |
| 层节点详情「层状态：BREAK…」 | 这一步：有问题（其余检查项都正常） |

### 实现要点

- 结构=XAML here-string+XamlReader::Parse+FindName 绑定；DispatcherTimer 500ms 轮询事件流（UI 线程，无 Invoke 封送）；DiagDrain C# 排水/taskkill /T 取消/X 关闭确认（Window.Closing）/STA 自检重启全部沿用 v0.6 已验机制
- 样式集中 Window.Resources：色板资源（沿用 HTML CSS 取样）+按钮 ControlTemplate（CornerRadius=6+IsMouseOver 高亮+禁用态显式前景）+主按钮（开始/再跑=Pass 绿）
- 状态图标用文字符号（✓ ✗ – ①②③）非图标资源（延续 v0.6 拍板）
- GUI 版本 v0.7 显示状态栏右；engine 不动（v0.6）；bat 启动器不动
- 窗口标题不变「diag 电脑体检台」；检查项英文名保留（报告对号用）+中文层名

### 测试与验收

- engine 零改动=135/135 不动（无新单测面——GUI 纯呈现层）
- 真机手测=十条清单重跑（同 v0.6 标准）+guicheck 三查复测（截断/小白友好/布局）全 PASS 才算过
- lite v0.7 重打包+中文空格路径彩排

### 拍板记录（2026-10-20 晚，用户当轮三项全拍推荐项）

| # | 决策点 | 拍板结果 |
|---|---|---|
| 9 | 数据通路 | B 案：engine 新增 `-ProgressFile`（逐项事件流）+`-JsonReport`（JSON 结构化落盘），两参数默认关；判定/推进/既有输出逐字不动，130/130 不动 |
| 10 | 启动器 | bat 一闪版：「全面体检（图形版）.bat」（start 调 powershell -STA -WindowStyle Hidden）；现有六 bat 一字不动 |
| 11 | 界面主题 | 深色主题：BackColor/ForeColor 手绘，配色与 v0.2.1 HTML 报告拉齐（实现片从 HTML CSS 取样） |

**1020 实测兑现（实现片当夜，5.1 主测+pwsh7 兼容）**：135/135 双版本绿（130 既有零改动+B 案新增 5 条=JSON 结构/事件序/快速断点截断/默认关回归）；真机手测十条过九条半——①窗体居中+黑框一闪 0 残留 ②35 项进度真动+日志三态逐行滚 ③五树结果树红绿黄 ④蓝屏单树与 CLI 逐项 ALL-SAME（nnndisfilter 必中）⑤复制逐字 VERBATIM-IDENTICAL ⑥浏览器钮开 HTML 不回归 ⑦取消后 taskkill /T 零残留 ⑧中文空格路径彩排通（lite v0.6 zip→bat→GUI→报告落盘）⑩跑批中 X 确认弹窗、否=继续；**未过：F1 负例 150% 缩放真机不糊**（本机 100%，改系统缩放属红线不动，SetProcessDPIAware 机制已就位，挂高 DPI 真机）。真机读数四树与四代 CLI 实证一致=判定零改动证明。实况坑三处（GetNewClosure 作用域陷阱/空 scriptblock delegate 无 runspace 炸进程/zip 占位误伤）真机手测抓掉，明细=CHANGELOG 第九切片。


## 十五、v0.8+ 正规军路线：Edge 独立窗 + HTML 界面 + 双路径排障 + 安装器（2026-10-21 设计稿；1021 用户拍板开工，只做最终验收）

拍板记录（1021 用户）：①路线=Edge --app+HTML（观感上限=DeepSeek 级、零新依赖、判定零改动；HTML 资产永不作废，留 WebView2/C# 宿主升级道——UI 层与宿主层解耦，以后换宿主不换界面）；②版本管理=git 本地仓已建（1021 首提交；GitHub 私有远程待用户点头再推，版权图 .gitignore 不入库）；③产品线=lite 绿色版（解压即用）与正式版（安装器）共存不互替；④新功能=自助排障+自动排障双路径，用户电脑当小白鼠、出厂前严格测试、不可挽回操作零容忍、每步慎重提示。

### 架构（v0.8 起）

- **engine/**（PS）判定与检查项零改动；新增 **repair/ 域**=修复动作库，每动作一份自描述（风险级/预检/执行/验证/回滚五段），与 checks 同级受单测保护。
- **server.ps1**：HttpListener 绑定 127.0.0.1 随机端口（loopback 免防火墙弹窗），静态 ui/ + REST API（/api/start、/api/events 轮询、/api/report、/api/repair/*）；生命周期=窗口关闭→心跳断（≤3s）→杀引擎→server 自杀。
- **宿主**：`msedge --app=http://127.0.0.1:PORT/`（独立无地址栏窗口；lite 版接受 Edge 图标角标，正式版用安装器注册 PWA/快捷方式缓解，硬需求再升 C 宿主）。
- **ui/**：纯 HTML/CSS/JS，三视图=体检向导/结果中心/修复中心；WPF 壳（v0.7.1）退役进 archive 前保留一版作回退。
- **打包**：build.ps1 双出口——lite zip（现口径）+ Inno Setup 安装器（桌面/开始菜单快捷方式、缺依赖引导、卸载入口）。

### 双路径排障安全架构（本节核心，铁律级）

- **操作三级分类**（写进 repair 域结构，非 UI 装饰）：
  - **绿=自动排障可直接执行**：完全可逆、无数据损失、无服务中断（例：DNS 缓存刷新、时间重同步）。
  - **黄=自动排障需逐项确认+回滚包先行**：可逆但有中断（例：winsock/网络栈重置、网卡禁用再启用、指定服务重启）；执行前自动生成回滚脚本+可选系统还原点。
  - **红=永不代跑，仅自助向导**：删驱动/卸载软件/注册表改删/磁盘分区/固件类——只出分步指南（每步风险+回滚说明+微软官方文档链接），UI 警示色+二次确认。
- **修复事务五段式**：预检（条件核验，不满足即停）→快照/回滚包生成→执行（超时受控）→验证（复跑对应检查项确认修复生效）→留痕（repair-log.json 入 reports/，含完整命令与结果）。
- **防呆**：黄级确认弹层必列三行=将做什么/影响什么/怎么撤销；任何修复进行中禁并发第二个修复。
- **测试闸**：每个动作配单测（mock 环境：命令序列+回滚序列+超时负例+权限不足负例，四断言缺一不绿）；真机演练=用户电脑按绿→黄逐个过，红级永远只测向导渲染不真机执行；出厂闸（发群前）=全测试绿+真机全流程彩排+用户验收。

### UI 设计语言（v0.8）

深色主题延续（色板与报告 HTML 同源）；卡片化+圆角 8-12px+留白呼吸感；微交互=进度环/状态呼吸灯/结果卡片翻转；**小白/专家双视图**一键切换（小白=一句话结论+大按钮，专家=原始证据+命令细节全展开）；设计参考=DeepSeek 桌面端设计语言（像素级参考待用户提供 DSH 界面截图）。

### 切片计划（每片独立验收，顺序执行）

| 版本 | 内容 | 验收 |
|---|---|---|
| v0.8 | Edge 壳+server+HTML 三视图（功能对齐 v0.7.1，无修复） | UIA 自动化+真机手测十条 |
| v0.8.1 | 修复中心框架+绿级动作库 3-5 个+修复单测框架 | 单测全绿+真机绿级演练 |
| v0.9 | 黄级动作+回滚包+还原点集成 | 四断言单测+真机黄级演练 |
| v0.9.x | 小白/专家双视图+体验打磨 | guicheck 三查每片过 |
| v1.0 | Inno Setup 安装器+发群彩排（路书第 0 步解挂） | 全闸+用户终验 |

### 风险与对策

Edge --app 图标角标（lite 版接受）；HttpListener 仅 loopband 免防火墙；事件流=轮询 500ms 先行（与现节奏同）、SSE 后置；积分=重活排谷时（工作日夜/周末），每片收尾记账。

# diag CHANGELOG

## 2026-10-21 v0.9 黄级+回滚包+还原点片（第十三切片；修复域黄级全链+UI 逐项确认真流程；engine 判定层零改动）

- **范围与铁律兑现**：v0.9=repair/ 黄级 3 动作+执行器回滚包/还原点段+server 黄级放行+ui 逐项确认真流程+测试 152；engine/checks/trees 一字未动。改前基线 **144/144 双版本**（PS5.1 直跑 guicheck_tmp/v09-baseline-51.txt；pwsh7 纯净态=git stash 暂存在途改动+黄级 JSON 移出后取证 v09-baseline-7-clean.txt——首跑被在途黄级 JSON 撞上，rep_schema「只许绿级」闸当场咬住=闸有效实证）；改后 **152/152 双版本**（v09-final-51.txt、v09-final-7.txt，含末轮人话文案修复后复跑）。
- **黄级动作 3 选型（design 第四节 winsock/网络栈重置类）**：net_winsock_reset（netsh winsock reset，备份 Winsock/Winsock2 两注册表键）/net_tcpip_reset（ipv4+ipv6 reset，备份 Tcpip/Tcpip6 Parameters；affect 明示固定 IP 用户需重填）/net_tcp_reset（int tcp reset，备份 Tcp\Parameters）。动作 JSON 黄级新增字段=backup_steps（args 带 {BK} 占位符）+undo_script（撤销 bat 行模板，同占位符）+restore_point:true；match/verify 只挂真实检查项（dv_network_filters/net_ip_dhcp/net_dns_default/net_public_ping/net_gateway_ping）。
- **repair.ps1 六段化（v0.9）**：加载闸=红级永拒+黄级需显式 -AllowYellow 且缺 backup_steps/undo_script 即拒；新增回滚包段=撤销脚本先行落盘 reports\rollback\<id>-<stamp>\undo-*.bat（纯 ASCII bat+写盘后回读断言，{BK} 替换为真实备份目录）；执行段黄级=可选系统还原点→备份步（任一失败即中止）→主步（失败即停）→失败自动回滚；-WithRestorePoint 在提权内层 Checkpoint-Computer+前后序号对比（24h 频率限制静默跳过=当日已有还原点兜底判定），**还原点建不成/备份不全=中止零执行**（fail-safe 拍板）；失败分支也如实上报已跑步骤（本次排障缺口反推）；结果 stages 新增 pkg 段（undo 路径+还原点结果），台账 log 行加 pkg；提权内层生成器重构为 restore_point/backup/main/rollback 四相位（phase 入 summary，主步失败即停语义与直跑路径对齐）。
- **server.ps1**：/api/repair/run 红级仍 guide-only 永不执行，黄级放行带 -AllowYellow+可选 -WithRestorePoint（逐项确认由 ui 前置把关）；webVersion v0.9。生命周期复测：关窗 beacon 自杀+60 秒无页兜底自杀演练中各实触发一次，行为符合设计。
- **ui 黄级真流程（替换 v0.8.1「下一版上线」占位）**：黄卡按钮「逐项确认后执行」→弹层三行勾选（将做什么/影响什么/怎么撤销，三勾全点才点亮「确认执行」）+系统还原点勾选行（默认勾、可去勾）+步骤命令行+并发提示；restore_point 经 /api/repair/run body 透传；结果渲染新增「② 回滚包」段（撤销脚本文件名+还原点状态），编号改五段=①预检②回滚包③执行④复查⑤台账。
- **测试 144→152（8 新用例）**：rep_schema 黄级契约（backup_steps/undo_script 非空且含 {BK}+撤销 reg import 数≥备份 export 数+reg.exe 入白名单+库内动作数线 3→6+红级禁入库）；黄级四断言 fixture×5=rep_y_cmdseq（提权内层备份→主步依序+{BK} 替换闭环：备份标记必须落进真实备份目录）/rep_y_rollback（主步失败自动回滚按序 5 步相位断言）/rep_y_timeout（2 秒掐停+回滚）/rep_y_perm（直跑路径权限失败+自动回滚，双语境）/rep_y_rpfail（还原点建不成中止零副作用+回滚包先行仍落盘，双语境）；真黄级动作×3（rep_y_winsock/tcpip/tcp）forceNever 预检挡下零副作用——**单测绝不真跑黄级，真跑只在真机演练**；rep_rollback 断言适配 phase 化步骤表。runner 新增 forceNever/requireSilent/extraArgs 三开关。
- **真机演练（绿→黄顺序，全链过）**：绿=刷新 DNS 缓存（31ms，五段渲染+台账 16:19:40 行；复检如实报 SKIP/FAIL 不粉饰）。黄=winsock reset（18:21:54 台账行：备份×2 exit=0+主步 74ms+复检 dv_network_filters 仍 FAIL 如实呈现[重启后才生效，与 affect 文案一致]）；回滚包三件齐（undo bat+winsock.reg+winsock2.reg，与演练前置快照 SHA256 一致）。**三个安全分支真机全兑现**：①还原点分支=本机系统保护未开启，Checkpoint-Computer 报「服务禁用」→中止零执行（回滚包已先行落盘）；②备份失败分支（{BK} bug 期）→中止零执行；③成功路径全链。**撤销闭环**：前置快照==自动备份（SHA256）→撤销脚本提权真跑（双 reg import「操作成功完成」）→撤销后导出==前置快照==备份（四项 True）。诚实注脚：本机 Winsock 本为默认态，reset 写回默认=重置前后字节相同，「差异→复原」强语义本机不可演示；已证=备份有效（import 接受）+撤销可提权执行+执行前后状态一致。
- **演练抓掉三个真 bug（全带证据链）**：①**{BK} 占位符未替换**——提权内层 reg export 试图写字面量 {BK} 路径报「无法写入文件」（探针法定位：临时仓副本禁用 workDir 清理抓内层 step-1-err.txt）；修=执行段构造 bkSteps 时统一替换；单测同轮补 {BK} 闭环断言（此前 fixture 用 %TEMP% 掩盖了此坑）。②**弹层标题残留**——showYellowConfirm 未设 rm-title，沿用上一轮绿卡名「刷新 DNS 缓存」（弹层截图实抓）；修=设标题。③**页脚版本回退**——app.js 计时器/停表两处硬编码 v0.8.1，跑完一轮即盖掉 index.html 静态 v0.9（guicheck FAIL 实抓）；修=v0.9。另人话文案撤销脚本路径曾丢中间目录段（用户按显示路径找不到文件）→修=显示相对全路径。
- **guicheck 三查（12 PASS/1 FAIL/3 UNCLEAR→FAIL 修复后复核过）**：黄级弹层深/浅/窄（500px）+窄视口修复中心四图（gc-v09-yellow-modal-{dark,light,narrow}.png、gc-v09-narrow-repair.png）。FAIL=页脚 v0.8.1（bug③，修复后窄视口重截页脚 v0.9 复核过）；UNCLEAR 消解=「怎么撤销」的「销」字 1280 原图判读渲染正常、深色整页页脚被弹层遮挡=弹层设计如此。
- **工艺坑（1021 实锤）**：Start-Process -Verb RunAs 的 -ArgumentList 传含空格路径必须整串拼好且 -File 参数显式加引号——数组形式裸拼接导致提权子进程把路径从空格处拆断、秒退无输出无痕迹；repair.ps1 本体从未踩中只因它的工作目录在 %TEMP%（无空格），盘符路径含空格的工作区（本仓=F:\Zcode genius\）一踩即中。
- **lite v0.9 同步**：repair/ 整目录（含 6 动作 JSON）+server.ps1+ui/ 三件拷进 diag-lite/，BOM 逐验（ps1 带/JSON JS CSS HTML 不带，11/11 OK）+逐字节 diff ALL-IDENTICAL；本片不打 zip（双出口留 v1.0）。

## 2026-10-21 v0.8.1 修复中心片（第十二切片；修复中心框架+绿级动作+真机演练+三查+lite 同步收口；engine 判定层零改动）

- **范围与铁律兑现**：v0.8.1 全片=repair/ 域新增+server 三修复路由+ui 修复中心+测试第 4 节；**engine/checks/trees 一字未动判定逻辑**，两处引擎修复均为判定无关竞态（见下）；改前基线 135/135、改后 **144/144 双版本全绿**（guicheck_tmp/final2-51.txt、final2-7.txt 实档），生命周期 **20/20×3**。
- **repair/ 域（五段执行器）**：load→precheck→exec（每步超时受控）→verify（复跑 match 的检查项）→log（reports/repair-log.json 追加行，JSONL）；绿级动作 3 条选型=刷新 DNS 缓存（ipconfig /flushdns）/ARP 缓存刷新（arp -d *）/DHCP 重新注册（ipconfig /renew），动作 JSON 自描述五段（desc/affect/undo 三行文案+steps+rollback+match_checks+verify_checks）；黄/红级只留框架位（黄=逐项确认+回滚包先行 v0.9 上线，红=永不代跑仅分步指南）。**提权机制**：需管理员动作由执行器内部一次性 RunAs 拉起自身（本机 UAC=0 静默过，用户真机弹蓝框点「是」）；PS5.1 三坑如实记=大小写不敏感变量名互撞（$r/$R 同名炸）、快速退出进程 ExitCode 为 null、ConvertFrom-Json 数组嵌套需包 @() 。
- **server 修复三路由**：/api/repair/list（启动时只读 repair/actions/*.json，坏 JSON 跳过不炸）/run（POST id→子进程拉 repair.ps1）/status（轮询）；跑批与修复互斥双向 409；关窗/bye 时 repair 子进程随杀。
- **ui 修复中心（真框架替换 v0.8 占位）**：本轮 FAIL 项逐条列卡（复制修复方法保留），match_checks 命中的动作卡内嵌（色徽章+三行文案+步骤命令行）；绿=执行按钮→管理员预告弹层（「Windows 会弹蓝色确认框」口径）→五段结果就地渲染（预检/执行含命令输出回显/复查逐项/留痕）；黄=「看步骤与撤销法」弹层（注明下一版上线+步骤可自己照做）；红=二次确认（首点变「有风险——再点一次查看」，4 秒内再点才开）→全屏指南页（警示头+影响/撤销+编号步骤）。
- **测试第 4 节（9 用例，135→144）**：动作 schema 契约、命令序列/回滚序列/超时负例/权限负例（含 admin-block 分支）fixture、3 条真动作全链真跑（静默提权上下文分支）。
- **引擎两处判定无关修复（dac2fe6，证据链）**：①Write-ProgressEvent Add-Content 加 5 次重试——对照实验=v0.8 worktree 同样挂（排除 v0.8.1 新代码引入）；单发复现=双进程并发写 1/200 撞车（v0.8 读方共享句柄修复只降概率不归零，单次撞车即杀引擎）；②Trim-Reports 按内嵌时间戳排序——原按文件名词Lexical 排，diag-all-* 恒排最旧，新写合并报告到 50 上限即被删→404；修复后生命周期压测 **20/20×3**。
- **真机演练（施工单第 5 条，全链过）**：真跑 server→浏览器单勾网络体检（本机 net_dns_deadaddr 真实 FAIL）→修复中心出「刷新 DNS 缓存」绿卡→执行→管理员预告弹层→五段结果渲染（ipconfig 输出回显「已成功刷新 DNS 解析缓存」、复查 SKIP/FAIL 如实呈现）→**reports/repair-log.json 追加行核对（15:11:23 net_flush_dns ok=true ms=33）**。演练坑如实记：勾选框被装饰 span.box 挡 actionability→evaluate 设 checked+派 change；server 起后 25 秒无页自杀两次踩中（读文档超时）→端口文件等待与连页合并一步。
- **guicheck 三查（17 PASS / 0 FAIL / 0 UNCLEAR，可验收）**：修复中心深/浅/窄视口（500px）+黄红 fixture 渲染（临时塞 zz-fixture-yellow/red.json，match_checks 指 net_dns_deadaddr，验毕删净还原 3 文件）；证据=guicheck_tmp/gc-repair-{dark,light,narrow,yellow-modal,red-armed,red-guide}.png 六图；两条观感级提示不阻验收=浅色黄徽章对比度偏淡、窄视口导航按钮逐字断行（v0.9.x 打磨片候选）。演练工具坑：fullPage 截图对 fixed 背景产拼贴伪影→改拉高视口截 viewport；红级 4 秒武装窗口跨自动化调用会过期→两连击须同调用内。
- **lite v0.8.1 同步**：repair/ 整目录+server.ps1+ui/ 三件拷进 diag-lite/，BOM 逐验（.ps1 带 BOM、JSON/JS/CSS/HTML 无 BOM）+与主目录逐字节 diff ALL-IDENTICAL；本片不打 zip（双出口留 v1.0）。

## 2026-10-21 壁纸支线·定稿上墙（接下节「候选扩充+对比图」；主线 v0.8.1 不动，engine/checks/trees/tests/ui 零触及）

- **用户拍板**：候选 image.png（2048×951）+裁切构图 B 正中 focusX=361 +输出放大档 1840×1320。拍板件=bg-candidates/裁切草稿对比-1021.png（A180 偏左/B361 正中/C550 偏右三稿拼图）+放大对照-1021.png（原生 vs Lanczos 1.39×，目检放大不糊，且窗口大于图时 WPF 运行时拉伸质量不如预放大）。
- **定稿管线落盘 assets/bg.jpg**（1840×1320 JPEG q88，367KB）：B 窗口 1326×951 裁切 → Lanczos 放大 → 压暗 40%（#0F3D66 叠层 α=102；v0.7.1「黑蓝叠层」原色值无存档，按主题回退色同源执行，可读性由 guicheck 把关）→ q88；写盘后回读断言尺寸/格式/压暗角点 maxdiff=1。**实况修正：覆盖时 assets/bg.jpg 本不存在（v0.7.1 旧图 fan1 已随清理删除，GUI 此前一直纯色回退态）→「覆盖前备份旧图」空转，无备份产物**。
- **纯色回退实测过**：bg.jpg 改名离位→GUI 正常起窗，无面板遮挡带 187/187 px=纯色 #0F3D66（面板下透出=理论混合值 0.8×#0B2E4D+0.2×#0F3D66 吻合）→还原后同带采样恰为 bg.jpg 压暗灰底值 (116,133,151) 交叉吻合；两态客户区平均绝对差 14.2=背景图真实渲染。
- **guicheck-flash 四项复核全 PASS**（证据=guicheck_tmp/bg-new-withimg.png，1150×825 DPI 感知）：截断/布局/小白友好/图上文字可读性；边缘数像素桌面残影=截窗含 DWM 隐形边框非应用缺陷。窗口版本串仍 v0.7.1（观感支线不升版本）。
- **待用户补一行**：image.png 画师/来源页缺失（唯一候选拍板时未带三件套），需补进使用说明【背景图版权】段；补不出=「自用非商用」口径兜底。
- 证据留存：草稿/对照图在 bg-candidates/，验收截图 bg-new-withimg.png、bg-fallback-test.png 在 guicheck_tmp/。
- **1021 收官用户裁定（口径最终版）**：image.png 原图即定稿背景主题图；上墙与面板观感改造（用户不满面板挡脸效果）**挂起至最终版本落盘后再议**；assets/bg.jpg 仅 legacy WPF GUI 读取（v0.8 HTML 壳不受影响），现存即裸用 v0.7.1 管线产物，不再迭代。同轮发起 diag 过期流水清理：v0.7.1 旧 zip/截图、支线棒、guicheck_tmp 被迭代调试件（≈8.5M 截图+13 个一次性脚本）移 archive/过期流水-1021清理/（索引随附），10-21 当天件与 v0.8.1 测试基建零触及。

## 2026-10-21 壁纸支线·候选扩充+对比图（接力棒=交接棒-壁纸支线-v0.1.md；主线 v0.8.1 不动，engine/checks/trees/tests/ui 零触及）

- **扩候选 25 张全带社区数值**：zerochan 20 张——requests 直连被「Checking browser」JS 挑战拦（JSON 接口同 503），转 IAB 浏览器路线过挑战后页内 fetch+DOMParser 翻页；`Ronova?s=fav` 收藏降序 3 页 136 条（第 4 页免登录拿空=深度到顶），横图 28 张收 fav≥9 的 20 张，fav=站内收藏当天实测，原图 static 直链下载零失败；bilibili 5 张——按收藏降序取「若娜瓦 壁纸」前 5 的视频封面，view API 风控返非 JSON，改抓视频页 HTML `"pic"` 字段成功（封面已下载，如选 b 类定稿前可再提高清截帧）；lofter 跳过（tag 页免登录被重定向 /front/login，browser 实测）；米游社跳过（旧端点 404 勿重探，沿侦察结论）。单站请求量：zerochan 浏览器侧 ≤10 次+下载 20 次，bilibili ≤13 次，均在 ≤40 红线内。
- **登记表重写**（assets/bg-candidates/登记表.md）：全表加「社区数值」列（fan1-6 标未取数）；新增 25 行（z01-z20 + b1-b5），画师/来源 URL/直链/尺寸/fav 或收藏播放五件齐；25 个文件落 bg-candidates/（zc<id>.* 与 bili-<bvid>.jpg），尺寸 PIL 回读与登记值逐张比对一致。
- **对比图 sheet-1021.jpg**（2472×2204，26 格=编号+画师+社区数+尺寸标注，含现役 fan1 对照格；msyh 字体渲染目检清晰）。**停下等用户拍板选图——拍板前未做任何图片处理、未动 assets/bg.jpg**（施工单第 3 条红线兑现）。
- 临时件清理：zerochan 挑战页探针临时 html 已删；bg-candidates/ 留 zc-meta.json/bili-meta.json 两个数据源小件（登记表依据，定稿后可删）。

## 2026-10-21 v0.8 Edge 壳+HTML 界面片（第十一切片；10-20 深夜开工跨零点收尾）

- 目标：design 第四节 v0.8 落地——Edge --app 独立窗+本地 server+纯 HTML/CSS/JS 三视图，功能对齐 v0.7.1，本片零修复动作。**判定零改动铁律兑现：engine/checks/trees/tests 一字未动，135/135 改动前基线与交付后终验双版本全绿**（5.1+pwsh7 各 135/135）。
- **server.ps1（新增，5.1/7 双兼容，BOM）**：HttpListener 绑 loopback 随机端口（TcpListener 探空端口→释放→绑；127.0.0.1 前缀被拒自动降级 localhost 前缀，免防火墙弹窗）+静态 ui/（index/app.js/style.css 白名单下发）+REST（/api/meta /api/start /api/events /api/cancel /api/report /api/heartbeat /api/bye /api/open-reports /api/shutdown + /reports/<diag-*> 报告下发带文件名白名单正则）；引擎子进程沿用 B 案 -ProgressFile/-JsonReport（engine 零改动）；DiagDrain C# 排水照搬+stderr 落盘 temp 日志（隐藏窗可诊断）；开发/测试参数 -MockDir/-NoBrowser/-PortFile 默认关（lite 行为=真跑）。
- **生命周期（v0.8 的灵魂件，两次返工后定稿）**：关窗主信号=页面 pagehide sendBeacon('/api/bye')→server 2 秒宽限（F5 重载先拉静态文件即撤销）→杀引擎（taskkill /T/F try/catch）→自杀——Edge 真窗两连测 2 秒自杀+零残留达标「窗关→3 秒内」。心跳=兜底而非主判（**Chromium 后台页定时器节流到 ~1 次/分钟，2.5 秒心跳超时会把最小化的活窗误杀——真机实锤**）：非跑批态 60 秒无请求=页面已弃→自杀，跑批中不判（引擎跑完自然收敛）；**beacon 与在途心跳的赛跑**（bye 后到的心跳把 bye 冲掉退化 60 秒）修=只有静态资源//api/meta（真页面加载信号）才撤销 bye，心跳/事件轮询不撤销——Edge 复测第二次抓到、修后两连过。
- **ui/ 三视图（纯 HTML/CSS/JS 零构建零 CDN 断网可用）**：体检向导（勾选卡+跑批进度卡）/结果中心（左树右详情+复制）/修复中心（占位：绿黄红三色安全规则卡+本轮 FAIL 清单带复制，v0.8 无任何代跑动作）；深色科技感（参考 Fluent 2 暗色面板+shadcn 卡片语言：CSS 变量色板+1px 边框卡片+径向渐变底+强调色辉光点）；**用户可自定义主题**（右上「◐ 主题」：深/浅色+六强调色，localStorage 持久化）；文案对照表逐字沿用第十四节（✓ 正常/✗ 有问题/– 没查成、正在查：xxx（第 N 步，共 M 步）、只支持查一项或全部——勾 2 到 4 项不行、已取消，本次没有报告 等）；F5 刷新恢复（server 侧事件缓冲 since=0 重放+跑完态静默拉报告）。
- **「全面体检（网页版）.bat」（第八启动器，diag-lite；ASCII+CRLF 无 BOM 验字节；现有七 bat 一字不动）**：start powershell -WindowStyle Hidden -File server.ps1，server 绑定后自拉 msedge --app（三路径探测+默认浏览器降级兜底）。
- **功能对齐 v0.7.1 验收面（全过）**：树勾选（全勾联动禁用单改/单勾/勾 2-4 禁用+状态栏提示）✓ 进度真值+当前层文案 ✓ 日志三态着色+秒耗时 ✓ 结果树四级（报告/树/①②③层/检查项）+选中详情（evidence/suggestion/层说明/树结论/总结论五型）✓ FAIL 复制（clipboard API+execCommand+**选中文本弹层 Ctrl+C 三级兜底**——失焦环境自动复制失败时文字已选好，实测 248 字符全选）✓ 取消（UI 点取消→cancelled 文案+引擎零残留）✓ 关闭确认（**网页内弹层**「体检没跑完，确定退出？」继续检查=不打断+退出=杀引擎+告别层；OS X 关窗=beforeunload 原生确认+beacon 生命周期）✓ 浏览器看完整报告（/reports/ 下发 v0.2.1 渲染不回归）✓。
- **自动化验收三通道**（test_xclose.ps1 的网页版后继；UIA 直驱 Edge 树弃用=Chromium UIA 走 CDP/浏览器自动化更稳，如实记）：①**guicheck_tmp/test_webclose.ps1 20/20**=mock 全流程（meta/静态/start/events 事件序/report/报告下发）+真跑取消零残留+beacon 关窗自杀+双开 409 拒+弃页 60 秒兜底；②**浏览器自动化全交互流**（真机 server 实跑：全面体检 35 项真跑 33 秒/网络树快速断点链/结果树真读数与历代 CLI 实证一致=DNS 死地址断点+蓝屏 0x139×3+nnndisfilter+内存诊断史全命中；复制/主题换肤/F5×3 不误杀）；③**test_edge_app.ps1 真窗链**=bat→Edge 窗（标题=diag 电脑体检台）→截窗图→CloseMainWindow→2 秒自杀→三零残留（两连测）。
- **三查四轮收口（guicheck-flash：首轮 4 FAIL→修→复审→第四轮 2/2 PASS）**：①日志框 1.75 行高不能整除产半行切割+状态栏贴边→修=整 22px 行高+308px 框高+状态栏加高；②结果树「层级错位/游离」程序级几何审计证伪（16 层节点 left 全 88px、无空行、从属正确）——真因=树列 276px 窄+长标题换行+状态后缀混排的视觉误读，仍做真优化=层标题与状态徽章分体（「—— 有问题」独立着色徽章，标题悬挂缩进）；③修复建议 netsh 参数行中硬切→修=break-all 换 overflow-wrap:anywhere（复审 PASS：折行在词边界）；④Edge 窗「右缘真截断」两轮复现→**title 探针定案（页面把 innerWidth/scrollWidth/dpr 写进 document.title 供 UIA 直读）：窗内实测 1245=1245 零溢出，元凶=截图脚本 DPI 不感知**（系统 125% 缩放下 GetWindowRect 拿逻辑坐标 1010，真窗物理 1262——截图丢右侧 20% 画面=假截断），修=shotwin.ps1 加 SetProcessDPIAware，DPI 感知重拍 1262x1355 后终审确认右列卡片完整 wrap 正常（坑沉 LEDGER 2026-10-21）。附带修正：跑批卡自动滚动 behavior:smooth 在后台页被 rAF 节流卡死→改 auto；防御性 body min-width:700 拔除（窄视口反而致溢出，画蛇添足）。
- **两处实况坑（真机抓掉，如实记）**：①**事件流并发读抢锁杀死引擎**——server Get-Content 轮询与 engine Add-Content 追加写抢文件锁，engine Stop 偏好下锁冲突=终止错误 exit 1（mock 高频追加必撞、真跑稀疏从没撞过=历代 GUI 无此史）；修=读方 FileStream(FileShare.ReadWrite) 显式共享写+末行撕裂容忍（解析失败的末行不算已读下轮重读），三连压测 17/17→20/20；②**IAB 自动化环境 document 失焦致 clipboard API 拒绝**=自动复制必失败——产品级修=三级复制兜底（弹选中文本层），真机 Edge 前台窗+真实点击不受影响（secure context+clipboard API 存在程序级证明）。
- lite v0.8 同步：server.ps1+ui/ 三件复制进 diag-lite/（BOM 逐验）；本片不打 zip（build.ps1 双出口=lite zip+Inno Setup 安装器留 v1.0 切片，发群口径不变）。
- 拍板与待用户裁定（夜间自治，保守默认）：修复中心占位文案=三色规则说明+FAIL 清单（无代跑）；Edge 缺失时降级默认浏览器（窗口形态降级非功能损失）；--window-size 高度 Edge 自主恢复（宽度 1000 生效）未强制锁窗高。

## 2026-10-20 v0.7/v0.7.1 WPF 重写壳层+美化收尾片（第十切片）

- 目标：design 第十四节落地（WinForms 壳退役换 WPF/XAML；路线=1020 用户拍板「WPF 重写壳层（推荐）」；触发=用户实锤「右上角截断+文案不小白+观感廉价」+guicheck 坐实 P1-P9）。**纯呈现层重写：判定逻辑、检查项、树、engine、bat 启动器零改动**（135 既有用例零改动全绿为回归锚）；功能面 F1-F8 规格零变化。
- **v0.7 WPF 主体（1020 深夜实现毕，交接棒记录）**：gui/run_gui.ps1 整体重写为 XAML here-string+XamlReader::Parse+FindName 绑定；样式集中 Window.Resources（色板资源+按钮 ControlTemplate：CornerRadius=6+悬停高亮+禁用态显式前景 #8FA3B8+主按钮 Pass 绿）；P1/P2 根治=WrapPanel 自然宽+TextBlock/TextBox TextWrapping=Wrap（窗口缩放文字永不截断）；P3-P6=文案全面大白话化（对照表=design 第十四节，✓ 正常/✗ 有问题/– 没查成三态、层节点①②③编号、时间戳去秒）；P7=禁用态显式前景；P8=2026-10-20 21:16 去秒+节点中文化；P9=空详情占位「查完的结果会显示在这里」。DispatcherTimer 500ms UI 线程轮询沿用；DiagDrain C# 排水/taskkill /T 取消/STA 自检重启/SetProcessDPIAware 全部沿用 v0.6 已验机制。真机已验（1020）：首屏/跑批 35 项/五树结果树/复制 248 字符/再跑/蓝屏单树与 CLI ALL-SAME。
- **v0.7.1 美化（本片）**：①背景图=用户拍板 fan1（原神若娜瓦同人二创，画师 MrDogcc，米游社帖 78917212，自用非商用）——程序级适配：居中偏左裁剪 920:660 构图（focusX=40）+2x 分辨率 1840×1320+整体压暗 40%（黑蓝叠层 alpha=102）+JPEG q88 → assets/bg.jpg；WPF 注入=Window.Background 换 ImageBrush（Stretch=UniformToFill，OnLoad+Freeze）；**assets\bg.jpg 不存在自动回退纯色 #0F3D66（发群 zip 不带图=观感自动降级纯色，零功能损失）**；面板 Panel/PanelHi 改 80% 不透明度（#CC0B2E4D/#CC123A5F）叠图上，TreeView/ListBox/日志区随资源联动。压暗 40%+选图 fan1=1021 用户看草稿截图拍板定稿。版权口径=画师+来源链接写进使用说明【背景图版权】段+「发群版不带图」声明+「想加背景放 assets/bg.jpg」指引。②窗口标题栏版本 v0.7.1（状态栏右侧+guiVersion）。
- **v0.7.1 修复（上一棒未完件复测中挖出的 v0.7 真 bug，如实记）**：**跑批中点 X=确认弹窗永不出现且 UI 假死**——根因=WPF Window.Closing 事件分发过程内同步调用 MessageBox.Show 死锁（弹窗永不创建、UI 线程悬死在 Show 内、窗口被 e.Cancel 保活=「点了 X 没反应」；1020 手测第⑩条为假阳性）。修法=Closing 处理器只做 取消+启 80ms 一次性 DispatcherTimer，弹窗脱出 WM_CLOSE 分发上下文再 Show（本程序 btnCopyTimer 同模式）；确认「是」→杀引擎+清进度文件+置 closeConfirmed 标志真关窗。附修：两处 `& taskkill.exe` 调用包 try/catch——PS5.1 下原生命令 stderr 行+`$ErrorActionPreference='Stop'` 转终止错误，crash.log 实锤取消按钮处理器曾被 taskkill「could not be terminated」stderr 炸断（9.1 中文 stderr 复现路径）。
- 复测（1021，UIA 自动化）：**X 关闭/取消 7/7 全绿**=跑批中 X 弹窗出现 ✓/「否」=继续跑不杀 ✓/「取消」=taskkill /T 杀引擎零残留+窗口保留 ✓/非跑批态 X 直关无弹窗 ✓/「是」=退出并杀引擎 ✓/终态零残留 ✓（证据截图 guicheck_tmp/x-dlg-run1/2.png；测试脚本 guicheck_tmp/test_xclose.ps1=UIA 驱动可复跑）。**135/135 全绿**（GUI 呈现层零触及 engine，回归锚不动）。自动化探针三处坑如实记：①WPF owned MessageBox 在 UIA 树不挂根节点 #32770、而是 owner 主窗口的后代（按钮 AutomationId=6/7）——按老经验找弹窗必假阴性；②native 弹窗按钮可无 InvokePattern，击键兜底（Y/N 助记键）；③`Get-Process | ? {$_.Id}` 内联经 bash 必吃 `$_`、含 `$_` 的 PowerShell 一律落文件跑。
- lite v0.7.1：gui/run_gui.ps1 同步；使用说明升 v0.7.1（版本行+背景图版权段）；**zip 不带 assets/**（背景图=自留件）。
- 三查复测（guicheck-flash：截断/小白友好/布局/图上可读性）：**首次回报不可判（UNCLEAR/FAIL）——环境事故非代码回归**：此前调试轮遗留的孤儿 GUI 实例（挂模态弹窗+各自引擎在跑）堆在桌面，新起实例客户区渲染整片白（UIA 树正常、像素不画；多 WPF 实例并存渲染资源枯竭的典型症状）。清杀全部孤儿后主会话同链路复拍（guicheck_tmp/draft-v071.png 清场版）视觉复核：**四项全过**=深色主题+背景图正常渲染/复选框按钮状态栏文字全可读（截断过）/无重叠错位（布局过）/文案大白话无黑话（小白友好过，v0.7 全量替换口径未回退）/图上文字对比度足够（图上可读性过）。教训沉 LEDGER：长跑自动化测试必须每轮收尾杀净实例，孤儿模态窗会污染后续视觉验收。
- lite v0.7.1 打包：**diag-lite-v0.7.1.zip**（53 条 110KB；字节级抽验=包内无 bg 图（发群版不带图口径兑现）+reports 占位在+gui 含 askCloseTimer 修复）；engine/checks/trees 与 v0.6 逐字同源（呈现层零改动证明）。
- 拍板记录：背景图选材=1021 用户拍板（fan1 若娜瓦暗红/40% 压暗/面板 80% 半透明，草稿截图过目后定稿）；官方壁纸路线 1021 用户否决（「不要官方壁纸」→改抓画师二创）；「兹白」经视觉识别岗确认是另一角色非画师（纠偏抓图口径）。

## 2026-10-20 v0.6 图形界面实现片（第九切片）

- 目标：design 第十三节落地（WinForms 壳+engine 进程隔离；拍板 9-11=B 案数据通路/bat 一闪/深色主题）。**纯呈现层：判定逻辑、检查项、树、engine 推进机制零改动**；GUI 绝不 import engine 函数、不自己跑检查项；退出码 0/2/3 原样透传，GUI 不重新解读判定。素材闸不适用（界面域非故障域）。
- **engine v0.6 B 案两默认关参数**：①`-ProgressFile <路径>`——每完成一检查项追加一行 JSON 事件（event=check 树/层/项名/状态/耗时毫秒；断点事件=event break；单树收尾=event tree_done 带 FAIL/PASS；全局收尾=event done 带退出码+htmlReport/jsonReport 路径）；②`-JsonReport`——HTML 落盘同时多落 diag-\<树\>-\<时间戳\>.json（结构：engine/host/time→trees[]→tree/report_name/verdict_title/verdict_all_pass/break_layer→layers[]→state/verdict_fail→checks[]→status/evidence/suggestion/detail 全量，与 HTML 同源 layerResults，**禁解析 HTML 充数**）。两参数默认关=不带时行为逐字不变（stdout 零新增行）；版本字符串全部处升 v0.6（菜单横幅/文本报告头尾/HTML banner+footer）；reports 50 份裁剪扩收 .json；**reports 目录自愈**（发行包缺目录防御一行加固，幂等不碰判定与输出）。
- **gui/run_gui.ps1 WinForms 壳**（5.1+pwsh7 双兼容；STA 自检+非 STA 自动重启自身；入口 SetProcessDPIAware() P/Invoke 进程级防 125%/150% 糊字）：F1 主窗体「diag 电脑体检台」900×640（Min 800×520，CenterScreen；跑批中点 X=确认弹窗「体检没跑完，确定退出？」，空闲/完成态直接关）；F2 树选择面板（6 复选框=全面体检〔五树连跑，推荐〕+五单树，文案对齐 engine 菜单原文，ToolTip=各树层 title 串联；勾全面=五单树联动勾选并禁用单改；开始只认全勾（-TreeName all）或恰好一勾，勾 2-4=按钮禁用+状态栏「只支持单项或全面体检」；快速模式复选框=断点即停；跑批中整面板禁用）；F3 进度面板（ProgressBar 真值=已完成/总项数，总项数=启动时只读 trees/*.yaml 数 checks；当前动作 Label「第 X/Y 层·层名：检查项 取证中」；日志 ListBox 逐行滚动三态着色 PASS 绿/FAIL 红/SKIP 灰；快速模式断点后剩余项灰 SKIP 行补齐）；F4 结果面板（左 TreeView 根=报告标题/树/层/检查项四级带状态色+右详情=完整 evidence 等宽+suggestion；FAIL 项「复制修复建议」按钮=Clipboard.SetText 剪贴板回弹提示；数据源=JSON 报告，JSON 缺失时诚实降级摘要不装懂）；F5 按钮区（开始⇄取消⇄再跑一次；浏览器看完整报告=完成态可用 Invoke-Item 落盘 HTML 复用 v0.2.1 渲染；打开报告文件夹=explorer 只读）；F6 状态栏（左一句话状态+右 v0.6·引擎 PID·耗时 mm:ss 每秒刷；异常态红字+「请把 reports/ 最新文件发给维护者」不吞错；取消态如实标「已取消，无报告」）；F7 状态机（选择→跑批→完成/取消/异常→再跑/重选回选择）；F8 线程模型（取消=taskkill /T 杀本会话派生子进程树；子进程 stdout/stderr=Add-Type 编译 C# 空回调异步排水；进度事件流=UI 线程 Timer 500ms 轮询增量行；进程退出=Timer 轮询 HasExited 在 UI 线程收敛）。深色主题（拍板 11）：BackColor/ForeColor 手绘，色值取样自 v0.2.1 HTML 报告 CSS（窗体底 #0f3d66=banner 原值/面板 #0b2e4d=banner 同族暗档/浅文字 #f8fafc；状态色 #188a42/#d92b2b/#667085 深底提亮一档保对比度），列表/树自绘或设色。
- 启动器（拍板 10）：**「全面体检（图形版）.bat」**（diag-lite；ASCII+CRLF，反斜杠 chr(92) 显式造+od 验字节；`start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "gui\run_gui.ps1"`，cmd 宿主一闪后只剩窗体）；**现有六 bat 一字不动**（拍板 7 先例）。
- 测试：**135/135 双版本全绿**（5.1+pwsh 7）=**130 条既有用例零改动全绿**（回归锚）+**B 案新增 5 条**（tests/cases_b.ps1+run_tests.ps1 ③节：临时仓〔engine/checks/trees 复制 temp〕跑 engine 主仓 reports 零污染——b_json_single_break 断点场景 JSON 结构〔树→层→项与 yaml 层序项数逐层比对+FAIL 必附 suggestion〕+事件流全断言〔9 check+1 break+1 tree_done+1 done、事件序=树层序、done.jsonReport 路径存在、stdout 报告保存行不回归〕/b_json_single_fullpass 全通 break_layer=null+exit0/b_json_all_clean 五树按序+36〔实为 35〕check+5 tree_done+1 done/b_progress_faststop 蓝屏树快速断点=2 项事件+后续层 SKIPPED-AFTER-BREAK 空 checks/b_default_off 两参数不带=零 JSON 零进度文件+stdout 基线关键词照常）。修 1 处 PS 字符串坑（"$k:" 被 5.1 解析为驱动器限定变量引用→$($k):）。
- 真机手测清单十条（computer-use 视觉级+程序级双验）：①双击启动窗体居中、黑框一闪后 0 残留 cmd 窗 ✓②默认全面体检 35 项进度真动（88%/100% 中途截图）+日志逐项滚（40 行三态着色）✓③结果树五树红绿黄正确（根/树/层/项四级+总结论+退出码人话）✓④蓝屏单树三层与 CLI 版逐项一致（history/attribution/evidence 三层状态与 20 分钟前全面体检版 **ALL-SAME=True** 程序级比对；nnndisfilter FAIL 必中）✓⑤FAIL 项 suggestion 完整+复制逐字（bs_suspect_drivers 159 字符剪贴板 vs JSON **VERBATIM-IDENTICAL=True**）✓⑥浏览器钮开 HTML（Edge 新 tab「全面体检报告 …」，v0.2.1 渲染不回归）✓⑦跑批中取消→取消态如实+taskkill /T 后引擎孙进程 **0 残留** ✓⑧中文+空格路径解压跑通（桌面「lite 彩排 v06」解压→双击图形 bat→GUI→全面体检→reports 落盘 diag-all html+json）✓⑨5.1 主测全条+pwsh7 全链路（窗体起+UIA 点击+引擎跑+JSON 落盘+结果树渲染）✓⑩跑批中 X→确认弹窗、否=继续跑不杀 ✓。**未过项如实记**：F1 负例「150% 缩放真机不糊」未验（本机 100% 缩放，改系统缩放属 R1 系统级禁改；SetProcessDPIAware 机制已就位，挂待高 DPI 真机）。
- 真机预期读数兑现：全面体检结果树四树读数与四代 CLI 实证一致（蓝屏三层全中/驱动 stack 34 家+4 层过滤/性能 startup 超时/网络按当下网态 DNS 死地址断点）——判定零改动证明。
- lite v0.6：engine（v0.6）+gui/run_gui.ps1 复制；第七启动器「全面体检（图形版）.bat」；使用说明升 v0.6 七入口（图形版置推荐位+gui 文件夹勿删告知）；**diag-lite-v0.6.zip**（53 条 108KB；reports 只带「报告在这里.txt」占位=真实报告不进包；包内字节级抽验：engine 无 v0.5 残留/gui 含 DiagDrain 无 GetNewClosure/占位在）。
- **本片三处实况坑（真机手测抓掉，如实记）**：①**GetNewClosure 与 $script: 前缀不兼容**——事件 handler 加 .GetNewClosure() 后 $script: 指向闭包 module 而非脚本作用域，Timer 轮询/取消/关闭确认全失效（表面进度文本只是启动时刻静态值）；修=全部去掉 GetNewClosure（delegate scriptblock 本就保留原 sessionstate 链），11 处。②**空 scriptblock 转 delegate 在无 runspace 的回调线程炸进程**——add_OutputDataReceived({ }) 的 OutputDataReceived 回调（.NET 线程池）执行空 scriptblock 也需 runspace，引擎首批 stdout 到达即整进程消失且 stderr 无痕；先误换 Timer 内 ReadExisting 排水=pipe 空时底层同步 Read 阻塞 UI 线程挂死；终修=Add-Type 编译 C# 空回调（纯 .NET 闭包无 runspace 依赖）。③**zip 打包 skip 规则误伤 reports 占位文件**——「skip reports 下 .txt/.html」把 v0.5 惯例的「报告在这里.txt」占位也清了（空目录不进 zip）→解压后无 reports 目录→引擎写报告炸→GUI 异常态；修=只 skip diag-* 前缀真实报告+engine 加目录自愈双保险。彩排 UIA 辅助观察另见：Hidden console 宿主下 UIA 控件类型退化为 Pane（自动化视角差异，真人交互无碍，记录待察）。
- 拍板记录（施工单级自拍，design 实现注意项收口）：进度事件文件清理口径=temp 域跑完即删（瞬态管道非档案）；JSON 报告进 50 份裁剪（diag-* 同规则）；图标资源形态=不用 ico，状态用文字前缀着色（[PASS]/▶/↷）；勾 2-4 禁用形态=开始按钮灰+状态栏提示；GUI 标题保持「diag 电脑体检台」逐字（F1 规格），版本显示走状态栏右侧「diag v0.6·PID·耗时」。

## 2026-10-20 v0.5 驱动树实现片（第八切片）

- 目标：design 第十二节驱动树落地（6 检查项+树+测试，判定语义一字不改）。施工单= 施工单-v0.5-驱动.md（拍板 9-12 续 design 1-8：菜单=engine 中文/合并=多树 -TreeName all/裁剪=全部 diag-* 保留 50 份/DriverDate 交叉参照不做）。素材口径=无新真实样本，凭微软官方命令域实证设计（路书闸已标）；既有实证锚=1019 蓝屏案 nnndisfilter（交叉验收用）。
- 6 个只读检查项（checks/dv_*）：`dv_driver_signature`（Win32_SystemDriver Running→PathName 三形态清洗（\??\ 前缀/SystemRoot 前缀/相对路径补全）→CompanyName 分桶（含 Microsoft=微软桶跳过验签=性能护栏）→非微软子集 Get-AuthenticodeSignature 两段式；NotSigned/HashMismatch/UnknownError=FAIL，全 Valid=PASS 附聚合，NotSupported 等非常规状态=登记制不判 FAIL）/ `dv_driver_age`（.sys LastWriteTime<2015-07-29（Win10 RTM 官方锚）古董计数 ≥5=FAIL；未定位不参与附计数行）/ `dv_thirdparty_inventory`（CompanyName 聚合，非微软（含无厂商元数据桶）>30=FAIL，15-30=PASS 附注「偏厚」；与 signature 不做缓存共享=小拍板①）/ `dv_network_filters`（Get-NetAdapterBinding -IncludeHidden，Enabled 且 ComponentID 非 ms_ 前缀按组件去重 ≥3=FAIL；名单标注 bs_suspects.json 只标注不判定，文件损坏不崩）/ `dv_device_errors`（Win32_PnPEntity，软码 22/45 豁免，高频码 10/12/28/31/43 人话内置，未收录码显码号+指引属性页）/ `dv_driver_load_failures`（Kernel-PnP 219 近 30 天 Level≥Warning（数字 Level 判定语言无关），设备实例路径三段降级提取（EventData XML→含 \ 的 Properties→消息首行），同路径 ≥2 次=「反复」点名护栏）。
- `trees/drivers.yaml`：integrity/stack/suspect 三层聚合取证型，report_name=驱动体检报告，verdict_title=驱动隐患结论；bs_suspect_drivers 跨树复用零改动（先例=v0.3 bs_whea_hardware）。
- **engine v0.5**（大改）：①版本字符串全部处升 v0.5；②多树模式 `-TreeName all`（拍板 10）：依次跑 network/bluescreen/hardware/performance/drivers 五树（版本史序），单树执行管线函数化复用（Invoke-TreeLayers/New-TextReport/HTML 渲染件拆可复用函数），stdout=顶部 banner「diag 全面体检报告 v0.5」+五树单树文本顺序原样输出，落盘仅一份 diag-all-\<stamp\>.html（banner 硬编码「全面体检报告」+五树总览表（树名|结论|FAIL 徽章）+每树 verdict 卡与证据链），任一树 FAIL→EXIT 2；③中文菜单（拍板 9）：all 且 MockDir 空且未带 -NoMenu 才显示（Read-Host 回车=连跑五树/1-5=单跑该树/-Full 与 -OpenReport 照带/非法输入重问 3 次后默认全部）；④reports/ 保留策略（拍板 11）：落盘后（单树与 all 两路径）diag-* 的 .html/.txt/.md 按文件名字典序（=时间戳序）降序保留最新 50 份，删 N>0 输出一行清理回执，非 diag-* 不动，-NoSaveReport 不裁剪。**单树基线锚程序级验证**：v0.4（lite 副本）与 v0.5 同 mock 跑 network 树，stdout 与 HTML 归一版本号+时间戳后逐字节一致（函数化重构零文案漂移）。
- 测试：**130/130 双版本全绿**（5.1+pwsh 7；118 单测=92 旧+26 新（dv×26）+12 场景=9 旧+3 新）。新单测 28-33 节覆盖 design 全部负例+FAIL suggestion 关键词断言+名单注入（dv_network_filters -SuspectsFile）；新场景 dv_full_clean（三层全通）/dv_local_case（三层全故障 -Full）/all_trees_merge（tree='all' 断言总 banner+五树报告头，runner 零改动）。
- 真机验收（本机，非管理员）：**stack 层真命中断点**=第三方驱动 34 个超 30 工程线+网络过滤 4 层（NPCAP×2+**nt_nnndisfilter 带给梨名单标注**+Realtek——与蓝屏树 1019 证据交叉一致）；suspect 层 bs_suspect_drivers FAIL 必中（nnndisfilter Running）+dv_driver_load_failures 真命中 130 条（PCI 显卡/ROOT\DISPLAY 各 ×65 反复）；integrity 层诚实 PASS（34 个非微软全 Valid——给梨驱动本身有签名，靠名单层报它=设计分工正确；古董 0，最早 2021-11-30；未见正规厂商 NotSigned 目录签名误报，无需登记）。总入口 -TreeName all -NoMenu -Full：五树齐跑 EXIT 2，各树结论与单跑一致，合并 HTML 结构断言 12/12（总览表/树节×5/断点层默认展开/给梨标注/零 JS）。裁剪实测：造 55 份假最旧 diag-aa-*+1 个非 diag 占位→跑引擎→「已删 16 份」回执+总数 50+最旧 16 个假文件被删+11 份真实报告全保留+占位不动。网络树回归：断点 DNS 层与既有一致（CLI 断点路径无回归）。
- lite v0.5：6 dv checks+drivers.yaml+engine（v0.5）复制（字节级+BOM 逐文件复验）；第五启动器**驱动体检.bat**+总入口**全面体检.bat**（ASCII+CRLF 无 BOM 无裸 LF，反斜杠 chr(92) 显式造，od 验字节；原四 bat 一字不动）；使用说明升 v0.5 六入口（含 reports 50 份自动清理告知）；**diag-lite-v0.5.zip**（51 条=34 ps1+5 trees+engine+3 json+6 bat+说明+reports 占位；包内字节级抽验：engine 无 v0.4 残留、bat CRLF、dv BOM 齐、实跑报告不进包）。彩排：桌面全新中文+空格路径（测试 目录 体检工具 v05）解压→全面体检.bat 实跑喂回车=菜单真交互「本轮连跑五树」→合并报告落盘+五树报告头全 HIT；驱动体检.bat 实跑→单树报告落盘+给梨命中。彩排目录已清理。
- 返工实锤（本片三坑，如实记）：①engine 注释里的历史版本字样漏清（"v0.4 起替代记事本"）——lite 复制后才被 zip 抽验抓到，重修主档+lite 同步+测试双版本复跑 130/130 确认零影响（**复制前先跑 zip 级抽验的断言，复制后同步再验**）；②HTML 函数化拼接 AppendLine 双重换行=部件间多空行——单树 HTML 与 v0.4 字节级 diff 抓到（外层改 Append 修复），**重构渲染必须跑归一化字节对比而非只看关键词**；③bash heredoc 写 python 测试脚本吃 \x 十六进制转义（Windows 路径反斜杠）——改 Write 落 .py 文件+raw string（R3 python heredoc 坑的变体，文件级中转根治）。

## 2026-10-20 v0.4 性能树实现片（第七切片）

- 目标：design 第十一节性能树落地（7 检查项+树+测试，判定语义一字不改）。施工单= 施工单-v0.4-性能.md（拍板=用户当轮确认，HANDOFF 乙区 diag 行同步）。素材口径=无新真实样本，凭微软官方命令域实证设计（路书闸已标，禁发群维持）。
- 7 个只读检查项（checks/pf_*）：`pf_boot_duration`（官方日志 id=100 近 5 次开机时长，Warning/Critical≥2 或均值>60s=FAIL；BootTime 从 EventData XML 抓=语言无关）/ `pf_boot_degradation_events`（同日志 30 天 id=101/103 点名事件，只收实拍确认过的 ID）/ `pf_startup_items`（Win32_StartupCommand+pf_suspects.json 空名单起步；>20 项=负担线；注明不反映任务管理器已禁用状态）/ `pf_service_timeouts`（SCM 7000/7009/7011 30 天史，官方 30000 毫秒口径）/ `pf_disk_space`（系统盘 10%/20GB 双工程线）/ `pf_memory_pressure`（4GB=Win11 官方线；commit>90%=卡顿进行时；不用"空闲物理内存低"判定）/ `pf_disk_saturation`（队列>2 经典工程线，2 秒双采样防瞬时误报；15ms 只附读数不立判据）。
- `trees/performance.yaml`：boot/startup/runtime 三层聚合取证型，report_name=性能体检报告，verdict_title=性能瓶颈结论。engine 全部 7 处版本字符串升 v0.4（随片升版惯例），判定/渲染零改动。
- 测试：**101/101 双版本全绿**（5.1+pwsh 7；92 单测=59 旧+33 新+9 场景=7 旧+2 新）。新场景：pf_full_clean（全健康三层全通）/pf_local_case（三层全故障 -Full 攒证据）。
- 真机验收（非管理员）：**startup 层真命中 FAIL**=服务超时 93 条（7000 AndrowsSvr ×63+Steam Client Service 7000×15/7009×15——服务层迟钝实证）；runtime 层真读数全 PASS（6 盘水位/15.8GB 内存 commit 44%/队列 0）；boot 层诚实 SKIP+PASS（Diagnostics-Performance 日志本机无 id=100 事件→no-data SKIP；101/103 近 30 天 0 条→PASS）。验收判据「全树零崩溃+真读数或诚实 SKIP」达成；101/103 实拍未见 102/106/108/110→不扩收（铁则遵守）。网络/蓝屏/硬件三树真机回归无恙（EXIT 码与既有断点一致，横幅 v0.4）。
- **真机抓到并修掉三处实况 bug（本片返工实锤）**：①Get-WinEvent 无匹配事件的中文消息"找不到与指定的选择条件匹配的事件"不被英文 'No events' 匹配→0 条被误判 SKIP（应 PASS）——匹配扩 'No events|找不到'；②7009 服务名提取错位（本机实拍 P[0]=毫秒数、P[1]=服务名、P[2]=二进制尾巴）→改自适应提取「首个非纯数字参数」，两语言皆准；③Diagnostics-Performance 日志需管理员权限（ListLog 实证）→SKIP 证据附「管理员身份运行可复核」（同 v0.3 SMART 先例）。修后双版本 101/101 复跑绿+真机复跑 EXIT=2 正确。
- 空名单坑（烟测期抓掉）：`suspects: []` 被 `-not $suspects` 判 falsy→误报"JSON 损坏"SKIP——改为显式区分「suspects 属性缺失=损坏」与「空数组=合法空名单」。v0.4 名单空起步所以此路径必经，单测已固化（25 项用例即跑在真名单空态下）。
- lite v0.4：7 pf checks+pf_suspects.json+performance.yaml+engine（v0.4）复制进 diag-lite/（BOM 逐文件验证）；第四启动器**性能体检.bat**（ASCII+CRLF 字节级验证：无 BOM/18 对 CRLF/无裸 LF/CR；engine\run.ps1 反斜杠按 chr(92) 显式造，1019 旧坑不复发）；使用说明升 v0.4 四入口；**diag-lite-v0.4.zip**（42 文件=31 checks+4 trees+engine+reports 占位+说明+4 bat；reports 实跑报告 3 份不进包；engine 7 处 v0.4 无 v0.3 残留抽验）。彩排：桌面全新中文+空格路径解压→真跑 bat 本体（5.1 链）→HTML 落盘+6 关键词全中。
- 中断复制坑（打包期抓掉）：lite 同步脚本在 pf_suspects.json 断言处中断，排其后的 performance.yaml/engine 漏复制→首包 zip 内 engine 仍 v0.3；补复制+断言改在打包后抽验（包内字节级）——**复制脚本必须全量跑完再打包，抽验以 zip 内字节为准**。

## 2026-10-20 v0.3 硬件树实现片（第六切片）

- 目标：design 第十节硬件树落地（5 检查项+树+测试，判定语义一字不改）。前半程（5 检查项落盘 BOM 5/5、hardware.yaml、16 单测、2 场景）由 5.3 会话 1020 14:37 完成；本会话（flash 接棒）跑完后半程：双版本测试→真机验收→lite 打包→记账。
- 测试：**66/66 双版本全绿**（5.1+pwsh 7；实测分解=59 单测〔41 旧+18 hw 新〕+7 场景，施工单原记"46 旧+16 新"为漏计）。首跑 63/66：hw_smart_predict/hw_thermal 共 3 个 FAIL 分支 evidence 只附原始读数行、人话结论只写进 suggestion，与 design「FAIL 附人话：哪块盘哪个指标在报警」不符——修 checks：FAIL evidence 追加结论行（smart 附 findings 全文、thermal 附「热区过热（>75℃）：各区读数」），状态/阈值/suggestion 零改动。
- 真机验收（本机，非管理员）：storage=PASS（3 盘全 Healthy）+SMART SKIP（**Access denied 终审分支实况命中**）；power_thermal=双 SKIP（台式无电池；热区 CIM 资源不可达→query-error SKIP 路径实况验证）；memory_board=**双 FAIL**（hw_memdiag_history 10-13 有 1101 真实命中，1201 只陈列不判定；bs_whea_hardware 10-04 与蓝屏树 1019 实测证据一致）——design 验收判据「memory_board 层命中且与蓝屏树证据一致」达成；report_name=硬件体检报告 生效，SKIP 反话术在报告实文。
- lite v0.3：5 hw checks+hardware.yaml 复制进 diag-lite/（BOM 5/5 复验）；第三启动器**硬件体检.bat**（ASCII+CRLF，同 v0.2 模板，原两 bat 未动）；使用说明升 v0.3 三入口；**diag-lite-v0.3.zip**（32 条=25 旧+7 新零删减；reports/ 只装占位说明，10-19 彩排 txt 不进包；包内 bat 字节级复验）。
- 返工实锤（本坑记录）：bat 首版 `engine\run.ps1` 的 `\r` 被写成真 CR 字节（bash 内联 python 多层转义剥离失配，PowerShell 实跑报 engineun.ps1 才抓到）——**bash 内联 python 写含反斜杠内容一律 chr(92) 显式造**，写入后 od 验字节；修复后 bat 实跑全链通（报告落盘+浏览器自动开+断点结论正确）。
- 登记（范围外发现）：①lite 引擎报告横幅仍自印 v0.2.1——用户当轮拍板"该修就修"，已修：engine/run.ps1 全部 7 处版本字符串 v0.2.1→v0.3（测试断言零版本引用，66/66 双版本复跑绿；lite 引擎同步；报告抬头/落款实测 v0.3；zip 重打包复验）；②使用说明.txt 三入口更新=施工单未列，按"lite 同步"题中之义补做（报备）。

## 2026-10-20 v0.2.1 HTML 报告片（第五切片）

- 目标：界面升级路线第一片（1019 用户令：抵触记事本观感）——报告渲染层改 HTML，只改"怎么显示"不改"怎么判"。
- engine v0.2.1：落盘产物 txt→**HTML 单文件**（reports/diag-\<树\>-\<时间戳\>.html）；`-OpenReport` 由记事本改走文件关联开**默认浏览器**；版本号三处升 v0.2.1。**stdout 文本报告逐字不动**（测试基线锚）；判定逻辑/检查项/树文件/码书/名单零改动。
- HTML 渲染：内嵌 CSS 零 JS 零外链（断网可用、单文件可转发）；深蓝横幅+白卡片配色，PASS 绿/FAIL 红/SKIP 灰状态徽章；**证据链按层 `<details>` 原生折叠**（断点层默认展开、通过/跳过层收起，summary 带层状态+检查项统计）；**修复建议按检查项分段卡片**（suggestion 原文 pre-wrap）；evidence/suggestion 全量 HTML 转义（Escape-Html，防原始输出特殊字符破坏页面）。数据源与文本报告同一 `$layerResults`，报告头按树渲染逻辑（verdict_title/report_name）沿用。
- 测试：**46/46 双版本全绿不动一兵**（5.1+pwsh 7，tests/ 三件套零改动；场景断言只查 stdout，文本未动故基线天然保持）。
- 真机验收：网络树断点复现（双网关同跃点冲突，与 1019 一致）+蓝屏树 -Full 三层全中保持（0x139×3/给梨 Running/29 次孤立掉电）；HTML 落盘结构断言全过（doctype/charset/折叠 details/断点层 open/修复卡/关键词五连中）；视觉验收子代理四项 PASS（中文零乱码/配色排版/卡片结构/无溢出重叠）；折叠行为 DOM 级验证（收起层只显标题行+统计，断点层展开证据）。
- lite 同步：engine 复制一致；两个 bat 文案换浏览器口径（ASCII+CRLF 字节级验证；版本横幅 v0.2.1）；使用说明 v0.2.1（记事本→浏览器+.html+折叠提示）；reports 占位文件同步 .html；**diag-lite-v0.2.1.zip**（44KB，26 文件结构同 v0.2）；中文+空格路径解压彩排双入口通过（cmd 真跑 bat 本体、5.1 解释器、HTML 落盘+蓝屏报告五关键词全中）。
- 拍板记录（1019 下放制，本片自行拍板）：①stdout 文本保留=测试锚+黑框进度；②txt 落盘退役（渲染层整体换 HTML，不双产物；浏览器全坏的机器本就上不了网，HTML 记事本仍可开）；③折叠默认态=断点层展开其余收起（结论优先，证据按需）；④零 JS（details/summary 原生，群友环境兼容面最小）；⑤黑框隐藏不做（路书"可隐藏"非硬性，进度感对群友有用，自问节挂账）。

## 2026-10-19 v0.2 蓝屏模块（第四切片）

- 目标：把 1013 蓝屏案取证经验产品化——三层取证聚合树，FAIL≠断点，=「发现蓝屏隐患」。
- engine v0.2：树可选字段 `verdict_title`（报告结论标题，缺省"断点结论"）+ `report_name`（报告大标题按树渲染，缺省保持网络树文案，证据链副标随之切换聚合取证口径）；「N 层全通」按层数动态（4 层仍显示"四层全通"）；版本号 v0.1→v0.2。**网络树 yaml 零改动，报告文案除版本号外逐字不变**。
- 6 个只读检查项（checks/bs_*）：`bs_event_history`（90 天 1001 蓝屏史，码/dump 路径正则提取）/ `bs_powerloss_distinction`（41 与 1001 ±2 分钟配对，孤立 41≥2=掉电死机嫌疑）/ `bs_code_frequency`（同码≥2=慢性病，码书联动、未收录如实标注零瞎编）/ `bs_whea_hardware`（30 天 WHEA 硬件报错）/ `bs_minidump_inventory`（dump 盘点，被清理→PASS 附 WARN）/ `bs_suspect_drivers`（嫌疑名单对照 Running 驱动；名单/码书 JSON 损坏→SKIP 带证据不崩，完工问 1 程序级验证）。
- `trees/bluescreen.yaml`：history 蓝屏史 / attribution 归因（bs_code_frequency+bs_whea_hardware）/ evidence 现场；verdict_title=隐患结论，verdict_all_pass 四无口径。**分层拍板（1019 用户）：码频归 attribution**——design 表格+预期读数+施工单第 7 节三处互证，施工单条目头"history 层"判笔误。
- 测试：**46/46 双版本全绿**（5.1+pwsh 7；单项 24→41 条含 2 条损坏 JSON 注入用例，场景 3→5 个）。runner 扩展：suggestion 关键词断言 / 损坏 JSON 注入（-CodesFile/-SuspectsFile）/ 场景级 tree+full 参数（蓝屏聚合型用 -Full 跑满三层）。
- 真机验收（非管理员账户）：蓝屏树 -Full **三层全中**=3 次蓝屏史（0x00000139×3，09-04/10-10/10-13，与 design 素材实证逐项吻合）+0x139 慢性病码书翻译+WHEA 10-04 一条+dump 3196KB 存活+nnndisfilter Running 命中给梨名单；**额外量化 29 次孤立掉电/死机**（41 共 34 条：配对 5/孤立 29）。网络树回归：断点结论与证据链文案逐字保持，双默认网关同跃点冲突断点复现，无回归。
- lite 同步：`diag-lite-v0.2.zip`（41KB，顶层 diag-lite/ 结构同 v0.1）；**新增「蓝屏体检.bat」**（ASCII+CRLF，-TreeName bluescreen -Full -OpenReport；1019 拍板新增，路书"双击出蓝屏层报告"验收达成，原网络 bat 一字未动）+使用说明 v0.2 双入口版；中文+空格路径解压彩排通过（双入口 exit 2+报告落盘，蓝屏报告五关键词全中）。
- 非管理员实测（完工问 2）：本会话即普通账户——Get-WinEvent 1001/41/WHEA 全部正常出数、Minidump 目录可枚举、Get-CimInstance 正常；SKIP 出口（超时/JSON 损坏）程序级可达，权限拒绝分支本机未触发（权限够）。
- 英文系统口径（完工问 3）：码 `0x[0-9A-Fa-f]{8}` 与 `.dmp` 均 ASCII 恒定；本机 WHEA 消息即英文（判定只数条数，结论正确）=活样张实证；41/1001 配对用 TimeCreated 与消息语言无关。

## 2026-10-19 知识底盘审计片（第三切片）

- 目标：知识来源从"本地单机"升级为"权威可溯源"（用户点名的覆盖面质疑）。
- 对微软官方文档逐项校准网络树 9 项（详见 知识来源.md 校准表）：
  - ✅ 四层推进结构与官方 TCP/IP 排障指南方法论一致，骨架不动
  - ⚠️ 补官方口径 ×2：网关可能禁 ping（FAIL 建议加 nslookup 交叉验证命令）；ICMP 可能被网络拦（公网 ping 建议加交叉验证说明）
  - ➕ 判定增强 ×1：**网关跨网段检测**（微软官方记载故障模式"网关必须与网卡同网段"）——含"信息不足不定罪"保护（route 输出无 On-link 行时跳过判定）
- 蓝屏素材库落盘（指针制，官方总表取材）：`checks/bugcheck_codes.json`（29 高频码，code/name/类别/一句人话/官方链接）+`checks/bs_suspects.json`（嫌疑驱动名单，实证收录制，起步=给梨 nnndisfilter）
- 测试：27/27 双版本全绿（5.1+7，新增"网关跨网段"负例）；真机快跑确认跨段判定无误伤。
- 知识治理三规则入档（知识来源.md）：口径改动必同步账本/无来源不收录/未覆盖域清单对照升级。

## 2026-10-19 v0.1 普及版 diag-lite（第二切片）

- 目标：群友 Windows（Win10/11 自带 PowerShell 5.1）解压→双击「网络体检.bat」→记事本自动弹报告，零安装零依赖。
- 5.1 兼容层：14 个 ps1 全部 UTF-8 带 BOM；`#Requires -Version 5.1`；子进程解释器自引用 `(Get-Process -Id $PID).Path`（5.1/7 通吃）。
- **修掉 5.1 两大坑**：①命令行跨进程传参吃掉 mock 内双引号（网卡名解析全灭）→ mock 改走临时文件 `-MockFile` 传输；②报告编码 →txt+UTF8 BOM 记事本直开。
- 测试：**双版本 26/26 全绿**（Windows PowerShell 5.1 + pwsh 7 各跑一遍）。
- 打包：`diag-lite-v0.1.zip`（23KB：bat 启动器/使用说明/engine/checks/trees/reports），bat 纯 ASCII+CRLF（防 GBK 乱码）。
- 真机验收：模拟群友全链（解压到全新中文+空格路径→跑 bat→报告自动弹出落盘）通过；5.1 链下中文证据零乱码。
- 设计定稿：design.md 落盘（5 条拍板记录）；施工单-v0.1-检查项规格.md（9 项逐项规格+新检查项模板）。

## 2026-10-19 v0.1 网络模块（首个切片）

- engine 骨架：`engine/run.ps1` 读树→逐层执行→FAIL 定位断点→人话报告（stdout + reports/ 落盘）。退出码 0=全通 / 2=有断点 / 3=引擎错误。`-Full` 断点后继续取证；`-MockDir` 全树模拟模式。
- 网络排查树：`trees/network.yaml`（JSON 语法=合法 YAML 1.2 子集；因 powershell-yaml 未装且 diag 必须断网可用，零依赖用内置解析）。
- 9 个只读检查项落地（`checks/`，统一输出 {name, status, evidence, suggestion}）：
  net_adapter_list / net_ip_dhcp / net_gateway_conflict / net_gateway_ping /
  net_dns_deadaddr / net_dns_default / net_dns_gateway_proxy / net_dns_public / net_public_ping
- 模拟测试：`tests/run_tests.ps1` 26/26 绿（23 单项用例含正负例 + 3 全树断点链场景，其中 dns_deadaddr 场景=2026-10-19 原始故障重演）。
- 真机验收通过：报告落盘 `reports/diag-network-20261019-2014*.md`；真机命中真实断点（双默认网关同跃点 35 冲突），并送两个活样本：以太网源出不了公网（src DEAD）+ 192.168.0.1 网关拒绝 DNS（Query refused）。
- 实现决策记录：
  - 树文件用 JSON 语法而非自由 YAML（零依赖，断网可用优先）。
  - 死地址判定=私有地址 DNS 不属于任何活动网卡网段；公共 DNS 不判死（可达性交给 nslookup 项），避免公共 DNS 误报。
  - 多网卡"部分坏"场景：存在 ≥1 可用链路即 PASS，异常记备注（单网卡坏才是断点）。
  - 检查项经 Start-Job 内 `& pwsh` 数组传参调用（规避 Start-Process 命令行空格/中文转义）。

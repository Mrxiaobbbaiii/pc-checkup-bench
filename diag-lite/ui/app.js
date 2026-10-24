'use strict';
/* 电脑体检台 UI · v1.1.0 本体（A 段美化可用性 2026-10-22 + C 段 ext 口子/版本串 2026-10-23）：
   —— v1.1.0 C 段：APP_VERSION 升 v1.1.0；新增 ui/custom.css 可选加载（fetch 探测，缺文件静默）
   —— 结果页：问题优先。按「问题族」展示层归并（跨树同名去重、同一次蓝屏的多项合并），
      严重度三档（高/中/低），「只看问题 / 全部检查项」双视图，每张卡可锚到修复中心；
      SKIP 单独成组并解释「没查成 ≠ 有问题」，缺管理员权限的项给「以管理员重跑」提示。
   —— 修复中心：问题修复置顶，常用修复折叠到最后；同一动作只渲染一次；错配的 match_checks
      在数据层修正，并在卡上补「这项不解决：…」提示。
   —— 页眉合并为「外观」菜单；字号四档；键盘焦点可见；红级指南可整段复制。
   只读承诺、绿/黄/红三级语义、五段修复结果、server/engine 接口全部保持 v1.0.1 原样。 */

const APP_VERSION = 'v1.3.0';

/* v1.1.0 ext 口子：ui/custom.css 存在则加载（免重打包换肤）；不存在=404 静默跳过，控制台零报错 */
fetch('custom.css', { cache: 'no-store' })
  .then((r) => {
    if (!r.ok) return;
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = 'custom.css';
    document.head.appendChild(link);
  })
  .catch(() => {});

const $ = (s, root) => (root || document).querySelector(s);
const $$ = (s, root) => [...(root || document).querySelectorAll(s)];

const S = {
  meta: null,            // /api/meta：五棵树定义（层/检查项/文案）
  expectSeq: [],         // 本轮预期检查序列 [{tree, layer, layerTitle, check}]
  seqPos: 0,
  fast: false,
  appState: 'idle',      // idle | running | done | cancelled | error
  lastSeq: 0,
  htmlUrl: '',
  reportPayload: null,   // /api/report 缓存（结果树+修复中心共用）
  entries: null,         // 展示层归并后的检查项（跨树同名只留一条）
  currentSuggestion: '',
  runStartAt: 0,
  pollTimer: null,
  elapsedTimer: null,
  beatFail: 0,
  repairActions: null,   // /api/repair/list 缓存（null=还没拿到）
  repairBusy: false,     // 本地镜像：修复进行中（禁其他修复/按钮态）
  repairDoneIds: {},     // 已执行过的动作 id → 结果（防重复渲染）
  lastNode: null,        // 结果树最后选中节点
  resultFilter: 'problems',
};

const STATUS_WORD = { PASS: '✓ 正常', FAIL: '✗ 有问题', SKIP: '– 没查成' };
const LAYER_NUM = ['①', '②', '③', '④', '⑤', '⑥'];

/* 检查项人话名映射（纯显示层；数据与修复匹配仍用英文原名） */
const CHECK_HUMAN = {
  net_adapter_list: '网卡与连线', net_ip_dhcp: 'IP 地址获取', net_gateway_conflict: '网关配置冲突',
  net_gateway_ping: '网关连通', net_public_ping: '公网连通', net_dns_deadaddr: 'DNS 死地址',
  net_dns_default: '默认 DNS 配置', net_dns_gateway_proxy: 'DNS 网关代理', net_dns_public: '公共 DNS 解析',
  net_proxy_vpn: '系统代理 / hosts / VPN',
  bs_event_history: '蓝屏记录（近 90 天）', bs_powerloss_distinction: '断电与蓝屏区分', bs_code_frequency: '蓝屏码频次',
  bs_whea_hardware: '硬件报错记录', bs_minidump_inventory: '转储文件盘点', bs_suspect_drivers: '嫌疑驱动名单',
  hw_disk_health: '磁盘健康', hw_disk_errors: '文件系统错误', hw_smart_predict: 'SMART 健康预测', hw_battery_wear: '电池损耗',
  hw_thermal: '温度热区', hw_memdiag_history: '内存诊断史',
  dv_driver_signature: '驱动签名', dv_driver_age: '驱动年代', dv_thirdparty_inventory: '第三方驱动数量',
  dv_network_filters: '网络过滤驱动', dv_device_errors: '设备错误（黄三角）', dv_driver_load_failures: '驱动加载失败',
  pf_boot_duration: '开机用时', pf_boot_degradation_events: '开机变慢事件', pf_startup_items: '开机自启项',
  pf_service_timeouts: '服务超时', pf_disk_space: '磁盘剩余空间', pf_memory_pressure: '内存压力',
  pf_disk_saturation: '磁盘繁忙度', pf_app_crashes: '应用崩溃 / 卡死',
  net_proxy_system: '系统级代理设置', net_tcp_port: '加密端口连通（443）', net_df_ping: '大包传输探测（MTU）',
  net_wlan_signal: 'Wi-Fi 信号强度', net_tcp_stall: '连接卡死统计', pf_uptime: '连续开机时长',
};
function humanCheck(n) { return CHECK_HUMAN[n] || n; }
/* 标签页标题进度：跑批中显示「N% · 电脑体检台」，完成短暂提示后恢复（host 原生壳窗口标题不跟随——单实例 FindWindow 精确匹配约束） */
/* 上次体检时间戳：本机 localStorage 记忆，向导页显示一行（30 天内有效） */
function saveLastRun(sec) {
  try {
    const es = S.entries || [];
    localStorage.setItem('diag-last-run', JSON.stringify({ at: Date.now(), total: es.length, fails: es.filter((e) => e.status === 'FAIL').length, sec: sec }));
  } catch (e) {}
  renderLastRun();
  markGuided(); // 跑过一轮体检：首次引导卡永久收起（独立键，不随 30 天过期回潮）
}
/* 首次启动三步引导（轮7）：无 diag-guided 键=没跑过体检→显示；体检完成写键→本会话收起+以后不再出现 */
function markGuided() {
  try { localStorage.setItem('diag-guided', '1'); } catch (e) {}
  renderFirstGuide();
}
function renderFirstGuide() {
  const el = $('#first-guide'); if (!el) return;
  let seen = false;
  try { seen = !!localStorage.getItem('diag-guided'); } catch (e) {}
  el.classList.toggle('hidden', seen);
}
$('#fg-got-it').addEventListener('click', markGuided); // 用户确认过=不再打扰（1024 用户反馈：确认制）

/* ---------- 版本更新弹窗（1024 用户拍板：更新内容在用户 UI 弹一次；只装最新一版，完整开发史=仓库 CHANGELOG.md） ---------- */
const RELEASE_NOTES = {
  'v1.3.0': [
    '跑完告诉你和上次比修好了几项、新冒出来几项',
    '「历史对比」选两份报告一比，就知道变化',
    '修复中心记「修复小史」：修过什么、成没成',
    '界面明暗自动跟 Windows 走',
  ],
};
(function checkUpdateNotes() {
  let seen = null;
  try { seen = localStorage.getItem('diag-seen-ver'); } catch (e) {}
  if (seen === APP_VERSION) return;
  // 老用户（有使用痕迹）升级后弹一次；全新用户不弹（首次有三步引导卡，不叠弹窗），直接记版本
  let hasTraces = false;
  try {
    hasTraces = !!(localStorage.getItem('diag-guided') || localStorage.getItem('diag-last-run') || localStorage.getItem('diag-theme2'));
  } catch (e) {}
  const notes = RELEASE_NOTES[APP_VERSION];
  try { localStorage.setItem('diag-seen-ver', APP_VERSION); } catch (e) {}
  if (!hasTraces || !notes) return;
  $('#um-title').textContent = '电脑体检台更新到 ' + APP_VERSION;
  $('#um-list').innerHTML = notes.map((t) => '<li>' + esc(t) + '</li>').join('');
  $('#update-modal').classList.remove('hidden');
})();
$('#um-ok').addEventListener('click', () => {
  try { localStorage.setItem('diag-seen-ver', APP_VERSION); } catch (e) {}
  $('#update-modal').classList.add('hidden');
});
function renderLastRun() {
  const el = $('#last-run'); if (!el) return;
  let v = null;
  try { v = JSON.parse(localStorage.getItem('diag-last-run') || 'null'); } catch (e) {}
  if (!v || !v.at || Date.now() - v.at > 30 * 24 * 3600 * 1000) { el.classList.add('hidden'); return; }
  const d = new Date(v.at), pad = (n) => String(n).padStart(2, '0');
  el.textContent = '上次体检：' + (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) +
    ' · 查了 ' + (v.total || 0) + ' 项' + (v.fails ? '，发现 ' + v.fails + ' 个问题' : '，全部正常');
  el.classList.remove('hidden');
}
function setTitleProgress(pct) { document.title = (pct == null ? '' : pct + '% · ') + '电脑体检台'; }

/* 一句话人话解释：每条检查在详情里先讲「这是什么」 */
const CHECK_INFO = {
  net_adapter_list: '电脑认不认得出网卡，网线/无线有没有连上。',
  net_ip_dhcp: 'IP 地址是不是自动获取，有没有拿到有效地址。',
  net_gateway_conflict: '同一个局域网里，有没有两台设备抢同一个网关。',
  net_gateway_ping: '电脑能不能连上路由器（网关）。',
  net_public_ping: '连不连得上外网（用公共地址试）。',
  net_dns_deadaddr: 'DNS 服务器地址是不是一个根本不通的死地址。',
  net_dns_default: '系统默认的 DNS 配置是否正常。',
  net_dns_gateway_proxy: 'DNS 有没有被网关或代理劫持。',
  net_dns_public: '改用公共 DNS 后，能不能正常解析网址。',
  net_proxy_vpn: '系统代理、hosts 文件和 VPN/虚拟网卡有没有在背后改网络。',
  bs_event_history: '最近 90 天有没有蓝屏记录。',
  bs_powerloss_distinction: '区分是断电重启，还是真的蓝屏。',
  bs_code_frequency: '同一个蓝屏代码是不是反复出现。',
  bs_whea_hardware: 'Windows 有没有记录硬件级报错（WHEA）。',
  bs_minidump_inventory: '有没有留下蓝屏转储文件，可供分析原因。',
  bs_suspect_drivers: '蓝屏记录里有没有反复出现的嫌疑驱动。',
  hw_disk_health: '硬盘自检（SMART）状态是否健康。',
  hw_disk_errors: '硬盘文件系统有没有报结构损坏或写入延迟（NTFS 事件）。',
  hw_smart_predict: '用 SMART 数据预测硬盘会不会很快坏。',
  hw_battery_wear: '笔记本电池损耗到什么程度。',
  hw_thermal: 'CPU、硬盘温度有没有过热。',
  hw_memdiag_history: '以前跑过的内存诊断有没有报过错。',
  dv_driver_signature: '驱动有没有正规数字签名。',
  dv_driver_age: '驱动是不是太老了。',
  dv_thirdparty_inventory: '装了多少第三方驱动（越少越稳）。',
  dv_network_filters: '网络过滤驱动有几层（某些加速器、杀软会加层）。',
  dv_device_errors: '设备管理器里有没有黄色感叹号。',
  dv_driver_load_failures: '驱动加载失败的次数多不多。',
  pf_boot_duration: '开机用了多久。',
  pf_boot_degradation_events: '有没有「开机明显变慢」的记录。',
  pf_startup_items: '开机自启项有多少、占不占资源。',
  pf_service_timeouts: '系统服务有没有频繁超时。',
  pf_disk_space: '磁盘还剩多少空间。',
  pf_memory_pressure: '内存够不够用，有没有频繁换页。',
  pf_disk_saturation: '磁盘是不是长期 100% 忙。',
  pf_app_crashes: '最近 30 天有哪些应用反复崩溃或卡死。',
  net_proxy_system: '系统底层（服务级 / 用户级）有没有被设置代理服务器。',
  net_tcp_port: '能不能跟外网建立加密连接（443 端口，浏览器上网都靠它）。',
  net_df_ping: '大个数据包能不能顺利过线路（有些网络会卡大包，表现为网页只开一半）。',
  net_wlan_signal: 'Wi-Fi 信号够不够强，太弱会网速慢、时断时续。',
  net_tcp_stall: '有没有一堆网络连接卡在「正在连接」不动（线路拥塞或软件占线的迹象）。',
  pf_uptime: '电脑连续开了多久，太久不停机会累积小毛病。',
};

/* 严重度三档（纯显示层，不参与判定）：高=要尽快处理，中=建议处理，低=知道就行 */
const CHECK_SEVERITY = {
  bs_event_history: 'high', bs_code_frequency: 'high', bs_minidump_inventory: 'high',
  bs_whea_hardware: 'medium', bs_suspect_drivers: 'medium', bs_powerloss_distinction: 'low',
  hw_smart_predict: 'high', hw_thermal: 'high', hw_memdiag_history: 'high', hw_disk_health: 'medium',
  hw_battery_wear: 'low',
  net_adapter_list: 'high', net_public_ping: 'high', net_gateway_ping: 'medium', net_ip_dhcp: 'medium',
  net_gateway_conflict: 'medium', net_dns_deadaddr: 'medium', net_dns_default: 'medium',
  net_dns_public: 'medium', net_dns_gateway_proxy: 'medium',
  dv_driver_signature: 'medium', dv_device_errors: 'high', dv_network_filters: 'medium',
  dv_driver_load_failures: 'medium', dv_driver_age: 'low', dv_thirdparty_inventory: 'low',
  pf_disk_space: 'high', pf_memory_pressure: 'medium', pf_disk_saturation: 'medium',
  pf_service_timeouts: 'medium', pf_boot_degradation_events: 'medium', pf_boot_duration: 'low',
  pf_startup_items: 'low', pf_app_crashes: 'medium',
  hw_disk_errors: 'high', net_proxy_vpn: 'medium',
  net_proxy_system: 'medium', net_tcp_port: 'medium', net_df_ping: 'medium',
  net_wlan_signal: 'medium', net_tcp_stall: 'medium', pf_uptime: 'low',
};
const SEV_META = {
  high: { word: '高', desc: '要尽快处理', cls: 'high' },
  medium: { word: '中', desc: '建议处理', cls: 'medium' },
  low: { word: '低', desc: '知道就行', cls: 'low' },
};
function checkSeverity(name) { return CHECK_SEVERITY[name] || 'medium'; }
const SEV_RANK = { high: 0, medium: 1, low: 2 };

/* 展示层问题族：把几十个检查项归成人能看懂的问题清单；note 解释「这几项可能是一件事」 */
const PROBLEM_GROUPS = [
  { id: 'bsod', title: '蓝屏与稳定性', prefix: 'bs_', note: '蓝屏记录、蓝屏码频次、转储文件盘点说的可能是同一件事：最近蓝屏过。硬件报错和嫌疑驱动也放这里一起看。' },
  { id: 'network', title: '上网与网络', prefix: 'net_', note: '按「网卡 → IP → 网关 → 公网 → DNS → 应用层（代理/hosts/VPN）」的顺序查，通常是链路上某一环断了。' },
  { id: 'hardware', title: '硬件健康', prefix: 'hw_', note: '硬盘、文件系统、内存、温度这些硬件项的体检结果；「没查成」多半是没权限或机器没有这个部件。' },
  { id: 'driver', title: '驱动', prefix: 'dv_', note: '驱动越老、越多、越没签名，系统越容易不稳；网络过滤层多了也可能拖慢上网。' },
  { id: 'app', title: '应用崩溃与卡死', prefix: 'pf_app_', note: '同一个软件反复崩溃/卡死时看这里；多个不同软件都崩，也可能是内存/驱动问题。' },
  { id: 'perf', title: '开机与运行速度', prefix: 'pf_', note: '开机用时、自启项、服务超时、内存和磁盘压力——电脑慢往往不是单一原因。' },
];
function groupFor(name) {
  const g = PROBLEM_GROUPS.find((x) => name.indexOf(x.prefix) === 0);
  return g || { id: 'other', title: '其他', note: '' };
}

/* ---------- 先修这个（v1.4.0 轮1）：根因关联规则表 ----------
   跨树交叉定位——同一元凶的多项 FAIL 合并成一个行动项（如嫌疑驱动+网络过滤层+蓝屏码频次
   → 一个根因：过滤驱动）。命中门槛=规则 checks 里 ≥minHits 项 FAIL（单项不硬凑根因，归普通行动项）。
   排序分 score = 收益 gain × 把握 conf ÷ 风险 risk（手工标定，宁稳勿激进），而非纯严重度。
   纯前端展示层，判定逻辑零碰。target.action=跳修复中心对应动作卡；target.check=跳该项说明。 */
const CORR_RULES = [
  { id: 'disk_dying', title: '最要紧的一件事：硬盘在变坏，先备份数据', minHits: 2,
    checks: ['hw_disk_health', 'hw_smart_predict', 'hw_disk_errors'],
    why: '磁盘健康和文件系统错误同时报警，硬盘多半在变坏。第一步永远是先把重要数据备份出来，再谈修。',
    gain: 5, risk: 1, conf: 0.9, target: { check: 'hw_disk_health' } },
  { id: 'filter_driver', title: '一个根因：网络过滤驱动在捣乱', minHits: 2,
    checks: ['bs_suspect_drivers', 'dv_network_filters', 'bs_code_frequency'],
    why: '蓝屏嫌疑驱动和网络过滤层同时点名，多半是同一个加速器/安全软件捆绑的过滤驱动——按一张卡处理，蓝屏和断网一起收。',
    gain: 5, risk: 3, conf: 0.8, target: { action: 'dv_filter_handling' } },
  { id: 'dns_side', title: '一个方向：DNS 配置坏了', minHits: 2,
    checks: ['net_dns_deadaddr', 'net_dns_default', 'net_dns_public'],
    why: 'DNS 相关多项同时出问题，指向 DNS 地址配置本身。改成公共 DNS（阿里/腾讯）一招可解，能自动改、可撤销。',
    gain: 4, risk: 1.5, conf: 0.85, target: { action: 'net_dns_public_set' } },
  { id: 'driver_residue', title: '一个方向：设备驱动有残留或没装好', minHits: 2,
    checks: ['dv_driver_load_failures', 'dv_device_errors'],
    why: '驱动加载失败和设备报错同时出现，常见于换过硬件/重装系统后驱动没清干净。先重扫设备，再按显卡残留卡清理。',
    gain: 4, risk: 3, conf: 0.7, target: { action: 'dv_device_rescan' } },
  { id: 'mem_hw', title: '一个方向：内存或供电不稳', minHits: 2,
    checks: ['bs_whea_hardware', 'hw_memdiag_history', 'pf_app_crashes'],
    why: '硬件报错记录和多应用崩溃同时出现，优先怀疑内存（跑一次内存诊断），笔记本再查电池供电。',
    gain: 4, risk: 4, conf: 0.7, target: { action: 'bs_attribution_card' } },
  { id: 'proxy_mess', title: '一个方向：代理在背后改网络', minHits: 2,
    checks: ['net_proxy_vpn', 'net_proxy_system', 'net_tcp_stall'],
    why: '系统级和应用层同时查到代理配置，多半是装软件/加速器时留下的。先一键重置系统代理，再人工清应用层。',
    gain: 3, risk: 1.5, conf: 0.75, target: { action: 'net_winhttp_reset' } },
  { id: 'boot_burden', title: '一个方向：开机负担太重', minHits: 2,
    checks: ['pf_boot_duration', 'pf_boot_degradation_events', 'pf_startup_items'],
    why: '开机慢+自启项多+系统点名拖慢启动的软件，三件事往往是同一批软件造成的。清一清自启就见效。',
    gain: 3, risk: 1, conf: 0.8, target: { check: 'pf_startup_items' } },
];
function corrScore(r) { return (r.gain * r.conf) / r.risk; }

/* 先修这个：渲染行动区。两层结构——①根因合并项（规则命中，按 score 排序在前）
   ②单项行动项（未被规则覆盖的 FAIL 项，按严重度排）。每项带一键跳转：
   有匹配动作的跳修复中心对应卡，没有的跳该项说明（详情面板）。全部 FAIL 必有着落，禁静默断链。 */
function renderFirstFix() {
  const box = $('#first-fix');
  if (!box) return;
  const entries = S.entries || [];
  const fails = entries.filter((e) => e.status === 'FAIL');
  if (!S.reportPayload || !fails.length) { box.classList.add('hidden'); box.innerHTML = ''; return; }

  const byName = new Map(fails.map((e) => [e.name, e]));
  const ruleItems = [];
  const covered = new Set();
  CORR_RULES.forEach((r) => {
    const hits = r.checks.filter((n) => byName.has(n));
    if (hits.length < r.minHits) return;
    hits.forEach((n) => covered.add(n));
    ruleItems.push({ rule: r, hits });
  });
  ruleItems.sort((a, b) => corrScore(b.rule) - corrScore(a.rule));

  box.innerHTML = '';
  const title = document.createElement('div');
  title.className = 'card-title';
  title.textContent = '先修这个';
  box.appendChild(title);
  const intro = document.createElement('div');
  intro.className = 'ff-intro';
  intro.textContent = '按「值得先修的程度」排序（修好能解决多少问题 ÷ 风险 × 把握），不是按严重度吓人。每条都能一键跳到处理办法。';
  box.appendChild(intro);

  ruleItems.forEach(({ rule, hits }) => {
    const item = document.createElement('div');
    item.className = 'ff-item';
    item.dataset.rule = rule.id;
    const head = document.createElement('div');
    head.className = 'ff-head';
    const tag = document.createElement('span');
    tag.className = 'ff-tag';
    tag.textContent = '合并看';
    const t = document.createElement('b');
    t.textContent = rule.title;
    head.appendChild(tag); head.appendChild(t);
    item.appendChild(head);
    const why = document.createElement('div');
    why.className = 'ff-why';
    why.textContent = rule.why;
    item.appendChild(why);
    const chips = document.createElement('div');
    chips.className = 'ff-chips';
    hits.forEach((n) => {
      const chip = document.createElement('button');
      chip.className = 'ff-chip';
      chip.textContent = humanCheck(n);
      chip.addEventListener('click', () => { switchView('results'); renderCheckDetail(byName.get(n)); });
      chips.appendChild(chip);
    });
    item.appendChild(chips);
    const btnRow = document.createElement('div');
    btnRow.className = 'ff-btns';
    const go = document.createElement('button');
    go.className = 'btn-primary';
    go.textContent = '去处理';
    go.addEventListener('click', () => {
      if (rule.target.action) focusActionCard(rule.target.action);
      else if (rule.target.check && byName.has(rule.target.check)) { switchView('results'); renderCheckDetail(byName.get(rule.target.check)); }
      else focusRepair(hits);
    });
    btnRow.appendChild(go);
    item.appendChild(btnRow);
    box.appendChild(item);
  });

  const singles = fails.filter((e) => !covered.has(e.name))
    .sort((a, b) => (SEV_RANK[checkSeverity(a.name)] - SEV_RANK[checkSeverity(b.name)]) || a.name.localeCompare(b.name));
  singles.forEach((e) => {
    const item = document.createElement('div');
    item.className = 'ff-item single';
    item.dataset.check = e.name;
    const head = document.createElement('div');
    head.className = 'ff-head';
    const tag = document.createElement('span');
    tag.className = 'ff-tag sev';
    tag.textContent = SEV_META[checkSeverity(e.name)].word;
    const t = document.createElement('b');
    t.textContent = humanCheck(e.name);
    head.appendChild(tag); head.appendChild(t);
    item.appendChild(head);
    const act = (S.repairActions || []).find((a) => (a.match_checks || []).indexOf(e.name) >= 0);
    const why = document.createElement('div');
    why.className = 'ff-why';
    why.textContent = act ? '修复中心有对应办法：' + act.name + (act.level === 'green' ? '（能自动修）' : act.level === 'yellow' ? '（确认后自动修）' : '（按步骤来）') : '点开看这项的处理建议。';
    item.appendChild(why);
    const btnRow = document.createElement('div');
    btnRow.className = 'ff-btns';
    const go = document.createElement('button');
    go.className = 'btn';
    go.textContent = '去处理';
    go.addEventListener('click', () => { if (act) focusActionCard(act.id); else { switchView('results'); renderCheckDetail(e); } });
    btnRow.appendChild(go);
    item.appendChild(btnRow);
    box.appendChild(item);
  });

  box.classList.remove('hidden');
}

/* 锚到修复中心某张动作卡（按动作 id；先修这个的行动项跳转用） */
function focusActionCard(actionId) {
  switchView('repair');
  requestAnimationFrame(() => {
    const target = $$('#repair-list .action-card').find((c) => c.dataset.actionId === actionId);
    if (!target) return;
    target.scrollIntoView({ behavior: 'smooth', block: 'center' });
    target.classList.add('flash');
    setTimeout(() => target.classList.remove('flash'), 2100);
  });
}

/* 术语小抄：第一次用的人不读说明也能对上号 */
const GLOSSARY = {
  'SKIP（没查成）': '这次没查成，既不是正常，也不是发现问题。常见原因：要管理员权限、机器没这个硬件、系统没留记录。按提示处理后可重跑。',
  'WHEA': 'Windows 硬件错误架构记录。出现 WHEA 往往指向内存、CPU、硬盘等硬件或电源问题，不是普通软件报错。',
  '驱动过滤层': '夹在系统和网卡之间的驱动（杀软、加速器、VPN 常会装）。层数多不一定是坏事，但网络出问题时它们是嫌疑对象。',
  '还原点': 'Windows 的系统快照。修复前建一个，出问题可以整体退回去。',
  '转储文件（.dmp）': '蓝屏时系统写下的现场记录，用来分析是哪个驱动或硬件导致蓝屏。',
  '0x139': '一个蓝屏错误代码，全称 KERNEL_SECURITY_CHECK_FAILURE，常见于驱动或内存问题。',
  '管理员权限': 'Windows 的最高操作权限。硬盘 SMART、温度等检查和部分修复需要它；右键程序选「以管理员身份运行」。',
  '第三方驱动': '不是微软自带、由其他软件安装的驱动。',
  '快速模式': '每一类查到问题就跳过该类剩余细项，更快，但证据会少一些。',
  '内存压力': '物理内存不够时，系统把数据挪到硬盘，表现为卡顿。',
  'MTU': '网络一次能传多大的数据包。有些线路卡大包（MTU 黑洞），表现为网页只开一半、图片加载不出。',
};

const ADMIN_SKIP_TEXT = '这项要管理员权限才能查。右键「全面体检.bat」→「以管理员身份运行」，再跑一轮就能看到结果。';
const ADMIN_SKIP = {
  hw_smart_predict: '这项要读硬盘的 SMART 数据，Windows 只允许管理员读。右键「全面体检.bat」→「以管理员身份运行」再跑一轮。',
  hw_thermal: '读温度传感器要管理员权限。右键「全面体检.bat」→「以管理员身份运行」再跑一轮。',
};
const SKIP_TAG = {
  hw_battery_wear: '机器没电池',
  pf_boot_duration: '系统没留记录',
  hw_memdiag_history: '系统没留记录',
};

function statusWord(st) { return STATUS_WORD[st] || '– 没查成'; }
function exitHuman(code) {
  if (code === 0) return '全部正常';
  if (code === 2) return '发现问题，点左边看哪里坏了';
  if (code === 3) return '程序出错';
  return '异常退出（代码 ' + code + '）';
}
function setStatus(text, cls) {
  const el = $('#status-left');
  el.textContent = text;
  el.className = cls || '';
  el.dataset.state = cls === 'err' ? 'stop' : (/^正在/.test(text) ? 'running' : 'idle');
}
function setCurrent(text) { $('#current-label').textContent = text; }
function addLog(text, cls) {
  const box = $('#log-box');
  const ln = document.createElement('div');
  ln.className = 'ln ' + (cls || '');
  ln.textContent = text;
  box.appendChild(ln);
  box.scrollTop = box.scrollHeight;
}

/* ---------- 视图切换 ---------- */
function switchView(name) {
  $$('.view').forEach((v) => v.classList.remove('active'));
  $('#view-' + name).classList.add('active');
  $$('.tab').forEach((t) => {
    const on = t.dataset.view === name;
    t.classList.toggle('active', on);
    t.setAttribute('aria-selected', on ? 'true' : 'false');
  });
  if (name === 'repair') { buildRepairList(); loadRepairHistory(); }
  if (name === 'results') updateResultsShell();
  if (name === 'history') loadHistory();
}
$('#tabs').addEventListener('click', (e) => {
  const t = e.target.closest('.tab');
  if (t) switchView(t.dataset.view);
});

/* 心跳：页面存活=server 存活；窗关=心跳断→server 杀引擎自杀 */
setInterval(() => {
  fetch('/api/heartbeat', { method: 'POST', cache: 'no-store' }).catch(() => {});
}, 1000);

/* ---------- 勾选逻辑（勾全面=五树联动勾选并禁用单改） ---------- */
function buildChecks() {
  const grid = $('#check-grid');
  S.meta.trees.forEach((t) => {
    const isExt = !!t.ext;   // v1.1.0：ext 扩展树不属于「全面体检」（engine all=内置五树），默认不勾、联动不带上
    const label = document.createElement('label');
    label.className = 'check-item tree-item' + (isExt ? ' ext-item' : '');
    label.dataset.tree = t.id;
    label.title = t.tip + (isExt ? '（扩展树：不属于「全面体检」，单独勾它单跑）' : '');
    label.innerHTML = '<input type="checkbox" class="chk-tree"' + (isExt ? '' : ' checked') + '>' +
      '<span class="box"></span>' +
      '<span class="txt"><b>' + esc(t.name) + '（' + esc(t.desc) + '）</b></span>';
    grid.appendChild(label);
  });
  const all = $('#chk-all');
  const setTreeDisabled = (locked) => {
    $$('.tree-item').forEach((it) => {
      it.querySelector('input').disabled = locked;
      it.classList.toggle('disabled', locked);
    });
  };
  setTreeDisabled(all.checked);
  all.addEventListener('change', () => {
    $$('.tree-item').forEach((it) => {
      it.querySelector('input').checked = all.checked && !it.classList.contains('ext-item');
    });
    setTreeDisabled(all.checked);
    updateSelUi();
  });
  $$('.tree-item input').forEach((inp) => inp.addEventListener('change', updateSelUi));
  $('#chk-fast').addEventListener('change', updateSelUi);
}
function getSelectionForm() {
  // v1.1.0：all=内置五树全勾且 ext 树没勾；ext 树只能单独选一棵跑
  const builtinTotal = $$('.tree-item:not(.ext-item)').length;
  const builtinChecked = $$('.tree-item:not(.ext-item) input:checked').length;
  const extChecked = $$('.tree-item.ext-item input:checked').length;
  if (builtinChecked === builtinTotal && extChecked === 0) return 'all';
  const picked = $$('.tree-item input').filter((i) => i.checked).map((i) => i.closest('.tree-item').dataset.tree);
  if (picked.length === 1) return picked[0];
  if (picked.length === 0) return 'none';
  return 'invalid-2-4';
}
function treeCheckCount(t) {
  return (t.layers || []).reduce((n, l) => n + (l.checks || []).length, 0);
}
function updateSelUi() {
  if (S.appState === 'running') return;
  const btn = $('#btn-run');
  btn.classList.remove('running', 'danger');
  const sel = getSelectionForm();
  const hint = $('#sel-hint');
  if (S.appState === 'idle') {
    if (sel === 'invalid-2-4') {
      btn.disabled = true;
      hint.textContent = '只支持查一类或全部——勾 2 到 4 类不行。要么全选，要么只留一类。';
      hint.className = 'hint warn';
      setStatus('选择不合法：勾 2 到 4 类不行', '');
    } else if (sel === 'none') {
      btn.disabled = true;
      hint.textContent = '至少勾一类再开始。';
      hint.className = 'hint warn';
      setStatus('先勾选要查的项目', '');
    } else {
      btn.disabled = false;
      const tree = sel === 'all' ? null : S.meta.trees.find((t) => t.id === sel);
      const n = tree ? treeCheckCount(tree) : 0;
      hint.textContent = tree
        ? '将只查「' + tree.name + '」这一类，共 ' + n + ' 项 · 只读，不改任何设置'
        : '将查五类全部 · 预计 1–3 分钟 · 只读，不改任何设置';
      hint.className = 'hint';
      setStatus('就绪', '');
    }
    btn.textContent = '开始体检';
  } else {
    btn.disabled = false;
    btn.textContent = '再跑一次';
    hint.textContent = '上轮已结束。点「再跑一次」可以重新选、重新查。';
    hint.className = 'hint';
  }
}

/* ---------- 跑批启动 / 取消 ---------- */
$('#btn-run').addEventListener('click', () => {
  if (S.appState === 'running') { cancelRun(); return; }
  if (S.appState !== 'idle') { resetToIdle(); return; }
  startRun();
});

async function startRun(opts) {
  opts = opts || {};
  const sel = getSelectionForm();
  if (!opts.tree && (sel === 'none' || sel === 'invalid-2-4')) return;
  const treeArg = opts.tree || sel;
  S.fast = opts.fast !== undefined ? !!opts.fast : $('#chk-fast').checked;
  S.expectSeq = [];
  S.meta.trees.forEach((t) => {
    if (treeArg !== 'all' && t.id !== treeArg) return;
    t.layers.forEach((l) => {
      l.checks.forEach((c) => {
        S.expectSeq.push({ tree: t.id, layer: l.name, layerTitle: l.title, check: c });
      });
    });
  });
  S.seqPos = 0; S.lastSeq = 0; S.beatFail = 0;
  S.appState = 'running'; setTitleProgress(0);
  S.reportPayload = null; S.entries = null; S.htmlUrl = '';
  try {
    const r = await fetch('/api/start', {
      method: 'POST', cache: 'no-store',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tree: treeArg, full: !S.fast }),
    });
    const j = await r.json();
    if (!j.ok) { S.appState = 'idle'; setStatus(j.error || '启动失败', 'err'); updateSelUi(); return; }
  } catch (e) {
    S.appState = 'idle';
    setStatus('连接不上本地服务，请关掉窗口重新打开', 'err');
    updateSelUi();
    return;
  }
  enterRunningUi(treeArg);
  S.runStartAt = Date.now();
  startPolling();
  startElapsed();
}

function enterRunningUi(treeArg) {
  const name = treeArg === 'all' ? '全面体检' : (S.meta.trees.find((t) => t.id === treeArg) || {}).name;
  $('#log-box').innerHTML = '';
  $('#progress-fill').style.width = '0%';
  $('#pct-label').textContent = '0 / ' + S.expectSeq.length + ' 项';
  $('#run-card').classList.remove('hidden');
  $('#run-card').closest('.view').classList.add('running');
  setTimeout(() => { $('#run-card').scrollIntoView({ behavior: 'auto', block: 'nearest' }); }, 60);
  $('#select-card').classList.add('disabled');
  $$('#select-card input').forEach((i) => (i.disabled = true));
  const btn = $('#btn-run');
  btn.textContent = '取消';
  btn.disabled = false;
  btn.classList.add('running');
  addLog('—— 开始' + name + ' ——', 'st-dim');
  if (S.expectSeq.length > 0) setNextCurrent(0);
  setStatus('正在体检（共 ' + S.expectSeq.length + ' 项）…', '');
  switchView('wizard');
}

function setNextCurrent(pos) {
  if (pos >= S.expectSeq.length) return;
  const nx = S.expectSeq[pos];
  const t = S.meta.trees.find((x) => x.id === nx.tree);
  const layerIdx = t.layers.findIndex((l) => l.name === nx.layer) + 1;
  setCurrent('正在查：' + nx.layerTitle + '（第 ' + layerIdx + ' 步，共 ' + t.layers.length + ' 步）');
}

async function cancelRun() {
  try { await fetch('/api/cancel', { method: 'POST', cache: 'no-store' }); } catch (e) {}
  setStatus('正在停止…', '');
  $('#btn-run').disabled = true;
}

/* ---------- 轮询 /api/events（500ms） ---------- */
function startPolling() {
  stopPolling();
  S.pollTimer = setInterval(pollEvents, 500);
}
function stopPolling() { if (S.pollTimer) { clearInterval(S.pollTimer); S.pollTimer = null; } }

async function pollEvents() {
  let payload;
  try {
    const r = await fetch('/api/events?since=' + S.lastSeq, { cache: 'no-store' });
    payload = await r.json();
    S.beatFail = 0;
  } catch (e) {
    S.beatFail++;
    if (S.beatFail >= 5) {
      stopPolling(); stopElapsed();
      S.appState = 'error';
      setStatus('连接不上本地服务，请关掉窗口重新打开', 'err');
      setCurrent('连接中断');
      $('#btn-run').disabled = true;
    }
    return;
  }
  (payload.events || []).forEach((ev) => handleEvent(ev));
  S.lastSeq = payload.lastSeq;
  if (payload.state && payload.state !== S.appState && payload.state !== 'running') {
    finalize(payload);
  } else if (payload.state === 'running' && S.appState !== 'running') {
    recoverRunning(payload); // 页面刷新后恢复：server 还在跑
  }
}

/* 预计剩余：前 5 项方差大不估；按已完成项平均耗时外推，纯展示层 */
function etaText() {
  if (S.seqPos < 5 || !S.expectSeq.length || S.seqPos >= S.expectSeq.length) return '';
  const remainMs = ((Date.now() - S.runStartAt) / S.seqPos) * (S.expectSeq.length - S.seqPos);
  if (remainMs < 10 * 1000) return ' · 快好了'; // 剩余<10秒才退模糊文案；门槛过大会让短任务全程只见「快好了」（终验实锤）
  const min = Math.floor(remainMs / 60000), sec = Math.round((remainMs % 60000) / 1000);
  return ' · 还要约 ' + (min ? min + ' 分 ' + sec + ' 秒' : sec + ' 秒');
}

function handleEvent(ev) {
  if (ev.event === 'check') {
    const sec = ev.ms ? (ev.ms / 1000).toFixed(1) + ' 秒' : '';
    addLog(statusWord(ev.status) + '  ' + humanCheck(ev.check) + ' · ' + sec, stClass(ev.status));
    S.seqPos++;
    const pct = S.expectSeq.length ? Math.round((S.seqPos / S.expectSeq.length) * 100) : 0;
    $('#progress-fill').style.width = pct + '%';
    $('#pct-label').textContent = S.seqPos + ' / ' + S.expectSeq.length + ' 项' + etaText();
    setTitleProgress(pct);
    setNextCurrent(S.seqPos);
  } else if (ev.event === 'break') {
    addLog('✗ 问题出在这一步：' + ev.layerTitle, 'st-fail');
    if (S.fast && S.seqPos < S.expectSeq.length) {
      for (let i = S.seqPos; i < S.expectSeq.length; i++) {
        const nx = S.expectSeq[i];
        if (nx.tree !== ev.tree) continue;
        if (nx.layer === ev.layer) continue;
        addLog('– 没查成  ' + humanCheck(nx.check) + '（快速模式提前结束）', 'st-skip');
        S.seqPos++;
      }
      const pct = S.expectSeq.length ? Math.round((S.seqPos / S.expectSeq.length) * 100) : 0;
      $('#progress-fill').style.width = pct + '%';
      $('#pct-label').textContent = S.seqPos + ' / ' + S.expectSeq.length + ' 项' + etaText();
      setTitleProgress(pct);
    }
  } else if (ev.event === 'tree_done') {
    const t = S.meta.trees.find((x) => x.id === ev.tree);
    const name = t ? t.name : ev.tree;
    addLog('—— ' + name + '完成：' + (ev.status === 'FAIL' ? '发现问题' : '全部正常') + ' ——', 'st-dim');
  }
}
function stClass(st) { return st === 'PASS' ? 'st-pass' : st === 'FAIL' ? 'st-fail' : 'st-skip'; }

function recoverRunning(payload) {
  S.appState = 'running'; setTitleProgress(0);
  S.lastSeq = 0;
  $('#log-box').innerHTML = '';
  addLog('—— 页面刷新过，接着显示进度 ——', 'st-dim');
  (payload.events || []).forEach((ev) => handleEvent(ev));
  S.lastSeq = payload.lastSeq;
  S.runStartAt = Date.now() - (payload.elapsedSec || 0) * 1000;
  S.fast = payload.runFull === false;
  const btn = $('#btn-run');
  btn.textContent = '取消'; btn.disabled = false; btn.classList.add('running');
  $('#select-card').classList.add('disabled');
  $$('#select-card input').forEach((i) => (i.disabled = true));
  $('#run-card').classList.remove('hidden');
  $('#pct-label').textContent = S.seqPos + ' / ' + S.expectSeq.length + ' 项';
  startElapsed();
  setStatus('正在体检…（页面刷新过）', '');
}

function finalize(payload) {
  document.title = '✓ 体检完成 · 电脑体检台';
  setTimeout(() => { if (S.appState !== 'running') setTitleProgress(null); }, 2500);
  stopPolling(); stopElapsed();
  S.appState = payload.state;
  const secHuman = Math.max(1, Math.round((Date.now() - S.runStartAt) / 1000)) || (payload.elapsedSec || 0);
  $('#view-wizard').classList.remove('running');
  if (payload.state === 'done') {
    S.htmlUrl = payload.htmlUrl || '';
    addLog('—— 体检完成（' + secHuman + ' 秒）· ' + (payload.exit === 0 ? '全部正常' : '发现问题') + ' ——',
      payload.exit === 0 ? 'st-pass' : 'st-fail');
    $('#progress-fill').style.width = '100%';
    setCurrent('查完了。右边按高/中/低列了问题，点一条就能看怎么修');
    setStatus('体检完成（' + secHuman + ' 秒）· ' + exitHuman(payload.exit), payload.exit === 0 ? '' : 'err');
    loadReport().then(() => {
      switchView('results');
      updateSelUi();
      saveLastRun(secHuman);
    });
  } else if (payload.state === 'cancelled') {
    addLog('—— 已取消，本次没有报告 ——', 'st-skip');
    setCurrent('已取消，本次没有报告');
    setStatus('已取消 · 用时 ' + secHuman + ' 秒', '');
    updateSelUi();
  } else {
    addLog('—— 程序出错了（代码 ' + payload.exit + '）——', 'st-fail');
    setCurrent('程序出错');
    setStatus('程序出错了（代码 ' + payload.exit + '）。请把 reports 文件夹里最新的文件发给维护者', 'err');
    updateSelUi();
  }
}

/* ---------- 用时（状态栏右侧） ---------- */
function startElapsed() {
  stopElapsed();
  S.elapsedTimer = setInterval(() => {
    const s = Math.floor((Date.now() - S.runStartAt) / 1000);
    const mm = String(Math.floor(s / 60)).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    $('#status-right').innerHTML = '<span class="ver-chip">电脑体检台 ' + APP_VERSION + '</span><span class="run-time">用时 ' + mm + ':' + ss + '</span>';
  }, 1000);
}
function stopElapsed() {
  if (S.elapsedTimer) { clearInterval(S.elapsedTimer); S.elapsedTimer = null; }
  $('#status-right').innerHTML = '<span class="ver-chip">电脑体检台 ' + APP_VERSION + '</span>';
}

/* ---------- 报告 ---------- */
async function loadReport() {
  try {
    const r = await fetch('/api/report', { cache: 'no-store' });
    const j = await r.json();
    if (j.error || !j.report) { S.reportPayload = null; S.entries = null; updateResultsShell(); return false; }
    S.reportPayload = j;
    buildResultTree();
    buildRepairList();
    updateResultsShell();
    renderDeltaBar();
    if (S.pendingSense && S.appState === 'done') { S.pendingSense = false; renderFixSense(); }
    return true;
  } catch (e) { updateResultsShell(); return false; }
}

function updateResultsShell() {
  const has = !!S.reportPayload;
  $('#result-empty').classList.toggle('hidden', has);
  $('#results-body').classList.toggle('hidden', !has);
  if (!has) {
    $('#verdict-banner').classList.add('hidden');
    $('#first-fix').classList.add('hidden');
    $('#first-fix').innerHTML = '';
    $('#problem-list').innerHTML = '';
    $('#result-tree').innerHTML = '';
    return;
  }
  $('#btn-browser').disabled = !S.htmlUrl;
  $('#btn-folder').disabled = false;
  $('#btn-copylist').disabled = false;
}

/* 展示层归并：跨树同名只留一条；同名取最坏状态；建议/证据补空 */
function collectChecks() {
  if (!S.reportPayload) return [];
  const map = new Map();
  const trees = S.reportPayload.report.trees || [];
  trees.forEach((t) => {
    (t.layers || []).forEach((l) => {
      (l.checks || []).forEach((c) => {
        let e = map.get(c.name);
        if (!e) {
          e = {
            name: c.name, status: c.status, evidence: c.evidence || '', suggestion: c.suggestion || '',
            trees: [t.report_name], checks: [c],
          };
          map.set(c.name, e);
        } else {
          if (e.trees.indexOf(t.report_name) < 0) e.trees.push(t.report_name);
          if (c.status === 'FAIL') e.status = 'FAIL';
          else if (c.status === 'SKIP' && e.status !== 'FAIL') e.status = 'SKIP';
          if (!e.evidence && c.evidence) e.evidence = c.evidence;
          if (!e.suggestion && c.suggestion) e.suggestion = c.suggestion;
        }
      });
    });
  });
  return [...map.values()];
}

/* ---------- 结果中心：大结论 ---------- */
function renderVerdictBanner(hide) {
  const vb = $('#verdict-banner');
  if (!vb) return;
  if (hide || !S.reportPayload) { vb.classList.add('hidden'); return; }
  const j = S.reportPayload.report;
  const isAll = (j.trees || []).length > 1;
  const entries = S.entries || collectChecks();
  const fails = entries.filter((e) => e.status === 'FAIL');
  const skips = entries.filter((e) => e.status === 'SKIP');
  const cnt = { high: 0, medium: 0, low: 0 };
  fails.forEach((e) => { const k = checkSeverity(e.name); cnt[k] = (cnt[k] || 0) + 1; });
  const ok = S.reportPayload.exit === 0 && fails.length === 0;

  vb.innerHTML = '';
  vb.classList.toggle('bad', !ok);
  vb.classList.toggle('ok', ok);
  const big = document.createElement('div');
  big.className = 'vb-big ' + (ok ? 'ok' : 'bad');
  big.textContent = ok ? '全部正常' : '发现问题 · 共 ' + fails.length + ' 项';
  const sub = document.createElement('div');
  sub.className = 'vb-sub';
  if (ok) {
    sub.textContent = (isAll ? '五类检查全部完成' : '本轮检查完成') +
      (skips.length ? '，有 ' + skips.length + ' 项没查成（不是有问题，原因见下）。' : '，没有发现隐患。');
  } else {
    sub.textContent = '已按严重度排好：先看「高」，再看「中」。每一条都能直接跳到修复方式。' +
      (skips.length ? '另有 ' + skips.length + ' 项没查成，不是有问题。' : '');
  }
  vb.appendChild(big);
  vb.appendChild(sub);

  const stats = document.createElement('div');
  stats.className = 'vb-stats';
  [['high', '高'], ['medium', '中'], ['low', '低']].forEach(([k, word]) => {
    if (!cnt[k]) return;
    const sp = document.createElement('span');
    sp.className = 'vb-sev ' + k;
    sp.textContent = word + ' ' + cnt[k];
    stats.appendChild(sp);
  });
  if (!fails.length) {
    const sp = document.createElement('span');
    sp.className = 'vb-sev';
    sp.textContent = '没查成 ' + skips.length;
    stats.appendChild(sp);
  }
  vb.appendChild(stats);

  const btn = document.createElement('button');
  btn.className = 'btn-primary vb-btn';
  btn.textContent = ok ? '看全部检查项' : '去修复中心';
  btn.addEventListener('click', () => { if (ok) setResultFilter('all'); else switchView('repair'); });
  vb.appendChild(btn);
  vb.classList.remove('hidden');
}

/* ---------- 结果中心：全部检查项树 ---------- */
function buildResultTree() {
  const tree = $('#result-tree');
  tree.innerHTML = '';
  if (!S.reportPayload) return;
  const j = S.reportPayload.report;
  const time = (j.time || '').replace(/:\d\d$/, '');
  const isAll = (j.trees || []).length > 1;
  const exit = S.reportPayload.exit;
  const rootText = isAll ? '全面体检报告  ' + time : ((j.trees[0] || {}).report_name || '体检报告') + '  ' + time;

  const root = document.createElement('details');
  root.open = true;
  const rootSum = document.createElement('summary');
  rootSum.style.fontWeight = '700';
  rootSum.style.color = exit === 0 ? 'var(--pass)' : 'var(--fail)';
  rootSum.appendChild(document.createTextNode(rootText));
  root.appendChild(rootSum);
  root.__data = { type: 'root', title: rootText, exitCode: exit, time: time };
  rootSum.addEventListener('click', (e) => { e.stopPropagation(); selectNode(root); });

  const children = document.createElement('div');
  children.className = 'node-children';
  (j.trees || []).forEach((t) => children.appendChild(buildTreeSection(t)));
  root.appendChild(children);
  tree.appendChild(root);

  S.entries = collectChecks();
  selectNode(root);
  renderVerdictBanner(false);
  renderFirstFix();
  const first = buildProblemList() || S.entries.find((e) => e.status === 'SKIP');
  if (first) renderCheckDetail(first);
  setResultFilter(S.resultFilter);
  updateResultsShell();
}

function buildTreeSection(t) {
  const sec = document.createElement('details');
  sec.open = true;
  const sum = document.createElement('summary');
  sum.style.color = t.break_layer ? 'var(--fail)' : 'var(--pass)';
  let breakTitle = '';
  if (t.break_layer) {
    const bl = (t.layers || []).find((l) => l.name === t.break_layer);
    if (bl) breakTitle = bl.title || '';
  }
  sum.appendChild(document.createTextNode(t.report_name));
  sec.appendChild(sum);
  sec.__data = { type: 'tree', data: t, breakTitle: breakTitle };
  sum.addEventListener('click', (e) => { e.stopPropagation(); selectNode(sec); });

  const kids = document.createElement('div');
  kids.className = 'node-children';
  (t.layers || []).forEach((l, i) => kids.appendChild(buildLayerNode(t, l, i)));
  sec.appendChild(kids);
  return sec;
}

function buildLayerNode(t, l, idx) {
  const det = document.createElement('details');
  const sum = document.createElement('summary');
  let mark, mcls;
  if (l.state === 'BREAK') { mark = '—— 有问题'; mcls = 'fail'; }
  else if ((l.state || '').indexOf('SKIPPED') === 0) { mark = '（快速模式未查）'; mcls = 'skip'; }
  else { mark = '✓'; mcls = 'pass'; }
  const num = idx < LAYER_NUM.length ? LAYER_NUM[idx] : '第' + (idx + 1);
  const tSpan = document.createElement('span');
  tSpan.className = 't';
  tSpan.textContent = num + ' ' + l.title;
  const markSpan = document.createElement('span');
  markSpan.className = 'mark ' + mcls;
  markSpan.textContent = mark;
  sum.appendChild(tSpan);
  sum.appendChild(markSpan);
  det.appendChild(sum);
  det.__data = { type: 'layer', data: l, treeName: t.report_name };
  sum.addEventListener('click', (e) => { e.stopPropagation(); selectNode(det); });

  const kids = document.createElement('div');
  kids.className = 'node-children';
  (l.checks || []).forEach((c) => {
    const leaf = document.createElement('div');
    leaf.className = 'leaf';
    leaf.style.color = c.status === 'PASS' ? 'var(--pass)' : c.status === 'FAIL' ? 'var(--fail)' : 'var(--skip)';
    leaf.title = c.name;
    leaf.appendChild(document.createTextNode(statusWord(c.status) + '  ' + humanCheck(c.name)));
    leaf.__data = { type: 'check', data: c, treeName: t.report_name };
    leaf.addEventListener('click', () => {
      renderCheckDetail({ name: c.name, status: c.status, evidence: c.evidence || '', suggestion: c.suggestion || '', trees: [t.report_name] });
    });
    kids.appendChild(leaf);
  });
  det.appendChild(kids);
  return det;
}

/* ---------- 结果中心：问题清单（展示层归并 + 严重度） ---------- */
function buildProblemList() {
  const box = $('#problem-list');
  if (!box) return null;
  box.innerHTML = '';
  const entries = S.entries || collectChecks();
  if (!entries.length) return null;
  const fails = entries.filter((e) => e.status === 'FAIL');
  const skips = entries.filter((e) => e.status === 'SKIP' && !fails.some((f) => f.name === e.name));
  const groups = [];
  PROBLEM_GROUPS.forEach((g) => {
    const items = fails.filter((e) => groupFor(e.name).id === g.id)
      .sort((a, b) => (SEV_RANK[checkSeverity(a.name)] - SEV_RANK[checkSeverity(b.name)]) || a.name.localeCompare(b.name));
    if (items.length) groups.push({ g, items });
  });
  groups.sort((a, b) => {
    const ra = Math.min(...a.items.map((e) => SEV_RANK[checkSeverity(e.name)]));
    const rb = Math.min(...b.items.map((e) => SEV_RANK[checkSeverity(e.name)]));
    return ra - rb;
  });

  if (!fails.length) {
    const card = document.createElement('div');
    card.className = 'problem-card sev-low';
    card.innerHTML = '<div class="pc-head"><span class="sev-badge low">✓</span><b>这一轮没有查出问题</b></div>' +
      '<div class="pc-note">' + (skips.length ? '还有 ' + skips.length + ' 项没查成，放到下面单独说。' : '所有检查项都正常，不用修。') + '</div>';
    box.appendChild(card);
  }

  groups.forEach(({ g, items }) => {
    const sev = items.map((e) => checkSeverity(e.name)).sort((a, b) => SEV_RANK[a] - SEV_RANK[b])[0];
    const meta = SEV_META[sev];
    const card = document.createElement('div');
    card.className = 'problem-card sev-' + sev;
    const head = document.createElement('div');
    head.className = 'pc-head';
    const badge = document.createElement('span');
    badge.className = 'sev-badge ' + meta.cls;
    badge.textContent = meta.word;
    const title = document.createElement('b');
    title.textContent = g.title;
    const count = document.createElement('span');
    count.className = 'pc-count';
    count.textContent = items.length + ' 项';
    head.appendChild(badge); head.appendChild(title); head.appendChild(count);
    card.appendChild(head);
    if (g.note) {
      const note = document.createElement('div');
      note.className = 'pc-note';
      note.textContent = g.note;
      card.appendChild(note);
    }
    const list = document.createElement('div');
    list.className = 'pc-items';
    items.forEach((e) => {
      const btn = document.createElement('button');
      btn.className = 'pc-item';
      btn.dataset.check = e.name;
      const st = document.createElement('span');
      st.className = 'pc-st st-fail';
      st.textContent = '✗';
      const nm = document.createElement('span');
      nm.textContent = humanCheck(e.name);
      const tr = document.createElement('span');
      tr.className = 'pc-tree';
      tr.textContent = e.trees.map((x) => String(x).replace(/报告$/, '')).join(' / ');
      btn.appendChild(st); btn.appendChild(nm); btn.appendChild(tr);
      btn.addEventListener('click', () => renderCheckDetail(e));
      list.appendChild(btn);
    });
    card.appendChild(list);
    const foot = document.createElement('div');
    foot.className = 'pc-foot';
    const go = document.createElement('button');
    go.className = 'btn';
    go.textContent = '去修复';
    go.addEventListener('click', () => focusRepair(items.filter((e) => e.suggestion).map((e) => e.name)));
    foot.appendChild(go);
    card.appendChild(foot);
    box.appendChild(card);
  });

  if (skips.length) {
    const card = document.createElement('div');
    card.className = 'problem-card sev-skip';
    const head = document.createElement('div');
    head.className = 'pc-head';
    const badge = document.createElement('span');
    badge.className = 'sev-badge';
    badge.textContent = '—';
    const title = document.createElement('b');
    title.textContent = '没查成（不是有问题）';
    const count = document.createElement('span');
    count.className = 'pc-count';
    count.textContent = skips.length + ' 项';
    head.appendChild(badge); head.appendChild(title); head.appendChild(count);
    card.appendChild(head);
    const note = document.createElement('div');
    note.className = 'pc-note';
    note.textContent = '这些项这次没拿到结果，不代表正常，也不代表坏了。常见原因是缺管理员权限、机器没这个部件、系统没留记录；按提示处理后可以重跑。';
    card.appendChild(note);
    const list = document.createElement('div');
    list.className = 'pc-items';
    skips.forEach((e) => {
      const btn = document.createElement('button');
      btn.className = 'pc-item';
      btn.dataset.check = e.name;
      const st = document.createElement('span');
      st.className = 'pc-st st-skip';
      st.textContent = '–';
      const nm = document.createElement('span');
      nm.textContent = humanCheck(e.name);
      const tr = document.createElement('span');
      tr.className = 'pc-tree';
      tr.textContent = isAdminSkip(e.name, e.evidence) ? '需管理员' : (SKIP_TAG[e.name] || '没结果');
      btn.appendChild(st); btn.appendChild(nm); btn.appendChild(tr);
      btn.addEventListener('click', () => renderCheckDetail(e));
      list.appendChild(btn);
    });
    card.appendChild(list);
    box.appendChild(card);
  }

  return (groups.length ? groups[0].items[0] : null) || fails[0] || skips[0] || null;
}

function setResultFilter(f) {
  S.resultFilter = f === 'all' ? 'all' : 'problems';
  const onProblems = S.resultFilter === 'problems';
  const entries = S.entries || collectChecks();
  const failCnt = entries.filter((e) => e.status === 'FAIL').length;
  const pb = $('#filter-problems'), fa = $('#filter-all');
  if (pb) {
    pb.classList.toggle('active', onProblems);
    pb.setAttribute('aria-selected', onProblems ? 'true' : 'false');
    $('#cnt-problems').textContent = ' ' + failCnt;
  }
  if (fa) {
    fa.classList.toggle('active', !onProblems);
    fa.setAttribute('aria-selected', !onProblems ? 'true' : 'false');
    $('#cnt-all').textContent = ' ' + entries.length;
  }
  $('#problem-list').classList.toggle('hidden', !onProblems);
  $('#result-tree').classList.toggle('hidden', onProblems);
}
$('#result-filter').addEventListener('click', (e) => {
  const b = e.target.closest('.seg-btn');
  if (b) setResultFilter(b.dataset.filter);
});

/* ---------- 结果中心：详情面板 ---------- */
function renderCheckDetail(entry) {
  if (!entry) return;
  const title = $('#sel-title');
  const ev = $('#ev-box');
  const sug = $('#sug-box');
  const label = $('#detail-label');
  const copyBtn = $('#btn-copy');
  const hint = $('#detail-hint');
  const goto = $('#btn-goto-repair');
  const fold = $('#ev-fold');
  const st = entry.status;
  S.currentSuggestion = '';
  copyBtn.disabled = true;
  copyBtn.textContent = '复制修复方法';
  sug.classList.remove('hidden');
  goto.hidden = true;
  hint.classList.add('hidden');
  hint.innerHTML = '';

  title.textContent = humanCheck(entry.name) + '  ' + statusWord(st);
  title.style.color = st === 'PASS' ? 'var(--pass)' : st === 'FAIL' ? 'var(--fail)' : 'var(--skip)';

  const info = CHECK_INFO[entry.name] || '';
  const sev = checkSeverity(entry.name);
  if (st === 'FAIL') {
    goto.hidden = false;
    goto.onclick = () => focusRepair([entry.name]);
    hint.innerHTML = '<p><b>这是什么：</b>' + esc(info || '这一项检查了系统和硬件的对应状态。') + '</p>' +
      '<p><b>影响程度：</b>' + SEV_META[sev].word + ' · ' + SEV_META[sev].desc +
      (entry.trees.length > 1 ? ' · 在 ' + esc(entry.trees.join('、')) + ' 里都查到了' : '') + '</p>';
    hint.classList.remove('hidden');
    if (!entry.suggestion) {
      hint.innerHTML += '<p><b>注意：</b>这项没给出修复方法（异常），请把报告发给维护者。</p>';
    }
    label.textContent = '怎么修';
    sug.textContent = entry.suggestion || '（这项有问题但没给修复方法——异常，请反馈）';
    if (entry.suggestion) { S.currentSuggestion = entry.suggestion; copyBtn.disabled = false; }
  } else if (st === 'SKIP') {
    const admin = isAdminSkip(entry.name, entry.evidence);
    const adminNote = ADMIN_SKIP[entry.name] || (admin ? ADMIN_SKIP_TEXT : '');
    hint.innerHTML = '<p><b>这是什么：</b>' + esc(info || '这一项检查了系统和硬件的对应状态。') + '</p>' +
      '<p><b>没查成 ≠ 有问题：</b>这次没拿到结果，不代表正常，也不代表坏了。' +
      (admin ? '这项要管理员权限才能查。' : '') + '</p>';
    hint.classList.remove('hidden');
    label.textContent = '怎么处理';
    sug.textContent = adminNote || entry.suggestion || '这次没查成，不影响其他项。按上面的原因处理后再跑一轮，就能看到结果。';
  } else {
    hint.innerHTML = '<p><b>这是什么：</b>' + esc(info || '这一项检查了系统和硬件的对应状态。') + '</p>' +
      '<p>这项正常，不需要修。</p>';
    hint.classList.remove('hidden');
    label.textContent = '检查结果';
    sug.textContent = '这项正常，不需要修。';
  }

  $('#ev-label').textContent = '看原始记录（这一项查了什么）';
  ev.textContent = entry.evidence || '（这项没有留下原始记录）';
  fold.open = false;
  S.lastNode = null;
  $$('.pc-item').forEach((b) => b.classList.toggle('active', b.dataset.check === entry.name));
}
function isAdminSkip(name, evidence) {
  if (ADMIN_SKIP[name]) return true;
  return /管理员|权限|拒绝访问|access is denied|access-denied|unauthorized/i.test(evidence || '');
}

/* 选中树/根/层节点（与原版四型一致，只是不再挤占 sug 大块） */
function selectNode(node) {
  const tag = node && node.__data;
  if (!tag) return;
  S.lastNode = node;
  const title = $('#sel-title');
  const ev = $('#ev-box');
  const sug = $('#sug-box');
  const label = $('#detail-label');
  const copyBtn = $('#btn-copy');
  const hint = $('#detail-hint');
  const goto = $('#btn-goto-repair');
  S.currentSuggestion = '';
  copyBtn.disabled = true;
  copyBtn.textContent = '复制修复方法';
  sug.classList.add('hidden');
  sug.textContent = '';
  hint.classList.add('hidden');
  hint.innerHTML = '';
  goto.hidden = true;
  $$('.pc-item').forEach((b) => b.classList.remove('active'));

  const fold = $('#ev-fold');
  $('#ev-label').textContent = '这一步的说明';
  fold.open = true;
  if (tag.type === 'layer') {
    const l = tag.data;
    title.textContent = l.title;
    title.style.color = l.state === 'BREAK' ? 'var(--fail)' : (l.state || '').indexOf('SKIPPED') === 0 ? 'var(--skip)' : 'var(--pass)';
    const stateHuman = l.state === 'BREAK' ? '这一步查出了问题'
      : (l.state === 'PASS' || l.state === 'PASSED-EARLIER') ? '这一步全部正常'
      : (l.state || '').indexOf('SKIPPED') === 0 ? '快速模式下这一步没有查' : l.state;
    ev.textContent = stateHuman + '\r\n\r\n这一步说明：' + (l.verdict_fail || '');
    label.textContent = '说明';
  } else if (tag.type === 'tree') {
    const t = tag.data;
    title.textContent = t.report_name;
    title.style.color = t.break_layer ? 'var(--fail)' : 'var(--pass)';
    const concl = t.break_layer ? '问题出在这一步：' + tag.breakTitle : '全部正常';
    ev.textContent = concl + '\r\n\r\n这项检查正常时会看到：' + (t.verdict_all_pass || '');
    label.textContent = '说明';
  } else if (tag.type === 'root') {
    title.textContent = tag.title;
    title.style.color = tag.exitCode === 0 ? 'var(--pass)' : 'var(--fail)';
    ev.textContent = '总结论：' + exitHuman(tag.exitCode) + '\r\n报告时间：' + tag.time + '\r\n\r\n想看带样式的完整报告：点上方「完整报告」';
    label.textContent = '说明';
  }
}

/* 锚到修复中心：优先匹配动作卡，其次「要自己动手的」项 */
function focusRepair(checks) {
  const names = (checks || []).filter(Boolean);
  if (!names.length) { switchView('repair'); return; }
  switchView('repair');
  requestAnimationFrame(() => {
    const cards = $$('#repair-list .action-card');
    let target = cards.find((c) => (c.dataset.checks || '').split(/\s+/).some((n) => names.indexOf(n) >= 0));
    if (!target) target = $$('#repair-list .repair-item').find((c) => names.indexOf(c.dataset.check) >= 0);
    if (!target) {
      const box = $('#repair-list');
      if (box) box.scrollIntoView({ block: 'start' });
      return;
    }
    target.scrollIntoView({ behavior: 'smooth', block: 'center' });
    target.classList.add('flash');
    setTimeout(() => target.classList.remove('flash'), 2100);
  });
}

/* ---------- 结果中心按钮 ---------- */
$('#btn-browser').addEventListener('click', () => {
  if (S.htmlUrl) window.open(S.htmlUrl, '_blank');
});
$('#btn-folder').addEventListener('click', async () => {
  try { await fetch('/api/open-reports', { method: 'POST', cache: 'no-store' }); } catch (e) {}
});
$('#btn-again').addEventListener('click', () => { resetToIdle(); switchView('wizard'); });
$('#btn-empty-run').addEventListener('click', () => { resetToIdle(); switchView('wizard'); });

function resetToIdle() {
  S.appState = 'idle';
  S.seqPos = 0; S.lastSeq = 0; S.htmlUrl = '';
  $('#log-box').innerHTML = '';
  $('#progress-fill').style.width = '0%';
  $('#pct-label').textContent = '0 / 0 项';
  $('#run-card').classList.add('hidden');
  $('#select-card').classList.remove('disabled');
  $$('#select-card input').forEach((i) => { i.disabled = false; });
  const all = $('#chk-all');
  if (all.checked) $$('.tree-item').forEach((it) => { it.querySelector('input').disabled = true; it.classList.add('disabled'); });
  const btn = $('#btn-run');
  btn.textContent = '开始体检';
  btn.classList.remove('running');
  setCurrent('正在准备…');
  setStatus('就绪', '');
  updateSelUi();
  updateResultsShell();
}

/* 复制问题清单：把结果一段纯文本复制出去求助（组名+严重度+人话检查名） */
function buildCopyList() {
  const es = S.entries || [];
  const fails = es.filter((e) => e.status === 'FAIL');
  const lines = [];
  if (!fails.length) {
    lines.push('这轮体检没查出问题（查了 ' + es.length + ' 项）。');
  } else {
    PROBLEM_GROUPS.forEach((g) => {
      const items = fails.filter((e) => groupFor(e.name).id === g.id)
        .sort((x, y) => SEV_RANK[checkSeverity(x.name)] - SEV_RANK[checkSeverity(y.name)]);
      if (!items.length) return;
      const sev = checkSeverity(items[0].name);
      lines.push('【' + (sev === 'high' ? '高' : sev === 'medium' ? '中' : '低') + '】' + g.title + '：' +
        items.map((e) => humanCheck(e.name)).join('、'));
    });
    const ungrouped = fails.filter((e) => groupFor(e.name).id === 'other');
    ungrouped.forEach((e) => lines.push('【其他】' + humanCheck(e.name)));
  }
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return '电脑体检台体检结果 ' + d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
    pad(d.getHours()) + ':' + pad(d.getMinutes()) + '（查了 ' + es.length + ' 项' +
    (fails.length ? '，发现问题 ' + fails.length + ' 项' : '') + '）\n\n' + lines.join('\n') +
    '\n\n（详细证据和修法在软件里看：结果中心→去修复中心）';
}
$('#btn-copylist').addEventListener('click', () => {
  doCopy(buildCopyList(), $('#btn-copylist'), '复制问题清单');
});

/* ---------- 复制 ---------- */
async function copyText(t) {
  try { window.focus(); await navigator.clipboard.writeText(t); return true; } catch (e) {
    try {
      const ta = document.createElement('textarea');
      ta.value = t;
      ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    } catch (e2) { return false; }
  }
}
function showCopyFallback(text) {
  const ta = $('#copy-ta');
  ta.value = text;
  $('#copy-overlay').classList.remove('hidden');
  ta.focus();
  ta.select();
}
async function doCopy(text, btn, resetLabel) {
  const ok = await copyText(text);
  if (ok) {
    btn.textContent = '已复制 ✓';
    setTimeout(() => { btn.textContent = resetLabel; }, 1200);
  } else {
    showCopyFallback(text);
    btn.textContent = resetLabel;
  }
}
$('#btn-copy').addEventListener('click', () => {
  if (!S.currentSuggestion) return;
  doCopy(S.currentSuggestion, $('#btn-copy'), '复制修复方法');
});

/* ---------- 修复中心 ---------- */
const LV_META = {
  green: { word: '绿色 · 安全可自动修', cls: 'green' },
  yellow: { word: '黄色 · 你确认后才动', cls: 'yellow' },
  red: { word: '红色 · 永远只给步骤', cls: 'red' },
};
const CMD_MAP = {
  'ipconfig.exe /flushdns': 'ipconfig /flushdns',
  'arp.exe -d *': 'arp -d *',
  'ipconfig.exe /registerdns': 'ipconfig /registerdns',
  'netsh.exe winsock reset': 'netsh winsock reset',
  'netsh.exe int ipv4 reset': 'netsh int ipv4 reset',
  'netsh.exe int ipv6 reset': 'netsh int ipv6 reset',
  'netsh.exe int tcp reset': 'netsh int tcp reset',
  'w32tm.exe /resync': 'w32tm /resync',
  'ie4uinit.exe -show': 'ie4uinit -show',
  'net.exe stop spooler': 'net stop spooler',
  'net.exe start spooler': 'net start spooler',
  'net.exe stop wuauserv': 'net stop wuauserv',
  'net.exe start wuauserv': 'net start wuauserv',
  'net.exe stop bits': 'net stop bits',
  'net.exe start bits': 'net start bits',
  'powercfg.exe -restoredefaultschemes': 'powercfg -restoredefaultschemes',
};
function stepCmdText(st) {
  if (st.display) return st.display;
  const raw = st.exe + ' ' + (st.args || []).join(' ');
  return CMD_MAP[raw] || raw;
}

/* 问题修复置顶（绿/黄 → 红 → 自己动手），常用修复折叠到最后。同一动作只渲染一次。 */
function buildRepairList() {
  const box = $('#repair-list');
  if (!box) return;
  const commons = (S.repairActions || []).filter((a) => a.common);
  const appendCommonsFold = () => {
    if (!commons.length) return;
    const fold = document.createElement('details');
    fold.className = 'common-fold';
    const sum = document.createElement('summary');
    sum.textContent = '常用修复（没跑体检也能用）';
    fold.appendChild(sum);
    const note = document.createElement('div');
    note.className = 'rep-sec-note';
    note.textContent = '这些是日常小修，不依赖体检结果；点开卡片仍会先讲清楚做什么、影响什么、怎么撤销。';
    fold.appendChild(note);
    commons.forEach((a) => fold.appendChild(buildActionCard(a, [])));
    box.appendChild(fold);
  };

  // 没报告：只展示常用修复（折叠），不冒充「查出来的问题」
  if (!S.reportPayload) {
    box.innerHTML = '';
    const c0 = $('#ri-count'); if (c0) c0.textContent = '';
    const ph = document.createElement('div');
    ph.className = 'placeholder';
    ph.textContent = commons.length
      ? '还没跑体检。跑完一轮，查出的问题会按严重度列在这里；下面的常用修复不用体检也能用。'
      : '还没有检查结果——先去「体检向导」跑一轮。';
    box.appendChild(ph);
    appendCommonsFold();
    return;
  }

  // 跨树同名 FAIL 只算一次；保留第一次出现的报告名与建议
  const failMap = new Map();
  (S.reportPayload.report.trees || []).forEach((t) => {
    (t.layers || []).forEach((l) => {
      (l.checks || []).forEach((c) => {
        if (c.status !== 'FAIL' || !c.suggestion) return;
        if (!failMap.has(c.name)) failMap.set(c.name, { tree: t.report_name, check: c.name, sug: c.suggestion });
      });
    });
  });
  const fails = [...failMap.values()]
    .sort((a, b) => SEV_RANK[checkSeverity(a.check)] - SEV_RANK[checkSeverity(b.check)]);
  box.innerHTML = '';
  const cnt = $('#ri-count');
  if (cnt) cnt.textContent = fails.length ? '共 ' + fails.length + ' 项' : '';

  if (fails.length === 0) {
    const ph = document.createElement('div');
    ph.className = 'placeholder';
    ph.textContent = '这一轮体检没有查出需要动手的问题。';
    box.appendChild(ph);
    appendCommonsFold();
    return;
  }

  const acts = (S.repairActions || [])
    .map((a) => ({ a, hits: fails.filter((f) => (a.match_checks || []).indexOf(f.check) >= 0) }))
    .filter((x) => x.hits.length);
  const covered = new Set();
  acts.forEach((x) => x.hits.forEach((f) => covered.add(f)));
  const rest = fails.filter((f) => !covered.has(f));
  const runnable = acts.filter((x) => x.a.level !== 'red');
  const reds = acts.filter((x) => x.a.level === 'red');

  const sec = (txt) => {
    const h = document.createElement('div');
    h.className = 'rep-sec';
    h.textContent = txt;
    box.appendChild(h);
  };

  if (runnable.length) {
    sec('能代跑的修复（先看「做什么 / 怎么撤销」，绿色可直接执行）');
    runnable.forEach(({ a, hits }) => box.appendChild(buildActionCard(a, hits)));
  }
  if (reds.length) {
    sec('高风险 · 只给步骤，工具永远不代跑');
    reds.forEach(({ a, hits }) => box.appendChild(buildActionCard(a, hits)));
  }
  if (rest.length) {
    sec('要自己动手的（点开看步骤，或整段复制）');
    rest.forEach((f) => {
      const item = document.createElement('div');
      item.className = 'repair-item sev-' + SEV_META[checkSeverity(f.check)].cls;
      item.dataset.check = f.check;
      const head = document.createElement('div');
      head.className = 'ri-head';
      const ti = document.createElement('div');
      ti.className = 'ri-title';
      ti.textContent = '【' + f.tree + '】' + humanCheck(f.check);
      const sevb = document.createElement('span');
      sevb.className = 'sev-badge ' + SEV_META[checkSeverity(f.check)].cls;
      sevb.textContent = SEV_META[checkSeverity(f.check)].word;
      const cp = document.createElement('button');
      cp.className = 'btn';
      cp.textContent = '复制修复方法';
      cp.addEventListener('click', () => { doCopy(f.sug, cp, '复制修复方法'); });
      head.appendChild(ti); head.appendChild(sevb); head.appendChild(cp);
      item.appendChild(head);
      const fold = document.createElement('details');
      fold.className = 'steps-fold';
      const foldSum = document.createElement('summary');
      foldSum.textContent = '看修复方法（全文）';
      fold.appendChild(foldSum);
      const pre = document.createElement('pre');
      pre.textContent = f.sug;
      fold.appendChild(pre);
      item.appendChild(fold);
      box.appendChild(item);
    });
  }
  appendCommonsFold();
}

function buildActionCard(a, hits) {
  const card = document.createElement('div');
  card.className = 'action-card lv-' + (LV_META[a.level] ? a.level : 'green');
  card.dataset.actionId = a.id;
  if (hits && hits.length) card.dataset.checks = hits.map((f) => f.check).join(' ');
  const badge = document.createElement('div');
  badge.className = 'ac-badge';
  const bm = LV_META[a.level] || LV_META.green;
  badge.innerHTML = '<b>' + esc(a.name) + '</b><span class="lv-tag ' + bm.cls + '">' + bm.word + '</span>';
  card.appendChild(badge);

  if (a.caveat) {
    const cv = document.createElement('div');
    cv.className = 'ac-caveat';
    cv.textContent = '这项不解决：' + a.caveat;
    card.appendChild(cv);
  }

  if (hits && hits.length) {
    const seen = new Set();
    const names = hits.map((f) => humanCheck(f.check)).filter((n) => (seen.has(n) ? false : (seen.add(n), true)));
    const row = document.createElement('div');
    row.className = 'ac-row';
    row.innerHTML = '<span class="ac-key">修哪些</span><span class="ac-val">' + esc(names.join('、')) +
      (hits.length > names.length ? '（共 ' + hits.length + ' 项）' : '') + '</span>';
    card.appendChild(row);
  }

  const rows = [['做什么', a.desc], ['影响什么', a.affect], ['怎么撤销', a.undo]];
  rows.forEach(([k, v]) => {
    if (!v) return;
    const row = document.createElement('div');
    row.className = 'ac-row';
    const kEl = document.createElement('span');
    kEl.className = 'ac-key';
    kEl.textContent = k;
    const vEl = document.createElement('span');
    vEl.className = 'ac-val';
    vEl.textContent = v;
    row.appendChild(kEl); row.appendChild(vEl);
    card.appendChild(row);
  });

  const fold = document.createElement('details');
  fold.className = 'steps-fold';
  const foldSum = document.createElement('summary');
  foldSum.textContent = '看具体步骤（命令）';
  fold.appendChild(foldSum);
  const steps = document.createElement('div');
  steps.className = 'ac-steps';
  (a.steps || []).forEach((st) => {
    const line = document.createElement('div');
    line.textContent = '· ' + (st.desc || '') + '（' + stepCmdText(st) + '）';
    steps.appendChild(line);
  });
  fold.appendChild(steps);
  card.appendChild(fold);

  const btnRow = document.createElement('div');
  btnRow.className = 'ac-btns';
  const btn = document.createElement('button');
  btn.className = 'btn act-run';
  btn.dataset.actionId = a.id;
  if (a.level === 'green') {
    btn.textContent = a.requires_admin ? '执行（会弹管理员确认）' : '执行';
    btn.addEventListener('click', () => onGreenRun(a, btn, card));
  } else if (a.level === 'yellow') {
    btn.textContent = '逐项确认后执行';
    btn.addEventListener('click', () => showYellowConfirm(a, btn, card));
  } else {
    btn.textContent = '看分步指南';
    btn.addEventListener('click', (e) => onRedArm(e, a));
  }
  btnRow.appendChild(btn);
  card.appendChild(btnRow);

  if (S.repairDoneIds[a.id]) {
    const done = document.createElement('div');
    done.className = 'ac-result';
    renderRepairResult(done, S.repairDoneIds[a.id]);
    card.appendChild(done);
  }
  return card;
}

/* 绿级执行流：需管理员→先弹预告确认；POST run →轮询 status→渲染五段结果 */
function onGreenRun(a, btn, card) {
  if (S.repairBusy || S.appState === 'running') {
    setStatus(S.appState === 'running' ? '正在体检中，请等这轮结束再修复' : '正在修复中，请等它结束', 'err');
    return;
  }
  if (a.requires_admin) showGreenConfirmModal(a, () => startRepairRun(a, btn, card));
  else startRepairRun(a, btn, card);
}
function showGreenConfirmModal(a, onGo) {
  document.getElementById('rm-title').textContent = a.name || '修复动作';
  const sub = document.getElementById('rm-sub');
  sub.textContent = '这个动作要用 Windows 管理员权限——点「执行」后 Windows 会弹一个确认框（蓝色的），点「是」才会真正跑；点「否」就什么都不动。';
  fillModalRows(a);
  const go = document.getElementById('rm-go');
  go.textContent = '执行';
  go.disabled = false;
  go.onclick = () => { hideRepairModal(); onGo(); };
  document.getElementById('rm-cancel').onclick = hideRepairModal;
  document.getElementById('repair-modal').classList.remove('hidden');
}
/* 黄级逐项确认：三行都打勾才点亮「确认执行」；可选系统还原点（建不出来自动中止） */
function showYellowConfirm(a, btn, card) {
  document.getElementById('rm-title').textContent = a.name || '修复动作';
  const sub = document.getElementById('rm-sub');
  sub.textContent = '这是有中断的修复动作——三行都看懂、逐项打勾，才会出现「确认执行」。点了之后工具会先自动生成撤销脚本和备份（回滚包），然后才开始干活。';
  const rows = document.getElementById('rm-rows');
  rows.innerHTML = '';
  const checks = [];
  [['将做什么', a.desc], ['影响什么', a.affect], ['怎么撤销', a.undo || a.rollback_note]].forEach(([k, v]) => {
    const lab = document.createElement('label');
    lab.className = 'rm-line';
    const ck = document.createElement('input');
    ck.type = 'checkbox';
    ck.className = 'rm-ck';
    const sp = document.createElement('span');
    sp.innerHTML = '<b>' + k + '：</b>' + esc(v || '');
    lab.appendChild(ck); lab.appendChild(sp);
    rows.appendChild(lab);
    ck.addEventListener('change', updGo);
    checks.push(ck);
  });
  const steps = document.createElement('div');
  steps.className = 'ac-steps';
  (a.steps || []).forEach((st) => {
    const line = document.createElement('div');
    line.textContent = '· ' + (st.desc || '') + '（' + stepCmdText(st) + '）';
    steps.appendChild(line);
  });
  rows.appendChild(steps);
  let rp = null;
  if (a.restore_point) {
    const lab = document.createElement('label');
    lab.className = 'rm-line rp';
    rp = document.createElement('input');
    rp.type = 'checkbox';
    rp.className = 'rm-rp';
    rp.checked = true;
    const sp = document.createElement('span');
    sp.textContent = '执行前先建一个系统还原点（推荐。建不出来会自动中止，什么都不动）';
    lab.appendChild(rp); lab.appendChild(sp);
    rows.appendChild(lab);
  }
  const go = document.getElementById('rm-go');
  go.textContent = '确认执行';
  go.disabled = true;
  go.onclick = () => {
    hideRepairModal();
    startRepairRun(a, btn, card, { restorePoint: rp ? rp.checked : false });
  };
  document.getElementById('rm-cancel').onclick = hideRepairModal;
  document.getElementById('repair-modal').classList.remove('hidden');
  updGo();
  function updGo() { go.disabled = !checks.every((c) => c.checked); }
}
function fillModalRows(a) {
  const rows = document.getElementById('rm-rows');
  rows.innerHTML = '';
  [['做什么', a.desc], ['影响什么', a.affect], ['怎么撤销', a.undo || a.rollback_note]].forEach(([k, v]) => {
    if (!v) return;
    const row = document.createElement('div');
    row.className = 'ac-row';
    row.innerHTML = '<span class="ac-key">' + k + '</span><span class="ac-val">' + esc(v) + '</span>';
    rows.appendChild(row);
  });
  const steps = document.createElement('div');
  steps.className = 'ac-steps';
  (a.steps || []).forEach((st) => {
    const line = document.createElement('div');
    line.textContent = '· ' + (st.desc || '') + '（' + stepCmdText(st) + '）';
    steps.appendChild(line);
  });
  if (a.rollback_note) {
    const rb = document.createElement('div');
    rb.textContent = '撤销包：' + a.rollback_note;
    steps.appendChild(rb);
  }
  rows.appendChild(steps);
}
function hideRepairModal() { document.getElementById('repair-modal').classList.add('hidden'); }

/* 红级二次确认：第一次点击=警示预告，4 秒内再点才开指南页 */
function onRedArm(e, a) {
  const btn = e.target;
  if (btn.dataset.armed === '1') { btn.dataset.armed = ''; showRedGuide(a); return; }
  btn.dataset.armed = '1';
  const old = btn.textContent;
  btn.textContent = '有风险——再点一次查看';
  btn.setAttribute('aria-label', '有风险——再点一次查看');
  setTimeout(() => { if (btn.dataset.armed === '1') { btn.dataset.armed = ''; btn.textContent = old; btn.setAttribute('aria-label', old); } }, 4000);
}
let guideText = '';
/* 宝宝巴士五要素（v1.4.0 轮2）：红卡/指南步可带 how={at,click,type,ok,fail}——
   在哪/点什么/输入什么/算成功/失败了先，一行一要素零废话；渲染与整段复制共用 */
const BB_KEYS = [['at', '在哪'], ['click', '点什么'], ['type', '输入什么'], ['ok', '看到什么算成功'], ['fail', '这步失败了先']];
function howHtml(st) {
  return '<div class="bb-lines">' + BB_KEYS.filter(([k]) => st.how[k]).map(([k, w]) =>
    '<div class="bb-line"><span class="bb-key">' + w + '</span><span class="bb-val">' + esc(st.how[k]) + '</span></div>').join('') + '</div>';
}
function howText(st) {
  return BB_KEYS.filter(([k]) => st.how[k]).map(([k, w]) => '　' + w + '：' + st.how[k]).join('\n');
}
function guideTextFor(a) {
  const lines = [];
  lines.push(a.name || '高风险操作');
  lines.push('红色 · 只给步骤，工具不会代跑');
  lines.push('');
  if (a.desc) lines.push('做什么：' + a.desc);
  if (a.affect) lines.push('影响什么：' + a.affect);
  const undo = a.undo || a.rollback_note;
  if (undo) lines.push('怎么撤销：' + undo);
  lines.push('');
  lines.push('步骤：');
  (a.steps || []).forEach((st, i) => {
    lines.push((i + 1) + '. ' + (st.how ? (st.desc || '') : (st.desc || '') + '（' + stepCmdText(st) + '）'));
    if (st.how) lines.push(howText(st));
  });
  lines.push('');
  lines.push('每一步都看清再做；做之前先确认「怎么撤销」。');
  return lines.join('\n');
}
function showRedGuide(a) {
  a = a || {};
  guideText = guideTextFor(a);
  const gdTitle = document.getElementById('gd-title');
  if (gdTitle) gdTitle.textContent = '⚠ ' + (a.name || '高风险操作') + ' · 只给步骤，工具不会代跑';
  document.getElementById('gd-sub').textContent = (a.desc || '') + ' 这类操作弄错可能开不了机或丢数据——工具永远不会代跑。下面每一步都请看清楚再做，做之前先看「怎么撤销」。';
  const rows = document.getElementById('gd-rows');
  rows.innerHTML = '';
  [['影响什么', a.affect], ['怎么撤销', a.undo || a.rollback_note]].forEach(([k, v]) => {
    if (!v) return;
    const row = document.createElement('div');
    row.className = 'ac-row';
    row.innerHTML = '<span class="ac-key">' + k + '</span><span class="ac-val">' + esc(v) + '</span>';
    rows.appendChild(row);
  });
  const steps = document.createElement('div');
  steps.className = 'ac-steps';
  (a.steps || []).forEach((st, i) => {
    if (st.how) {
      const line = document.createElement('div');
      line.className = 'bb-step';
      const num = document.createElement('span');
      num.className = 'bb-num';
      num.textContent = String(i + 1);
      const body = document.createElement('div');
      body.className = 'bb-body';
      if (st.desc) {
        const t = document.createElement('div');
        t.className = 'bb-title';
        t.textContent = st.desc;
        body.appendChild(t);
      }
      body.insertAdjacentHTML('beforeend', howHtml(st));
      line.appendChild(num); line.appendChild(body);
      steps.appendChild(line);
    } else {
      const line = document.createElement('div');
      line.textContent = (i + 1) + '. ' + (st.desc || '') + '（' + stepCmdText(st) + '）';
      steps.appendChild(line);
    }
  });
  rows.appendChild(steps);
  document.getElementById('guide-overlay').classList.remove('hidden');
}
document.getElementById('gd-ok').addEventListener('click', () => {
  document.getElementById('guide-overlay').classList.add('hidden');
});
document.getElementById('gd-copy').addEventListener('click', () => {
  const btn = document.getElementById('gd-copy');
  doCopy(guideText || '（没有可复制的步骤）', btn, '复制全部步骤');
});

async function startRepairRun(a, btn, card, opts) {
  opts = opts || {};
  S.lastRepairCtx = { a, btn, card };  // 还原点中止等场景「跳过还原点直接修」重试要用
  setRepairBusy(true, btn);
  setStatus('正在修复：' + a.name + (a.level === 'yellow' ? '（先生成回滚包，再执行）…' : '…'), '');
  let slot = card.querySelector('.ac-result');
  if (!slot) { slot = document.createElement('div'); slot.className = 'ac-result'; card.appendChild(slot); }
  slot.innerHTML = '<div class="rr-big running">正在修复：' + esc(a.name) + '…</div>' +
    '<div class="rr-sub">（要做的事：' + esc((a.steps || []).map((s) => s.desc).join('；')) + '）</div>';
  try {
    const r = await fetch('/api/repair/run', {
      method: 'POST', cache: 'no-store',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: a.id, restore_point: !!opts.restorePoint, skip_restore_point: !!opts.skipRp }),
    });
    const j = await r.json();
    if (!j.ok) { renderRepairResult(slot, { ok: false, human: j.error || '启动失败' }); return; }
    for (let i = 0; i < 200; i++) {
      await new Promise((res) => setTimeout(res, 700));
      let st;
      try { st = await (await fetch('/api/repair/status', { cache: 'no-store' })).json(); }
      catch (e) { continue; }
      if (st.state === 'done' && st.result) { S.repairDoneIds[a.id] = st.result; renderRepairResult(slot, st.result); if (st.result.ok) scheduleSense(a); return; }
      if (st.state === 'idle') { renderRepairResult(slot, { ok: false, human: '修复状态丢失，请重试' }); return; }
    }
    renderRepairResult(slot, { ok: false, human: '修复等太久了（超时），请重试' });
  } catch (e) {
    renderRepairResult(slot, { ok: false, human: '连接不上本地服务，请关掉窗口重新打开' });
  } finally {
    setRepairBusy(false, btn);
    setStatus('就绪', '');
  }
}
function setRepairBusy(busy, btn) {
  S.repairBusy = busy;
  if (busy) { $$('.act-run').forEach((b) => { b.dataset.origLabel = b.textContent; b.disabled = true; }); if (btn) btn.textContent = '修复中…'; }
  else { $$('.act-run').forEach((b) => { b.disabled = false; if (b.dataset.origLabel) b.textContent = b.dataset.origLabel; }); REPH.stale = true; }
}
/* ---------- 修复小史（1024 自主迭代轮C）：最近修过什么、成没成（数据根 repair-log.json 经 server 精简投影） ---------- */
const REPH = { loaded: false, stale: true, rows: [] };
async function loadRepairHistory(force) {
  const box = $('#rep-hist-body'), wrap = $('#repair-hist');
  if (!box || !wrap) return;
  if (REPH.loaded && !REPH.stale && !force) { wrap.classList.toggle('hidden', !REPH.rows.length); return; }
  try {
    const r = await fetch('/api/repair/history', { cache: 'no-store' });
    const j = await r.json();
    REPH.rows = j.history || [];
  } catch (e) { REPH.rows = []; }
  REPH.loaded = true; REPH.stale = false;
  if (!REPH.rows.length) { wrap.classList.add('hidden'); return; }
  box.innerHTML = REPH.rows.map((h) => {
    const lv = LV_META[h.level] ? LV_META[h.level].word.split(' ')[0] : '';
    let res;
    if (h.ok) res = '<span class="rh-ok">修好了</span>';
    else if (h.rp === 'failed') res = '<span class="rh-bad">没执行（还原点没建成，安全中止）</span>';
    else res = '<span class="rh-bad">没修好' + (h.fail_stage ? '（' + esc(h.fail_stage) + '）' : '') + '</span>';
    return '<div class="rh-row"><span class="rh-time">' + esc(h.time) + '</span><span class="rh-name">' + esc(h.name) + '</span>' +
      (lv ? '<span class="rh-lv lv-' + esc(h.level) + '">' + lv + '</span>' : '') + res + '</div>';
  }).join('');
  wrap.classList.remove('hidden');
}
/* 修复结果：大结论 + 复查提炼 + 下一步；五段明细折叠，失败默认展开 */
function renderRepairResult(slot, res) {
  slot.innerHTML = '';
  if (!res || !res.stages) {
    slot.appendChild(rrBig('bad', '✗ ' + ((res && res.human) || '没有拿到修复结果')));
    return;
  }
  const ok = !!res.ok;
  slot.appendChild(rrBig(ok ? 'ok' : 'bad', (ok ? '✓ 修好了' : '✗ 没修好') + ' · ' + (res.human || '')));
  const vf = res.stages.verify;
  if (vf && (vf.checks || []).length) {
    vf.checks.forEach((c) => {
      const l = document.createElement('div');
      l.className = 'rr-verify ' + (c.status === 'PASS' ? 'st-pass' : c.status === 'FAIL' ? 'st-fail' : 'st-skip');
      l.textContent = c.status === 'PASS' ? '复查通过：' + humanCheck(c.name) + ' 已正常'
        : c.status === 'FAIL' ? '复查仍有问题：' + humanCheck(c.name) + '（修复方法见这张卡上方）'
        : '复查没查成：' + humanCheck(c.name);
      slot.appendChild(l);
    });
  }
  const next = document.createElement('div');
  next.className = 'rr-next' + (ok ? '' : ' bad');
  if (ok) {
    const sp = document.createElement('span');
    sp.textContent = '这个问题应该已经解决。建议回「体检向导」再跑一轮，确认它变正常。';
    const btn = document.createElement('button');
    btn.className = 'btn';
    btn.textContent = '去复查';
    btn.addEventListener('click', () => switchView('wizard'));
    next.appendChild(sp); next.appendChild(btn);
  } else {
    const sp = document.createElement('span');
    // 还原点没建成的安全中止：给两条出路而不是一句「重试」（1024 用户实锤：看不懂原因也不知道下一步）
    const rpAborted = res.fail_stage === 'rollback_pkg' && res.stages.pkg && res.stages.pkg.restore_point &&
      res.stages.pkg.restore_point.requested && !res.stages.pkg.restore_point.ok;
    if (rpAborted) {
      sp.textContent = '系统还原功能被关着（很多优化软件会关掉它）：①开启后再修——Win 搜索「创建还原点」→ 选 C 盘 → 配置 → 启用；②跳过还原点直接修——撤销脚本已备好，出问题双击它就能还原。';
      const skip = document.createElement('button');
      skip.className = 'btn';
      skip.textContent = '跳过还原点，直接修';
      skip.addEventListener('click', () => {
        const c = S.lastRepairCtx;
        if (c && c.a) startRepairRun(c.a, c.btn, c.card, { skipRp: true });
      });
      next.appendChild(sp); next.appendChild(skip);
      slot.appendChild(next);
      appendRepairDetailFold(slot, res);
      return;
    }
    sp.textContent = '可以再点一次「执行」重试，或点开下面的明细看哪一步没跑成。';
    next.appendChild(sp);
  }
  slot.appendChild(next);

  appendRepairDetailFold(slot, res);
}
/* 修复五段明细折叠（预检/回滚包/执行/复查/台账）——成功默认收起、失败自动展开 */
function appendRepairDetailFold(slot, res) {
  const ok = !!res.ok;
  const fold = document.createElement('details');
  fold.className = 'steps-fold';
  const foldSum = document.createElement('summary');
  foldSum.textContent = '看修复过程明细';
  fold.appendChild(foldSum);
  const body = document.createElement('div');
  const st = res.stages;
  const pre = st.precheck;
  if (pre) {
    const l = document.createElement('div');
    l.className = 'stage-line ' + (pre.ok ? 'st-pass' : 'st-fail');
    l.textContent = (pre.ok ? '✓ ① 预检通过' : '✗ ① 预检没过：' + (pre.notes || []).join('；'));
    body.appendChild(l);
  }
  const pkg = st.pkg;
  if (pkg) {
    const rp = pkg.restore_point || {};
    let rpTxt = '';
    if (rp.requested) rpTxt = rp.ok ? '；系统还原点已备好' : '；✗ 系统还原点没建成';
    const l = document.createElement('div');
    l.className = 'stage-line ' + (pkg.ok ? 'st-pass' : 'st-fail');
    if (pkg.ok) {
      const uf = String(pkg.undo_file || '').split(/[\\/]/).pop();
      l.textContent = '✓ ② 回滚包已生成（撤销脚本 ' + uf + rpTxt + '）';
    } else {
      l.textContent = '✗ ② 回滚包：' + (pkg.note || '没生成') + rpTxt;
    }
    body.appendChild(l);
  }
  if (st.exec) {
    (st.exec.steps || []).forEach((s) => {
      const l = document.createElement('div');
      l.className = 'stage-line ' + (s.exit === 0 && !s.timed_out ? 'st-pass' : 'st-fail');
      l.textContent = (s.exit === 0 && !s.timed_out ? '✓ ③ ' : '✗ ③ ') + (s.desc || '') +
        (s.timed_out ? '：超时被停' : (s.exit !== 0 ? '：没跑成（退出码 ' + s.exit + '）' : '（' + ((s.ms || 0) / 1000).toFixed(1) + ' 秒）'));
      body.appendChild(l);
      if (s.out_head) {
        const o = document.createElement('div');
        o.className = 'stage-out';
        o.textContent = s.out_head;
        body.appendChild(o);
      }
    });
    if (!(st.exec.steps || []).length && st.exec.note) {
      const l = document.createElement('div');
      l.className = 'stage-line st-skip';
      l.textContent = '– ③ ' + st.exec.note;
      body.appendChild(l);
    }
  }
  const vf = st.verify;
  if (vf) {
    if ((vf.checks || []).length) {
      (vf.checks || []).forEach((c) => {
        const l = document.createElement('div');
        l.className = 'stage-line ' + (c.status === 'PASS' ? 'st-pass' : c.status === 'FAIL' ? 'st-fail' : 'st-skip');
        l.textContent = (c.status === 'PASS' ? '✓ ④ 复查 ' : c.status === 'FAIL' ? '✗ ④ 复查 ' : '– ④ 复查 ') +
          humanCheck(c.name) + (c.status === 'PASS' ? '：正常' : c.status === 'FAIL' ? '：仍有问题（修复方法见这张卡上方）' : '：没查成');
        body.appendChild(l);
      });
    } else if (vf.note) {
      const l = document.createElement('div');
      l.className = 'stage-line st-skip';
      l.textContent = '– ④ ' + vf.note;
      body.appendChild(l);
    }
  }
  const lg = st.log;
  if (lg) {
    const l = document.createElement('div');
    l.className = 'stage-line ' + (lg.ok ? 'st-dim' : 'st-fail');
    l.textContent = lg.ok ? '✓ ⑤ 已记入修复台账（reports/repair-log.json）' : '✗ ⑤ 台账没写上：' + (lg.err || '');
    body.appendChild(l);
  }
  fold.appendChild(body);
  fold.open = !ok;
  slot.appendChild(fold);
}
function rrBig(cls, text) {
  const l = document.createElement('div');
  l.className = 'rr-big ' + cls;
  l.textContent = text;
  return l;
}

/* ---------- 关闭确认 ---------- */
$('#btn-close').addEventListener('click', () => {
  if (S.appState === 'running') { $('#overlay').classList.remove('hidden'); return; }
  doShutdown();
});
$('#modal-stay').addEventListener('click', () => $('#overlay').classList.add('hidden'));
$('#modal-exit').addEventListener('click', async () => {
  $('#overlay').classList.add('hidden');
  doShutdown();
});
async function doShutdown() {
  stopPolling(); stopElapsed();
  try { await fetch('/api/shutdown', { method: 'POST', cache: 'no-store' }); } catch (e) {}
  window.close();
  setTimeout(() => { $('#bye-overlay').classList.remove('hidden'); }, 350);
}
$('#bye-ok').addEventListener('click', () => { window.close(); });
$('#copy-ok').addEventListener('click', () => $('#copy-overlay').classList.add('hidden'));

window.addEventListener('beforeunload', (e) => {
  if (S.appState === 'running') { e.preventDefault(); e.returnValue = ''; }
});
window.addEventListener('pagehide', () => {
  try { navigator.sendBeacon('/api/bye'); } catch (e) {}
});

/* ---------- 外观：明暗 + 强调色 + 背景原画（合并为一个菜单） ---------- */
const ACCENTS = { blue: '#4cc2ff', cyan: '#2dd4bf', green: '#3fd68f', violet: '#a78bfa', orange: '#ffb35c', pink: '#ff7b9c' };
const ACCENT_NAMES = { blue: '蓝色', cyan: '青色', green: '绿色', violet: '紫色', orange: '橙色', pink: '粉色' };
function sysTheme() { return (window.matchMedia && matchMedia('(prefers-color-scheme: light)').matches) ? 'light' : 'dark'; }
function resolveTheme(t) { return t === 'light' ? 'light' : 'dark'; }
function applyTheme(theme, accent) {
  const h = document.documentElement;
  // theme 可为 'auto'（跟随系统）：存原值、界面按解析后的实际明暗渲染
  h.dataset.theme = theme === 'auto' ? sysTheme() : resolveTheme(theme);
  h.dataset.accent = accent;
  try { localStorage.setItem('diag-theme2', JSON.stringify({ t: theme, a: accent })); } catch (e) {}
  $$('[data-theme-opt]').forEach((b) => {
    const on = b.dataset.themeOpt === theme;
    b.classList.toggle('active', on);
    b.setAttribute('aria-checked', on ? 'true' : 'false');
  });
  $$('.swatch').forEach((s) => {
    const on = s.dataset.accentKey === accent;
    s.classList.toggle('active', on);
    s.setAttribute('aria-checked', on ? 'true' : 'false');
  });
}
function initTheme() {
  let cfg = { t: 'auto', a: 'cyan' }; // 新用户默认跟随系统明暗（自主迭代轮B）；老用户已存的 dark/light 手选不动
  try { const raw = localStorage.getItem('diag-theme2'); if (raw) cfg = JSON.parse(raw); } catch (e) {}
  if (!ACCENTS[cfg.a]) cfg.a = 'cyan';
  if (cfg.t !== 'light' && cfg.t !== 'dark' && cfg.t !== 'auto') cfg.t = 'auto';
  // 系统明暗切换时，「自动」模式实时跟随（手选的 dark/light 不受影响）
  try {
    matchMedia('(prefers-color-scheme: light)').addEventListener('change', () => {
      try { const c = JSON.parse(localStorage.getItem('diag-theme2') || '{}'); if (c.t === 'auto') applyTheme('auto', c.a || 'cyan'); } catch (e) {}
    });
  } catch (e) {}
  const row = $('#accent-row');
  Object.keys(ACCENTS).forEach((k) => {
    const s = document.createElement('button');
    s.className = 'swatch';
    s.dataset.accentKey = k;
    s.title = ACCENT_NAMES[k];
    s.setAttribute('aria-label', '强调色：' + ACCENT_NAMES[k]);
    s.setAttribute('aria-checked', 'false');
    s.style.background = ACCENTS[k];
    s.addEventListener('click', () => applyTheme(document.documentElement.dataset.theme || 'dark', k));
    row.appendChild(s);
  });
  $$('[data-theme-opt]').forEach((b) => {
    b.addEventListener('click', () => applyTheme(b.dataset.themeOpt, document.documentElement.dataset.accent || 'cyan'));
  });
  applyTheme(cfg.t, cfg.a);

  const menu = $('#appearance-menu');
  const aBtn = $('#btn-appearance');
  const setMenu = (open) => {
    menu.classList.toggle('hidden', !open);
    aBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (open) { const cur = menu.querySelector('.seg-btn.active'); if (cur) cur.focus(); }
  };
  aBtn.addEventListener('click', (e) => { e.stopPropagation(); setMenu(menu.classList.contains('hidden')); });
  document.addEventListener('click', (e) => {
    if (menu.classList.contains('hidden')) return;
    if (menu.contains(e.target) || aBtn.contains(e.target)) return;
    setMenu(false);
  });
  $('#appearance-reset').addEventListener('click', () => { applyTheme('auto', 'cyan'); setMenu(false); });
}

/* ---------- 背景图原画弹层（点任意处关闭；图缺失时 img 不渲染，层仍可开不致命） ---------- */
$('#btn-bg').addEventListener('click', () => {
  $('#appearance-menu').classList.add('hidden');
  $('#btn-appearance').setAttribute('aria-expanded', 'false');
  $('#bg-overlay').classList.remove('hidden');
});
$('#bg-overlay').addEventListener('click', () => $('#bg-overlay').classList.add('hidden'));

/* Esc：先关菜单，再关最上层弹层 */
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  const menu = $('#appearance-menu');
  if (menu && !menu.classList.contains('hidden')) {
    menu.classList.add('hidden');
    $('#btn-appearance').setAttribute('aria-expanded', 'false');
    $('#btn-appearance').focus();
    return;
  }
  const layers = ['guide-overlay', 'repair-modal', 'copy-overlay', 'bg-overlay', 'overlay', 'bye-overlay'];
  for (const id of layers) {
    const el = document.getElementById(id);
    if (el && !el.classList.contains('hidden')) { el.classList.add('hidden'); return; }
  }
});

/* ---------- 术语小抄 ---------- */
function buildGlossary() {
  const list = $('#glossary-list');
  if (!list) return;
  Object.keys(GLOSSARY).forEach((k) => {
    const dt = document.createElement('dt');
    dt.textContent = k;
    const dd = document.createElement('dd');
    dd.textContent = GLOSSARY[k];
    list.appendChild(dt);
    list.appendChild(dd);
  });
}

/* ---------- 工具 ---------- */
function esc(s) {
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/* ---------- 启动 ---------- */
// 探针（仅 ?probe 出现时激活）：视口实测写进窗口标题，UIA/Get-Process 可读（自动化诊断用）
if (/[?&]probe/.test(location.search)) {
  const updProbe = () => {
    document.title = 'PROBE iw=' + window.innerWidth + ' sw=' + document.documentElement.scrollWidth + ' dpr=' + window.devicePixelRatio;
  };
  updProbe();
  window.addEventListener('resize', updProbe);
}
(async function init() {
  initTheme();
  buildGlossary();
  try {
    const r = await fetch('/api/meta', { cache: 'no-store' });
    S.meta = await r.json();
  } catch (e) {
    setStatus('连接不上本地服务，请关掉窗口重新打开', 'err');
    return;
  }
  buildChecks();
  updateSelUi();
  try {
    const rr = await fetch('/api/repair/list', { cache: 'no-store' });
    const rj = await rr.json();
    if (rj.ok) S.repairActions = rj.actions || [];
  } catch (e) {}

  // 页面刷新恢复：server 侧若正在跑，重放事件接着显示
  try {
    const r = await fetch('/api/events?since=0', { cache: 'no-store' });
    const p = await r.json();
    if (p.state === 'running') {
      const treeArg = p.runTree || 'all';
      S.fast = p.runFull === false;
      S.expectSeq = [];
      S.meta.trees.forEach((t) => {
        if (treeArg !== 'all' && t.id !== treeArg) return;
        t.layers.forEach((l) => l.checks.forEach((c) => S.expectSeq.push({ tree: t.id, layer: l.name, layerTitle: l.title, check: c })));
      });
      S.appState = 'running'; setTitleProgress(0);
      $('#select-card').classList.add('disabled');
      $$('#select-card input').forEach((i) => (i.disabled = true));
      $('#run-card').classList.remove('hidden');
      S.runStartAt = Date.now() - (p.elapsedSec || 0) * 1000;
      (p.events || []).forEach((ev) => handleEvent(ev));
      S.lastSeq = p.lastSeq;
      const btn = $('#btn-run');
      btn.textContent = '取消'; btn.disabled = false; btn.classList.add('running');
      startPolling(); startElapsed();
      setStatus('正在体检…（页面刷新过，接着显示）', '');
    }
  } catch (e) {}

  // server 侧已跑完（页面刷新过）：静默拉报告，结果中心/修复中心保持有数据
  try {
    const r0 = await fetch('/api/events?since=0', { cache: 'no-store' });
    const p0 = await r0.json();
    if (p0.state === 'done') {
      S.appState = 'done';
      S.htmlUrl = p0.htmlUrl || '';
      await loadReport();
      $('#btn-run').textContent = '再跑一次';
      updateSelUi();
      markGuided(); // server 侧已跑完＝跑过一轮体检：首次引导卡同样永久收起（防跑完瞬间刷新回潮）
    }
  } catch (e) {}
  updateResultsShell();
  renderLastRun();
  renderFirstGuide();
})();

/* ---------- 历史对比（1024 轮4/5：报告列表+两次对比+问题数趋势；纯前端展示层，判定零碰） ---------- */
const HIST = { loaded: false, reports: [] };

function histCheckMap(rep) {
  // rep = 报告 JSON（trees[].layers[].checks[]）→ { checkName: 'PASS'|'FAIL'|'SKIP', title, tree }
  const map = {};
  (rep.trees || []).forEach((t) => {
    (t.layers || []).forEach((l) => {
      (l.checks || []).forEach((c) => {
        map[c.name] = { status: c.status, tree: t.tree };
      });
    });
  });
  return map;
}
/* 和上次比（1024 自主迭代轮A）：结果页顶部一行摘要——本次 vs 上一份历史报告；
   纯前端复用对比口径（改善=上次 FAIL 这次不 FAIL；新增=上次不 FAIL 这次 FAIL），明细去历史对比页看 */
async function renderDeltaBar() {
  const el = $('#delta-bar'); if (!el) return;
  try {
    const r = await fetch('/api/reports/list', { cache: 'no-store' });
    const list = ((await r.json()).reports) || [];
    if (list.length < 2 || !S.reportPayload) { el.classList.add('hidden'); return; }
    const rr = await fetch('/reports/' + encodeURIComponent(list[1].file), { cache: 'no-store' });
    const pm = histCheckMap(await rr.json());
    const nm = histCheckMap(S.reportPayload.report);
    let better = 0, worse = 0;
    Object.keys(nm).forEach((k) => {
      const was = pm[k] ? pm[k].status : null, now = nm[k].status;
      if (was === 'FAIL' && now !== 'FAIL') better++;
      if (was !== 'FAIL' && now === 'FAIL') worse++;
    });
    const when = list[1].mtime.slice(5, 16);
    let txt;
    if (better && worse) txt = '和上次体检（' + when + '）比：修好了 ' + better + ' 项，又新冒出来 ' + worse + ' 项';
    else if (better) txt = '和上次体检（' + when + '）比：修好了 ' + better + ' 项，没有新问题';
    else if (worse) txt = '和上次体检（' + when + '）比：上次的问题都还在，又新冒出来 ' + worse + ' 项';
    else txt = '和上次体检（' + when + '）比：没有变化';
    el.innerHTML = '<div class="delta-txt">' + esc(txt) + '</div><button class="btn" id="delta-go">去历史对比看明细</button>';
    el.classList.remove('hidden');
    $('#delta-go').addEventListener('click', () => switchView('history'));
  } catch (e) { el.classList.add('hidden'); }
}
function histFailCount(map) { return Object.values(map).filter((v) => v.status === 'FAIL').length; }
function histHuman(name) { return CHECK_HUMAN[name] || name; }

async function loadHistory(force) {
  if (HIST.loaded && !force) return;
  let list = [];
  try {
    const r = await fetch('/api/reports/list', { cache: 'no-store' });
    const j = await r.json();
    list = j.reports || [];
  } catch (e) {
    $('#hist-list').innerHTML = '<div class="placeholder">历史记录暂时读不到。</div>';
    return;
  }
  // 逐份拉详情（只取每份的结构化摘要：时间/树/检查状态/FAIL 数）
  const items = [];
  for (const it of list) {
    try {
      const rr = await fetch('/reports/' + encodeURIComponent(it.file), { cache: 'no-store' });
      const rep = await rr.json();
      const map = histCheckMap(rep);
      items.push({ file: it.file, mtime: it.mtime, trees: (rep.trees || []).map((t) => t.report_name || t.tree).join('+'), map, fails: histFailCount(map) });
    } catch (e) { /* 单份坏档跳过，不拖垮整页 */ }
  }
  HIST.reports = items;
  HIST.loaded = true;

  const listEl = $('#hist-list');
  if (!items.length) {
    listEl.innerHTML = '<div class="placeholder">还没有历史报告——跑完一轮体检，这里会记住每次的结果。</div>';
    $('#hist-compare-card').hidden = true;
    $('#hist-trend-card').hidden = true;
    return;
  }
  listEl.innerHTML = items.map((r) =>
    '<div class="hist-item"><span class="hist-time">' + r.mtime + '</span>' +
    '<span class="hist-tree">' + r.trees + '</span>' +
    '<span class="hist-fail ' + (r.fails ? 'bad' : 'ok') + '">发现问题 ' + r.fails + ' 项</span></div>'
  ).join('');

  // 趋势（时间升序：改善还是恶化一眼可看）
  $('#hist-trend-card').hidden = false;
  const asc = items.slice().reverse();
  const maxF = Math.max(1, ...asc.map((r) => r.fails));
  $('#trend-list').innerHTML = asc.map((r) =>
    '<div class="trend-row"><span class="trend-time">' + r.mtime + '</span>' +
    '<span class="trend-bar"><i class="' + (r.fails ? 'bad' : 'ok') + '" style="width:' + Math.round(r.fails / maxF * 100) + '%"></i></span>' +
    '<span class="trend-val">' + r.fails + '</span></div>'
  ).join('');

  // 对比卡（≥2 份才开）
  if (items.length >= 2) {
    $('#hist-compare-card').hidden = false;
    const opt = (sel, arr) => sel.innerHTML = arr.map((r) => '<option value="' + r.file + '">' + r.mtime + '（' + r.trees + '，问题 ' + r.fails + ' 项）</option>').join('');
    opt($('#cmp-old'), items.slice(1));
    opt($('#cmp-new'), items.slice(0, 1));
  }
}

function buildCmpRows(om, nm) {
  const rows = [];
  let better = 0, worse = 0;
  // 只展示「有信息量」的行：状态变化了、或两次都是 FAIL（还没修好的老问题）
  Object.keys(nm).forEach((name) => {
    const n = nm[name], o = om[name];
    if (!o) { rows.push({ name, tag: '新增', cls: 'worse', txt: '上次没查到，这次：' + n.status }); if (n.status === 'FAIL') worse++; return; }
    if (o.status === n.status) {
      if (n.status === 'FAIL') rows.push({ name, tag: '仍在', cls: 'still', txt: '两次都有问题，还没修好' });
      return;
    }
    if (n.status === 'FAIL') { rows.push({ name, tag: '恶化', cls: 'worse', txt: o.status + ' → 有问题' }); worse++; }
    else if (o.status === 'FAIL') { rows.push({ name, tag: '改善', cls: 'better', txt: '有问题 → ' + n.status }); better++; }
    else { rows.push({ name, tag: '变化', cls: 'still', txt: o.status + ' → ' + n.status }); }
  });
  Object.keys(om).forEach((name) => {
    if (!nm[name]) rows.push({ name, tag: '未查', cls: 'still', txt: '这次体检没查到这一项（可能前面断点截断）' });
  });
  return { rows, better, worse };
}
function buildCmpHtml(om, nm, oldFails, newFails, sameWord) {
  const r = buildCmpRows(om, nm);
  const sum = '<div class="cmp-sum">问题数 <b>' + oldFails + '</b> → <b>' + newFails + '</b>' +
    '　·　<span class="better">改善 ' + r.better + ' 项</span>　<span class="worse">恶化/新增 ' + r.worse + ' 项</span></div>';
  const table = r.rows.length
    ? '<div class="cmp-rows">' + r.rows.map((r2) =>
        '<div class="cmp-row ' + r2.cls + '"><span class="cmp-tag">' + r2.tag + '</span><span class="cmp-name">' + histHuman(r2.name) + '</span><span class="cmp-txt">' + r2.txt + '</span></div>'
      ).join('') + '</div>'
    : '<div class="placeholder">' + (sameWord || '两次结果一致，全部正常或没有变化。') + '</div>';
  return sum + table;
}
function renderCompare(oldRep, newRep) {
  $('#cmp-out').innerHTML = buildCmpHtml(oldRep.map, newRep.map, oldRep.fails, newRep.fails);
}

$('#btn-compare').addEventListener('click', async () => {
  const of = $('#cmp-old').value, nf = $('#cmp-new').value;
  if (!of || !nf) return;
  const find = (f) => HIST.reports.find((r) => r.file === f);
  const a = find(of), b = find(nf);
  if (!a || !b) return;
  $('#cmp-out').innerHTML = '<div class="placeholder">正在对比…</div>';
  renderCompare(a, b);
});


/* ---------- 修复后感知（1024 轮6：修复成功→自动对关联树快扫→修复前后对比+再感知一次；复用轮4/5 对比引擎） ---------- */
function treeOfCheck(n) {
  return ({ net: 'network', bs: 'bluescreen', hw: 'hardware', pf: 'performance', dv: 'drivers' })[(n || '').split('_')[0]] || null;
}
function scheduleSense(action) {
  const mc = (action && action.match_checks) || [];
  const tree = mc.length ? treeOfCheck(mc[0]) : null;
  if (!tree) return;
  S.lastSenseAction = action;
  S.reportBeforeFix = S.reportPayload ? JSON.parse(JSON.stringify(S.reportPayload)) : null;
  S.pendingSense = true;
  setStatus('修复完成，正在感知电脑当前状态…', '');
  setTimeout(() => { switchView('wizard'); startRun({ tree, fast: true }); }, 900);
}
function renderFixSense() {
  const before = S.reportBeforeFix, after = S.reportPayload;
  let host = $('#fix-sense-card');
  if (!host) {
    host = document.createElement('div');
    host.id = 'fix-sense-card';
    host.className = 'card';
    const view = $('#view-repair');
    view.insertBefore(host, view.querySelector('.card'));
  }
  const repOf = (p) => (p && p.report && p.report.trees) ? p.report : p;
  if (!before || !after) {
    host.innerHTML = '<div class="card-title">修复后感知</div><div class="placeholder">还没有修复前后的对比数据——修复成功后会自动感知一次，或点下方按钮手动感知。</div>';
    appendSenseBtn(host);
    return;
  }
  const om = histCheckMap(repOf(before)), nm = histCheckMap(repOf(after));
  const title = '<div class="card-title">修复后感知 · 刚才那一下修完，电脑现在怎么样</div>';
  host.innerHTML = title + buildCmpHtml(om, nm, histFailCount(om), histFailCount(nm), '两次感知结果一致，全部正常。');
  appendSenseBtn(host);
}
function appendSenseBtn(host) {
  const btn = document.createElement('button');
  btn.className = 'btn';
  btn.style.marginTop = '10px';
  btn.textContent = '再感知一次';
  btn.onclick = () => {
    if (!S.lastSenseAction) return;
    scheduleSense(S.lastSenseAction);
  };
  host.appendChild(btn);
}

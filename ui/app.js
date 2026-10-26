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

const APP_VERSION = 'v1.6.1';

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

/* ---------- i18n（1025 双语轮）：语言包直载（i18n/zh-CN.js + en-US.js，零 fetch） ----------
   t(key) 点路径取词：当前语言缺 key → 回退中文（zh-CN 表）+ console.warn（漏译不白屏）；
   tf(key, vars) 做 {name} 占位替换。语言记忆 localStorage 'diag-lang'，默认 zh-CN（未存=中文，行为不变）。
   切换=写 localStorage 后 location.reload()：跑批中有 server 事件重放恢复路径（C1 后 reload 实锤），状态全量重建零半译残留。 */
const I18N_LANG_KEY = 'diag-lang';
let LANG = 'zh-CN';
function i18nGet(tab, key) {
  return String(key).split('.').reduce((o, k) => (o == null ? undefined : o[k]), tab);
}
function t(key) {
  let v = i18nGet(window.I18N_ZH || {}, key);
  if (LANG !== 'zh-CN') {
    const en = i18nGet(window.I18N_EN || {}, key);
    if (en !== undefined) return en;
    console.warn('[i18n] missing en key, fallback zh: ' + key);
  }
  if (v === undefined) { console.warn('[i18n] missing key: ' + key); return key; }
  return v;
}
function tf(key, vars) {
  let s = t(key);
  if (vars) Object.keys(vars).forEach((k) => { s = s.split('{' + k + '}').join(String(vars[k])); });
  return s;
}
/* 动作字段取词：json 数据文件是中文真源（零碰），en 模式查 en-US.actions[id]，缺→中文原值+warn */
function enAction(a) {
  return (LANG !== 'zh-CN' && window.I18N_EN && window.I18N_EN.actions) ? window.I18N_EN.actions[a.id] : null;
}
function actField(a, field) {
  const raw = a[field];
  if (LANG === 'zh-CN') return raw;
  const en = enAction(a);
  const v = en ? en[field] : undefined;
  if (typeof v === 'string' && v) return v;
  console.warn('[i18n] missing action field: ' + a.id + '.' + field);
  return raw;
}
function actSteps(a) {
  const raw = a.steps || [];
  if (LANG === 'zh-CN') return raw;
  const en = enAction(a);
  if (!en || !Array.isArray(en.steps)) { console.warn('[i18n] missing action steps: ' + a.id); return raw; }
  return raw.map((st, i) => (en.steps[i] ? Object.assign({}, st, en.steps[i]) : st));
}
function actSource(a, s, i) {
  if (LANG === 'zh-CN') return s.title;
  const en = enAction(a);
  const v = en && Array.isArray(en.sources) ? en.sources[i] : undefined;
  if (typeof v === 'string' && v) return v;
  console.warn('[i18n] missing action source: ' + a.id + '#' + i);
  return s.title;
}
/* 建议正文英译（1026 方案 B M1）：engine suggestion 恒中文，en 模式按 check_id 查 en-US.suggestions
   模板并用 detail 回填 {占位符}；缺模板/缺变量/zh 语言=回退中文原文（渐进覆盖，翻多少亮多少）。
   占位符来源=engine JSON 的 detail 字段：直通字段同名直取；派生变量（deadList=死地址去重列表、
   avgSec=毫秒转秒、分支键选择）在 SUGGEST_EN_PICK/SUGGEST_EN_VARS，分支序照抄检查脚本（只选词
   不判定）。对齐关系由 tests/cases_i18n.ps1 静态校验把守，改模板/改派生规则须同步那边的声明。 */
function sugTplKey(name, detail) {
  if (name === 'pf_boot_duration') {
    return (detail && Number(detail.warnCount) >= 2) ? 'pf_boot_duration_marks' : 'pf_boot_duration_avg';
  }
  return name;
}
/* engine 落盘 JSON 的 ConvertTo-Json 逐层计数深度有限，嵌套对象（findings 数组元素）被压成
   PS 转储串 "@{k=v; k2=v2}"（扁平标量 detail 幸存为真对象）。适配层容错解析取 verdict/dns；
   根治=engine 落盘加深序列化深度，属判定层禁区，已登记 M2 议。 */
function psDumpVars(s) {
  const out = {};
  const re = /([A-Za-z_][A-Za-z0-9_]*)=([^;}]*)/g;
  let m; while ((m = re.exec(String(s)))) out[m[1]] = m[2].trim();
  return out;
}
function sugVars(tplKey, detail) {
  const d = detail || {};
  if (tplKey === 'net_dns_deadaddr') {
    const seen = Object.create(null); const list = [];
    (Array.isArray(d.findings) ? d.findings : []).forEach((raw) => {
      const f = (typeof raw === 'string') ? psDumpVars(raw) : raw;
      if (f && f.verdict === 'DEAD-SUSPECT' && f.dns && !seen[f.dns]) { seen[f.dns] = 1; list.push(f.dns); }
    });
    return { deadList: list.join(' / ') };
  }
  if (tplKey === 'pf_boot_duration_marks') return { warnCount: d.warnCount };
  if (tplKey === 'pf_boot_duration_avg') return { avgSec: Math.round((Number(d.avgMs) || 0) / 1000) };
  return {};
}
function sugPlaceholders(tpl) {
  return (String(tpl).match(/\{[A-Za-z0-9_]+\}/g) || []).map((s) => s.slice(1, -1));
}
function enSuggestion(name, zhSug, detail) {
  if (LANG !== 'en-US' || !zhSug) return zhSug;
  const tplKey = sugTplKey(name, detail);
  const tpl = i18nGet(window.I18N_EN || {}, 'suggestions.' + tplKey);
  if (typeof tpl !== 'string' || !tpl) { console.warn('[i18n] missing suggestion template, fallback zh: ' + tplKey); return zhSug; }
  const vars = sugVars(tplKey, detail);
  const missing = sugPlaceholders(tpl).filter((p) => vars[p] === undefined || vars[p] === null || vars[p] === '');
  if (missing.length) { console.warn('[i18n] suggestion placeholders unresolvable, fallback zh: ' + tplKey + ' [' + missing.join(',') + ']'); return zhSug; }
  let s = tpl;
  Object.keys(vars).forEach((k) => { s = s.split('{' + k + '}').join(String(vars[k])); });
  return s;
}
/* 树/层取词：meta 树与报告树都用 tree id 查 en.groups.trees；ext 扩展树无词条→中文原值+warn（第三方内容不在产品翻译范围） */
function enTree(id) { return (LANG !== 'zh-CN' && window.I18N_EN && window.I18N_EN.groups && window.I18N_EN.groups.trees) ? window.I18N_EN.groups.trees[id] : null; }
function treeName(tdef) {
  if (LANG === 'zh-CN' || !tdef) return tdef ? tdef.name : '';
  const e = enTree(tdef.id);
  if (e && e.name) return e.name;
  console.warn('[i18n] missing tree: ' + tdef.id);
  return tdef.name;
}
function treeDesc(tdef) {
  if (LANG === 'zh-CN' || !tdef) return tdef ? tdef.desc : '';
  const e = enTree(tdef.id);
  if (e && e.desc) return e.desc;
  return tdef.desc;
}
function treeTip(tdef) {
  const titles = (tdef.layers || []).map((l) => layerTitle(tdef.id, l));
  return tf('chrome.tip_prefix', {}) + titles.join(' → ');
}
function layerTitle(treeId, l) {
  const zname = l.name || l.layer;         // meta 层对象用 name；期望序列项用 layer
  const ztitle = l.title || l.layerTitle;
  if (LANG === 'zh-CN') return ztitle;
  const e = enTree(treeId);
  const v = e && e.layers && e.layers[zname] ? e.layers[zname].title : undefined;
  if (v) return v;
  console.warn('[i18n] missing layer title: ' + treeId + '.' + zname);
  return ztitle;
}
function layerVfail(treeId, l) {
  if (LANG === 'zh-CN') return l.verdict_fail || '';
  const e = enTree(treeId);
  const v = e && e.layers && e.layers[l.name] ? e.layers[l.name].vfail : undefined;
  if (v) return v;
  console.warn('[i18n] missing layer verdict: ' + treeId + '.' + l.name);
  return l.verdict_fail || '';
}
/* 报告树名（engine 下发中文 report_name）→ 当前语言显示名（zh 去「报告」后缀的旧口径不变） */
function repNameDisplay(rep) {
  const s = String(rep == null ? '' : rep);
  if (LANG === 'zh-CN') return s.replace(/报告$/, '');
  const zhTrees = (window.I18N_ZH && window.I18N_ZH.groups && window.I18N_ZH.groups.trees) || {};
  for (const id in zhTrees) {
    if (zhTrees[id].report === s) {
      const e = enTree(id);
      if (e && e.name) return e.name;
    }
  }
  console.warn('[i18n] missing report name: ' + s);
  return s.replace(/报告$/, '');
}
/* 静态词条填充：data-i18n=textContent / data-i18n-html=innerHTML / data-i18n-title / data-i18n-aria */
function applyI18nStatic() {
  $$('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
  $$('[data-i18n-html]').forEach((el) => { el.innerHTML = t(el.dataset.i18nHtml); });
  $$('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); });
  $$('[data-i18n-aria]').forEach((el) => { el.setAttribute('aria-label', t(el.dataset.i18nAria)); });
  document.title = t('chrome.app_title');
  const sr = $('#status-right');
  if (sr) sr.innerHTML = '<span class="ver-chip">' + esc(tf('chrome.ver_chip', { v: APP_VERSION })) + '</span>';
}
/* 语言切换：写 localStorage → reload（跑批中有事件重放恢复；静态+动态区全量按新语言重建） */
function applyLang(lang) {
  if (lang !== 'en-US' && lang !== 'zh-CN') lang = 'zh-CN';
  try { localStorage.setItem(I18N_LANG_KEY, lang); } catch (e) {}
  location.reload();
}
function initLang() {
  let saved = null;
  try { saved = localStorage.getItem(I18N_LANG_KEY); } catch (e) {}
  LANG = (saved === 'en-US') ? 'en-US' : 'zh-CN';
  document.documentElement.lang = LANG;
  applyI18nStatic();
  $$('#lang-seg .seg-btn').forEach((b) => {
    const on = b.dataset.langOpt === LANG;
    b.classList.toggle('active', on);
    b.setAttribute('aria-checked', on ? 'true' : 'false');
    b.addEventListener('click', () => { if (b.dataset.langOpt !== LANG) applyLang(b.dataset.langOpt); });
  });
}
initLang(); // 立即执行：checkUpdateNotes 等加载期 IIFE 也要按记忆语言取词（defer 脚本时 DOM 已就绪）

const S = {
  meta: null,            // /api/meta：体检树定义（层/检查项/文案）
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

/* 状态词/人话名/一句话解释：文案真源在语言包（checks 段按检查项英文原名做 key） */
function statusWord(st) {
  if (st === 'PASS') return t('chrome.st_pass');
  if (st === 'FAIL') return t('chrome.st_fail');
  return t('chrome.st_skip');
}
const LAYER_NUM = ['①', '②', '③', '④', '⑤', '⑥'];

function humanCheck(n) {
  const k = 'checks.human.' + n;
  const v = tf(k, {});
  return (v === k) ? n : v;  // 未收录的检查项（如 ext 扩展）回退英文原名
}
function checkInfo(n) {
  const k = 'checks.info.' + n;
  const v = tf(k, {});
  return (v === k) ? '' : v;
}
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
/* 首次启动三步引导：无 diag-guided 键=没跑过体检→显示；体检完成写键→本会话收起+以后不再出现 */
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

/* ---------- 版本更新弹窗（更新内容在用户 UI 弹一次；只装最新一版，完整开发史=仓库 CHANGELOG.md） ---------- */
const RELEASE_NOTES = null; /* 更新说明文案真源=语言包 groups.notes（词条随语言切换） */
(function checkUpdateNotes() {
  let seen = null;
  try { seen = localStorage.getItem('diag-seen-ver'); } catch (e) {}
  if (seen === APP_VERSION) return;
  // 老用户（有使用痕迹）升级后弹一次；全新用户不弹（首次有三步引导卡，不叠弹窗），直接记版本
  let hasTraces = false;
  try {
    hasTraces = !!(localStorage.getItem('diag-guided') || localStorage.getItem('diag-last-run') || localStorage.getItem('diag-theme2'));
  } catch (e) {}
  const notes = (t('groups.notes.v1_5_0') || []);
  try { localStorage.setItem('diag-seen-ver', APP_VERSION); } catch (e) {}
  if (!hasTraces || !Array.isArray(notes) || !notes.length) return;
  $('#um-title').textContent = tf('groups.notes.um_title', { v: APP_VERSION });
  $('#um-list').innerHTML = notes.map((x) => '<li>' + esc(x) + '</li>').join('');
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
  const when = tf('chrome.date_md', { m: d.getMonth() + 1, d: d.getDate(), h: pad(d.getHours()), mm: pad(d.getMinutes()) });
  const extra = v.fails ? tf('chrome.last_run_fails', { n: v.fails }) : t('chrome.last_run_ok');
  el.textContent = tf('chrome.last_run', { when, n: v.total || 0, extra });
  el.classList.remove('hidden');
}
function setTitleProgress(pct) { document.title = (pct == null ? '' : pct + '% · ') + t('chrome.app_title'); }

/* 一句话人话解释已迁语言包 checks.info（checkInfo(n) 取词） */

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
  sec_defender_status: 'high', sec_defender_service: 'high', sec_defender_threats: 'high',
  sec_defender_exclusions: 'medium', sec_uac_level: 'medium', sec_firewall_profiles: 'medium',
  sec_bitlocker: 'low', sec_suspicious_tasks: 'medium',
};
/* 严重度词与说明：真源=语言包 groups.sev（word/desc） */
const SEV_META = {
  high: { get word() { return t('groups.sev.high.word'); }, get desc() { return t('groups.sev.high.desc'); }, cls: 'high' },
  medium: { get word() { return t('groups.sev.medium.word'); }, get desc() { return t('groups.sev.medium.desc'); }, cls: 'medium' },
  low: { get word() { return t('groups.sev.low.word'); }, get desc() { return t('groups.sev.low.desc'); }, cls: 'low' },
};
function checkSeverity(name) { return CHECK_SEVERITY[name] || 'medium'; }
const SEV_RANK = { high: 0, medium: 1, low: 2 };

/* 展示层问题族：把几十个检查项归成人能看懂的问题清单；标题/解释真源=语言包 groups.problem，
   本表只留归则（id/prefix），note 解释「这几项可能是一件事」 */
const PROBLEM_GROUPS = [
  { id: 'bsod', prefix: 'bs_' },
  { id: 'network', prefix: 'net_' },
  { id: 'hardware', prefix: 'hw_' },
  { id: 'driver', prefix: 'dv_' },
  { id: 'sec', prefix: 'sec_' },
  { id: 'app', prefix: 'pf_app_' },
  { id: 'perf', prefix: 'pf_' },
];
function groupTitle(gid) { return tf('groups.problem.' + gid + '.title', {}); }
function groupNote(gid) {
  const k = 'groups.problem.' + gid + '.note';
  const v = tf(k, {});
  return (v === k) ? '' : v;
}
function groupFor(name) {
  const g = PROBLEM_GROUPS.find((x) => name.indexOf(x.prefix) === 0);
  return g || { id: 'other', prefix: '' };
}

/* ---------- 先修这个（v1.4.0）：根因关联规则表 ----------
   跨树交叉定位——同一元凶的多项 FAIL 合并成一个行动项（如嫌疑驱动+网络过滤层+蓝屏码频次
   → 一个根因：过滤驱动）。命中门槛=规则 checks 里 ≥minHits 项 FAIL（单项不硬凑根因，归普通行动项）。
   排序分 score = 收益 gain × 把握 conf ÷ 风险 risk（手工标定，宁稳勿激进），而非纯严重度。
   纯前端展示层，判定逻辑零碰。target.action=跳修复中心对应动作卡；target.check=跳该项说明。 */
const CORR_RULES = [
  { id: 'disk_dying', minHits: 2,
    checks: ['hw_disk_health', 'hw_smart_predict', 'hw_disk_errors'],
    gain: 5, risk: 1, conf: 0.9, target: { check: 'hw_disk_health' } },
  { id: 'filter_driver', minHits: 2,
    checks: ['bs_suspect_drivers', 'dv_network_filters', 'bs_code_frequency'],
    gain: 5, risk: 3, conf: 0.8, target: { action: 'dv_filter_handling' } },
  { id: 'dns_side', minHits: 2,
    checks: ['net_dns_deadaddr', 'net_dns_default', 'net_dns_public'],
    gain: 4, risk: 1.5, conf: 0.85, target: { action: 'net_dns_public_set' } },
  { id: 'driver_residue', minHits: 2,
    checks: ['dv_driver_load_failures', 'dv_device_errors'],
    gain: 4, risk: 3, conf: 0.7, target: { action: 'dv_display_residue_card' } },
  { id: 'mem_hw', minHits: 2,
    checks: ['bs_whea_hardware', 'hw_memdiag_history', 'pf_app_crashes'],
    gain: 4, risk: 4, conf: 0.7, target: { action: 'bs_attribution_card' } },
  { id: 'proxy_mess', minHits: 2,
    checks: ['net_proxy_vpn', 'net_proxy_system', 'net_tcp_stall'],
    gain: 3, risk: 1.5, conf: 0.75, target: { action: 'net_winhttp_reset' } },
  { id: 'boot_burden', minHits: 2,
    checks: ['pf_boot_duration', 'pf_boot_degradation_events', 'pf_startup_items'],
    gain: 3, risk: 1, conf: 0.8, target: { check: 'pf_startup_items' } },
];
function corrTitle(rule) { return tf('groups.corr.' + rule.id + '.title', {}); }
function corrWhy(rule) { return tf('groups.corr.' + rule.id + '.why', {}); }
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
  title.textContent = t('chrome.ff_title');
  box.appendChild(title);
  const intro = document.createElement('div');
  intro.className = 'ff-intro';
  intro.textContent = t('chrome.ff_intro');
  box.appendChild(intro);

  ruleItems.forEach(({ rule, hits }) => {
    const item = document.createElement('div');
    item.className = 'ff-item';
    item.dataset.rule = rule.id;
    const head = document.createElement('div');
    head.className = 'ff-head';
    const tag = document.createElement('span');
    tag.className = 'ff-tag';
    tag.textContent = t('chrome.ff_tag_merge');
    const tEl = document.createElement('b');
    tEl.textContent = corrTitle(rule);
    head.appendChild(tag); head.appendChild(tEl);
    item.appendChild(head);
    const why = document.createElement('div');
    why.className = 'ff-why';
    why.textContent = corrWhy(rule);
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
    go.textContent = t('chrome.ff_go');
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
    const tEl = document.createElement('b');
    tEl.textContent = humanCheck(e.name);
    head.appendChild(tag); head.appendChild(tEl);
    item.appendChild(head);
    const act = (S.repairActions || []).find((a) => (a.match_checks || []).indexOf(e.name) >= 0);
    const why = document.createElement('div');
    why.className = 'ff-why';
    why.textContent = act ? tf('chrome.ff_has_action', { name: actField(act, 'name') }) +
      (act.level === 'green' ? t('chrome.ff_green') : act.level === 'yellow' ? t('chrome.ff_yellow') : t('chrome.ff_red'))
      : t('chrome.ff_no_action');
    item.appendChild(why);
    const btnRow = document.createElement('div');
    btnRow.className = 'ff-btns';
    const go = document.createElement('button');
    go.className = 'btn';
    go.textContent = t('chrome.ff_go');
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

/* 术语小抄：真源=语言包 groups.glossary；第一次用的人不读说明也能对上号 */
function glossaryEntries() {
  const g = (LANG === 'zh-CN' ? (window.I18N_ZH || {}) : (window.I18N_EN || window.I18N_ZH || {}));
  const table = i18nGet(g, 'groups.glossary');
  return table && typeof table === 'object' ? table : {};
}

const ADMIN_SKIP_TEXT_KEY = 'checks.admin_skip_text';

/* ADMIN_SKIP / SKIP_TAG 文案已迁语言包 checks 段（adminSkipNote / skipTag 取词） */

/* 管理员缺失解释 / SKIP 原因标签：真源=语言包 checks 段；isAdminSkip 证据正则不变（原文判定） */
function isAdminSkip(name, evidence) {
  if (t('checks.admin_skip.' + name) !== 'checks.admin_skip.' + name) return true;
  return /管理员|权限|拒绝访问|access is denied|access-denied|unauthorized/i.test(evidence || '');
}
function adminSkipNote(name) {
  const k = 'checks.admin_skip.' + name;
  const v = tf(k, {});
  return (v === k) ? t('checks.admin_skip_text') : v;
}
function skipTag(name) {
  const k = 'checks.skip_tag.' + name;
  const v = tf(k, {});
  return (v === k) ? t('chrome.pl_no_result') : v;
}

function exitHuman(code) {
  if (code === 0) return t('chrome.exit_ok');
  if (code === 2) return t('chrome.exit_fail');
  if (code === 3) return t('chrome.exit_err');
  return tf('chrome.exit_code', { n: code });
}
function setStatus(text, cls, state) {
  const el = $('#status-left');
  el.textContent = text;
  el.className = cls || '';
  el.dataset.state = cls === 'err' ? 'stop' : (state === 'run' || /^正在/.test(text)) ? 'running' : 'idle';
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
  // 跑完/取消/出错后从结果、历史页切回向导时，勾选表单要跟着解锁（跑动中仍保持锁定：
  // enterRunningUi 调本函数时 appState 已='running'，守卫不会误解锁）
  if (name === 'wizard' && S.appState !== 'running') unlockSelection();
}
$('#tabs').addEventListener('click', (e) => {
  const t = e.target.closest('.tab');
  if (t) switchView(t.dataset.view);
});

/* 心跳：页面存活=server 存活；窗关=心跳断→server 杀引擎自杀。
   body 带 {hidden}：页面隐藏时浏览器把定时器强节流到约 1 次/分钟，
   server 见 hidden=true 就把兜底线放宽（见 server.ps1 Test-ShouldStop），隐藏页不再被 60 秒线误杀 */
setInterval(() => {
  fetch('/api/heartbeat', { method: 'POST', cache: 'no-store',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ hidden: document.hidden === true }) }).catch(() => {});
}, 1000);

/* ---------- 勾选逻辑（勾全面=全部内置树联动勾选并禁用单改） ---------- */
function buildChecks() {
  const grid = $('#check-grid');
  S.meta.trees.forEach((tr) => {
    const isExt = !!tr.ext;   // v1.1.0：ext 扩展树不属于「全面体检」（engine all=内置树全集），默认不勾、联动不带上
    const label = document.createElement('label');
    label.className = 'check-item tree-item' + (isExt ? ' ext-item' : '');
    label.dataset.tree = tr.id;
    label.title = treeTip(tr) + (isExt ? ' ' + t('chrome.ext_tree_tip') : '');
    label.innerHTML = '<input type="checkbox" class="chk-tree"' + (isExt ? '' : ' checked') + '>' +
      '<span class="box"></span>' +
      '<span class="txt"><b>' + esc(treeName(tr)) + '（' + esc(treeDesc(tr)) + '）</b></span>';
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
  // v1.1.0：all=内置树全集全勾且 ext 树没勾；v1.6.1：2-5 棵内置树组合放行（逗号串），ext 树仍只单独选跑
  const builtinTotal = $$('.tree-item:not(.ext-item)').length;
  const builtinChecked = $$('.tree-item:not(.ext-item) input:checked').length;
  const extChecked = $$('.tree-item.ext-item input:checked').length;
  if (builtinChecked === builtinTotal && extChecked === 0) return 'all';
  const picked = $$('.tree-item input').filter((i) => i.checked).map((i) => i.closest('.tree-item').dataset.tree);
  if (picked.length === 1) return picked[0];
  if (picked.length === 0) return 'none';
  const hasExt = picked.some((id) => { const el = document.querySelector('.tree-item[data-tree="' + id + '"]'); return el && el.classList.contains('ext-item'); });
  if (hasExt) return 'invalid-mixed';
  return picked.join(',');
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
    if (sel === 'invalid-mixed') {
      btn.disabled = true;
      hint.textContent = t('chrome.sel_invalid');
      hint.className = 'hint warn';
      setStatus(t('chrome.sel_invalid_status'), '');
    } else if (sel === 'none') {
      btn.disabled = true;
      hint.textContent = t('chrome.sel_none');
      hint.className = 'hint warn';
      setStatus(t('chrome.sel_none_status'), '');
    } else if (sel.indexOf(',') >= 0) {
      btn.disabled = false;
      const ids = sel.split(',');
      const total = ids.reduce((n, id) => {
        const tr = S.meta.trees.find((x) => x.id === id);
        return n + (tr ? treeCheckCount(tr) : 0);
      }, 0);
      hint.textContent = tf('chrome.hint_multi', { n: ids.length, m: total });
      hint.className = 'hint';
      setStatus(t('chrome.status_ready'), '');
    } else {
      btn.disabled = false;
      const tree = sel === 'all' ? null : S.meta.trees.find((x) => x.id === sel);
      const n = tree ? treeCheckCount(tree) : 0;
      hint.textContent = tree
        ? tf('chrome.hint_tree', { name: treeName(tree), n })
        : t('chrome.hint_all');
      hint.className = 'hint';
      setStatus(t('chrome.status_ready'), '');
    }
    btn.textContent = t('chrome.run');
  } else {
    btn.disabled = false;
    btn.textContent = t('chrome.run_again');
    hint.textContent = t('chrome.hint_done');
    hint.className = 'hint';
  }
}
/* 解锁勾选表单（跑完/取消/出错后调用；锁只在跑动场景加，结束后必须还）。
   注意「勾全面→禁单改」联动是另一码事：全选勾着时单树项仍要锁回去（与 resetToIdle 同款语义）。 */
function unlockSelection() {
  $('#select-card').classList.remove('disabled');
  $$('#select-card input').forEach((i) => (i.disabled = false));
  const all = $('#chk-all');
  if (all.checked) $$('.tree-item').forEach((it) => { it.querySelector('input').disabled = true; it.classList.add('disabled'); });
  updateSelUi();
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
  if (!opts.tree && (sel === 'none' || sel === 'invalid-mixed')) return;
  const treeArg = opts.tree || sel;
  S.fast = opts.fast !== undefined ? !!opts.fast : $('#chk-fast').checked;
  S.expectSeq = [];
  const treeSet = treeArg === 'all' ? null : new Set(String(treeArg).split(','));
  S.meta.trees.forEach((t) => {
    if (treeSet && !treeSet.has(t.id)) return;
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
    if (!j.ok) { S.appState = 'idle'; setStatus(j.error || t('chrome.start_fail'), 'err'); updateSelUi(); return; }
  } catch (e) {
    S.appState = 'idle';
    setStatus(t('chrome.conn_lost'), 'err');
    updateSelUi();
    return;
  }
  enterRunningUi(treeArg);
  S.runStartAt = Date.now();
  startPolling();
  startElapsed();
}

function enterRunningUi(treeArg) {
  const defs = treeArg === 'all' ? [] : String(treeArg).split(',').map((id) => S.meta.trees.find((x) => x.id === id)).filter(Boolean);
  const name = treeArg === 'all'
    ? t('chrome.all_name').replace(/（.*/, '')
    : (defs.length > 1 ? defs.map((d) => treeName(d)).join('+') : (defs.length === 1 ? treeName(defs[0]) : treeArg));
  $('#log-box').innerHTML = '';
  $('#progress-fill').style.width = '0%';
  $('#pct-label').textContent = tf('chrome.pct_items', { a: 0, b: S.expectSeq.length });
  $('#run-card').classList.remove('hidden');
  $('#run-card').closest('.view').classList.add('running');
  setTimeout(() => { $('#run-card').scrollIntoView({ behavior: 'auto', block: 'nearest' }); }, 60);
  $('#select-card').classList.add('disabled');
  $$('#select-card input').forEach((i) => (i.disabled = true));
  const btn = $('#btn-run');
  btn.textContent = t('chrome.cancel');
  btn.disabled = false;
  btn.classList.add('running');
  addLog(tf('chrome.log_start', { name }), 'st-dim');
  if (S.expectSeq.length > 0) setNextCurrent(0);
  setStatus(tf('chrome.running_status', { n: S.expectSeq.length }), '', 'run');
  switchView('wizard');
}

function setNextCurrent(pos) {
  if (pos >= S.expectSeq.length) return;
  const nx = S.expectSeq[pos];
  const tr = S.meta.trees.find((x) => x.id === nx.tree);
  const layerIdx = tr.layers.findIndex((l) => l.name === nx.layer) + 1;
  setCurrent(tf('chrome.cur_checking', { title: layerTitle(nx.tree, nx), n: layerIdx, total: tr.layers.length }));
}

async function cancelRun() {
  try { await fetch('/api/cancel', { method: 'POST', cache: 'no-store' }); } catch (e) {}
  setStatus(t('chrome.stopping'), '', 'run');
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
      setStatus(t('chrome.conn_lost'), 'err');
      setCurrent(t('chrome.conn_lost'));
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
  if (remainMs < 10 * 1000) return t('chrome.eta_soon'); // 剩余<10秒才退模糊文案；门槛过大会让短任务全程只见「快好了」（终验实锤）
  const min = Math.floor(remainMs / 60000), sec = Math.round((remainMs % 60000) / 1000);
  return tf('chrome.eta_time', { t: tf('chrome.min_sec', { m: min, s: sec }) });
}

function handleEvent(ev) {
  if (ev.event === 'check') {
    const sec = ev.ms ? tf('chrome.sec_unit', { n: (ev.ms / 1000).toFixed(1) }) : '';
    addLog(statusWord(ev.status) + '  ' + humanCheck(ev.check) + ' · ' + sec, stClass(ev.status));
    S.seqPos++;
    const pct = S.expectSeq.length ? Math.round((S.seqPos / S.expectSeq.length) * 100) : 0;
    $('#progress-fill').style.width = pct + '%';
    $('#pct-label').textContent = tf('chrome.pct_items', { a: S.seqPos, b: S.expectSeq.length }) + etaText();
    setTitleProgress(pct);
    setNextCurrent(S.seqPos);
  } else if (ev.event === 'break') {
    addLog(tf('chrome.log_break', { title: layerTitle(ev.tree, ev) }), 'st-fail');
    if (S.fast && S.seqPos < S.expectSeq.length) {
      for (let i = S.seqPos; i < S.expectSeq.length; i++) {
        const nx = S.expectSeq[i];
        if (nx.tree !== ev.tree) continue;
        if (nx.layer === ev.layer) continue;
        addLog(tf('chrome.log_fast_skip', { name: humanCheck(nx.check) }), 'st-skip');
        S.seqPos++;
      }
      const pct = S.expectSeq.length ? Math.round((S.seqPos / S.expectSeq.length) * 100) : 0;
      $('#progress-fill').style.width = pct + '%';
      $('#pct-label').textContent = tf('chrome.pct_items', { a: S.seqPos, b: S.expectSeq.length }) + etaText();
      setTitleProgress(pct);
    }
  } else if (ev.event === 'tree_done') {
    const tr = S.meta.trees.find((x) => x.id === ev.tree);
    const name = tr ? treeName(tr) : ev.tree;
    addLog(tf('chrome.log_done_tree', { name, verdict: ev.status === 'FAIL' ? t('chrome.short_fail') : t('chrome.exit_ok') }), 'st-dim');
  }
}
function stClass(st) { return st === 'PASS' ? 'st-pass' : st === 'FAIL' ? 'st-fail' : 'st-skip'; }

function recoverRunning(payload) {
  S.appState = 'running'; setTitleProgress(0);
  S.lastSeq = 0;
  $('#log-box').innerHTML = '';
  addLog(t('chrome.resumed_log'), 'st-dim');
  (payload.events || []).forEach((ev) => handleEvent(ev));
  S.lastSeq = payload.lastSeq;
  S.runStartAt = Date.now() - (payload.elapsedSec || 0) * 1000;
  S.fast = payload.runFull === false;
  const btn = $('#btn-run');
  btn.textContent = t('chrome.cancel'); btn.disabled = false; btn.classList.add('running');
  $('#select-card').classList.add('disabled');
  $$('#select-card input').forEach((i) => (i.disabled = true));
  $('#run-card').classList.remove('hidden');
  $('#pct-label').textContent = tf('chrome.pct_items', { a: S.seqPos, b: S.expectSeq.length });
  startElapsed();
  setStatus(t('chrome.running_status_resumed'), '', 'run');
}

function finalize(payload) {
  document.title = t('chrome.title_done');
  setTimeout(() => { if (S.appState !== 'running') setTitleProgress(null); }, 2500);
  stopPolling(); stopElapsed();
  S.appState = payload.state;
  const secHuman = Math.max(1, Math.round((Date.now() - S.runStartAt) / 1000)) || (payload.elapsedSec || 0);
  $('#view-wizard').classList.remove('running');
  if (payload.state === 'done') {
    S.htmlUrl = payload.htmlUrl || '';
    addLog(tf('chrome.log_finish', { n: secHuman, verdict: payload.exit === 0 ? t('chrome.exit_ok') : t('chrome.short_fail') }),
      payload.exit === 0 ? 'st-pass' : 'st-fail');
    $('#progress-fill').style.width = '100%';
    setCurrent(t('chrome.finish_cur'));
    setStatus(tf('chrome.finish_status', { n: secHuman, verdict: exitHuman(payload.exit) }), payload.exit === 0 ? '' : 'err');
    loadReport().then(() => {
      switchView('results');
      unlockSelection();
      saveLastRun(secHuman);
    });
  } else if (payload.state === 'cancelled') {
    addLog(t('chrome.cancelled_log'), 'st-skip');
    setCurrent(t('chrome.cancelled_cur'));
    setStatus(tf('chrome.cancelled_status', { n: secHuman }), '');
    unlockSelection();
  } else {
    addLog(tf('chrome.error_log', { n: payload.exit }), 'st-fail');
    setCurrent(t('chrome.error_cur'));
    setStatus(tf('chrome.error_status', { n: payload.exit }), 'err');
    unlockSelection();
  }
}

/* ---------- 用时（状态栏右侧） ---------- */
function startElapsed() {
  stopElapsed();
  S.elapsedTimer = setInterval(() => {
    const s = Math.floor((Date.now() - S.runStartAt) / 1000);
    const mm = String(Math.floor(s / 60)).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    $('#status-right').innerHTML = '<span class="ver-chip">' + esc(tf('chrome.ver_chip', { v: APP_VERSION })) + '</span><span class="run-time">' + esc(tf('chrome.run_time', { t: mm + ':' + ss })) + '</span>';
  }, 1000);
}
function stopElapsed() {
  if (S.elapsedTimer) { clearInterval(S.elapsedTimer); S.elapsedTimer = null; }
  $('#status-right').innerHTML = '<span class="ver-chip">' + esc(tf('chrome.ver_chip', { v: APP_VERSION })) + '</span>';
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
            name: c.name, status: c.status, evidence: c.evidence || '', suggestion: c.suggestion || '', detail: c.detail || null,
            trees: [t.report_name], checks: [c],
          };
          map.set(c.name, e);
        } else {
          if (e.trees.indexOf(t.report_name) < 0) e.trees.push(t.report_name);
          if (c.status === 'FAIL') e.status = 'FAIL';
          else if (c.status === 'SKIP' && e.status !== 'FAIL') e.status = 'SKIP';
          if (!e.evidence && c.evidence) e.evidence = c.evidence;
          if (!e.suggestion && c.suggestion) e.suggestion = c.suggestion;
          if (!e.detail && c.detail) e.detail = c.detail;
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
  big.textContent = ok ? t('chrome.vb_ok') : tf('chrome.vb_bad', { n: fails.length });
  const sub = document.createElement('div');
  sub.className = 'vb-sub';
  if (ok) {
    sub.textContent = (isAll ? t('chrome.vb_ok_sub_all') : t('chrome.vb_ok_sub_one')) +
      (skips.length ? tf('chrome.vb_ok_skips', { n: skips.length }) : t('chrome.vb_ok_clean'));
  } else {
    sub.textContent = t('chrome.vb_bad_sub') +
      (skips.length ? tf('chrome.vb_bad_skips', { n: skips.length }) : '');
  }
  vb.appendChild(big);
  vb.appendChild(sub);

  const stats = document.createElement('div');
  stats.className = 'vb-stats';
  [['high', t('chrome.sev_high')], ['medium', t('chrome.sev_medium')], ['low', t('chrome.sev_low')]].forEach(([k, word]) => {
    if (!cnt[k]) return;
    const sp = document.createElement('span');
    sp.className = 'vb-sev ' + k;
    sp.textContent = word + ' ' + cnt[k];
    stats.appendChild(sp);
  });
  if (!fails.length) {
    const sp = document.createElement('span');
    sp.className = 'vb-sev';
    sp.textContent = tf('chrome.vb_skipped_n', { n: skips.length });
    stats.appendChild(sp);
  }
  vb.appendChild(stats);

  const btn = document.createElement('button');
  btn.className = 'btn-primary vb-btn';
  btn.textContent = ok ? t('chrome.vb_btn_all') : t('chrome.vb_btn_fix');
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
  const firstName = (j.trees[0] || {}).report_name || t('chrome.report_fallback');
  const rootText = isAll ? tf('chrome.root_name_all', { time }) : tf('chrome.root_name_one', { name: repNameDisplay(firstName), time });

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
    if (bl) breakTitle = layerTitle(t.tree, bl);
  }
  sum.appendChild(document.createTextNode(repNameDisplay(t.report_name)));
  sec.appendChild(sum);
  sec.__data = { type: 'tree', data: t, breakTitle: breakTitle };
  sum.addEventListener('click', (e) => { e.stopPropagation(); selectNode(sec); });

  const kids = document.createElement('div');
  kids.className = 'node-children';
  (t.layers || []).forEach((l, i) => kids.appendChild(buildLayerNode(t, l, i)));
  sec.appendChild(kids);
  return sec;
}

function buildLayerNode(tr, l, idx) {
  const det = document.createElement('details');
  const sum = document.createElement('summary');
  let mark, mcls;
  if (l.state === 'BREAK') { mark = t('chrome.layer_mark_break'); mcls = 'fail'; }
  else if ((l.state || '').indexOf('SKIPPED') === 0) { mark = t('chrome.layer_mark_skip'); mcls = 'skip'; }
  else { mark = '✓'; mcls = 'pass'; }
  const num = idx < LAYER_NUM.length ? LAYER_NUM[idx] : (idx + 1);
  const tSpan = document.createElement('span');
  tSpan.className = 't';
  tSpan.textContent = num + ' ' + layerTitle(tr.tree, l);
  const markSpan = document.createElement('span');
  markSpan.className = 'mark ' + mcls;
  markSpan.textContent = mark;
  sum.appendChild(tSpan);
  sum.appendChild(markSpan);
  det.appendChild(sum);
  det.__data = { type: 'layer', data: l, treeName: tr.report_name, treeId: tr.tree };
  sum.addEventListener('click', (e) => { e.stopPropagation(); selectNode(det); });

  const kids = document.createElement('div');
  kids.className = 'node-children';
  (l.checks || []).forEach((c) => {
    const leaf = document.createElement('div');
    leaf.className = 'leaf';
    leaf.style.color = c.status === 'PASS' ? 'var(--pass)' : c.status === 'FAIL' ? 'var(--fail)' : 'var(--skip)';
    leaf.title = c.name;
    leaf.appendChild(document.createTextNode(statusWord(c.status) + '  ' + humanCheck(c.name)));
    leaf.__data = { type: 'check', data: c, treeName: tr.report_name };
    leaf.addEventListener('click', () => {
      renderCheckDetail({ name: c.name, status: c.status, evidence: c.evidence || '', suggestion: c.suggestion || '', detail: c.detail || null, trees: [tr.report_name] });
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
    card.innerHTML = '<div class="pc-head"><span class="sev-badge low">✓</span><b>' + esc(t('chrome.pl_none_title')) + '</b></div>' +
      '<div class="pc-note">' + esc(skips.length ? tf('chrome.pl_none_skips', { n: skips.length }) : t('chrome.pl_none_clean')) + '</div>';
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
    title.textContent = groupTitle(g.id);
    const count = document.createElement('span');
    count.className = 'pc-count';
    count.textContent = tf('chrome.pl_count', { n: items.length });
    head.appendChild(badge); head.appendChild(title); head.appendChild(count);
    card.appendChild(head);
    const gnote = groupNote(g.id);
    if (gnote) {
      const note = document.createElement('div');
      note.className = 'pc-note';
      note.textContent = gnote;
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
      const trEl = document.createElement('span');
      trEl.className = 'pc-tree';
      trEl.textContent = e.trees.map((x) => repNameDisplay(x)).join(' / ');
      btn.appendChild(st); btn.appendChild(nm); btn.appendChild(trEl);
      btn.addEventListener('click', () => renderCheckDetail(e));
      list.appendChild(btn);
    });
    card.appendChild(list);
    const foot = document.createElement('div');
    foot.className = 'pc-foot';
    const go = document.createElement('button');
    go.className = 'btn';
    go.textContent = t('chrome.pl_go_fix');
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
    title.textContent = t('chrome.pl_skip_title');
    const count = document.createElement('span');
    count.className = 'pc-count';
    count.textContent = tf('chrome.pl_count', { n: skips.length });
    head.appendChild(badge); head.appendChild(title); head.appendChild(count);
    card.appendChild(head);
    const note = document.createElement('div');
    note.className = 'pc-note';
    note.textContent = t('chrome.pl_skip_note');
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
      const trEl = document.createElement('span');
      trEl.className = 'pc-tree';
      trEl.textContent = isAdminSkip(e.name, e.evidence) ? t('chrome.pl_need_admin') : skipTag(e.name);
      btn.appendChild(st); btn.appendChild(nm); btn.appendChild(trEl);
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
  copyBtn.textContent = t('chrome.copy_fix');
  sug.classList.remove('hidden');
  goto.hidden = true;
  hint.classList.add('hidden');
  hint.innerHTML = '';

  title.textContent = humanCheck(entry.name) + '  ' + statusWord(st);
  title.style.color = st === 'PASS' ? 'var(--pass)' : st === 'FAIL' ? 'var(--fail)' : 'var(--skip)';

  const info = checkInfo(entry.name);
  const sev = checkSeverity(entry.name);
  if (st === 'FAIL') {
    goto.hidden = false;
    goto.onclick = () => focusRepair([entry.name]);
    hint.innerHTML = '<p><b>' + esc(t('chrome.what_is')) + '</b>' + esc(info || t('chrome.default_info')) + '</p>' +
      '<p><b>' + esc(t('chrome.impact')) + '</b>' + SEV_META[sev].word + ' · ' + SEV_META[sev].desc +
      (entry.trees.length > 1 ? tf('chrome.in_trees', { trees: entry.trees.map((x) => repNameDisplay(x)).join(t('chrome.trees_join')) }) : '') + '</p>';
    hint.classList.remove('hidden');
    if (!entry.suggestion) {
      hint.innerHTML += '<p>' + esc(t('chrome.no_suggestion_warn')) + '</p>';
    }
    label.textContent = t('chrome.how_fix');
    const sugEn = enSuggestion(entry.name, entry.suggestion, entry.detail);
    sug.textContent = sugEn || t('chrome.no_suggestion_box');
    if (sugEn) { S.currentSuggestion = sugEn; copyBtn.disabled = false; }
  } else if (st === 'SKIP') {
    const admin = isAdminSkip(entry.name, entry.evidence);
    const adminNote = adminSkipNote(entry.name);
    hint.innerHTML = '<p><b>' + esc(t('chrome.what_is')) + '</b>' + esc(info || t('chrome.default_info')) + '</p>' +
      '<p><b>' + esc(t('chrome.skip_not_problem')) + '</b>' + esc(t('chrome.skip_not_problem_body')) +
      (admin ? esc(t('chrome.need_admin_note')) : '') + '</p>';
    hint.classList.remove('hidden');
    label.textContent = t('chrome.how_handle');
    sug.textContent = adminNote || enSuggestion(entry.name, entry.suggestion, entry.detail) || t('chrome.skip_default_sug');
  } else {
    hint.innerHTML = '<p><b>' + esc(t('chrome.what_is')) + '</b>' + esc(info || t('chrome.default_info')) + '</p>' +
      '<p>' + esc(t('chrome.pass_ok_line')) + '</p>';
    hint.classList.remove('hidden');
    label.textContent = t('chrome.check_result');
    sug.textContent = t('chrome.pass_ok_line');
  }

  $('#ev-label').textContent = t('chrome.ev_label');
  ev.textContent = entry.evidence || t('chrome.ev_empty');
  fold.open = false;
  S.lastNode = null;
  $$('.pc-item').forEach((b) => b.classList.toggle('active', b.dataset.check === entry.name));
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
  copyBtn.textContent = t('chrome.copy_fix');
  sug.classList.add('hidden');
  sug.textContent = '';
  hint.classList.add('hidden');
  hint.innerHTML = '';
  goto.hidden = true;
  $$('.pc-item').forEach((b) => b.classList.remove('active'));

  const fold = $('#ev-fold');
  $('#ev-label').textContent = t('chrome.ev_label_layer');
  fold.open = true;
  if (tag.type === 'layer') {
    const l = tag.data;
    title.textContent = layerTitle(tag.treeId, l);
    title.style.color = l.state === 'BREAK' ? 'var(--fail)' : (l.state || '').indexOf('SKIPPED') === 0 ? 'var(--skip)' : 'var(--pass)';
    const stateHuman = l.state === 'BREAK' ? t('chrome.layer_state_break')
      : (l.state === 'PASS' || l.state === 'PASSED-EARLIER') ? t('chrome.layer_state_pass')
      : (l.state || '').indexOf('SKIPPED') === 0 ? t('chrome.layer_state_skipped') : l.state;
    ev.textContent = stateHuman + '\r\n\r\n' + t('chrome.layer_note_prefix') + layerVfail(tag.treeId, l);
    label.textContent = t('chrome.label_note');
  } else if (tag.type === 'tree') {
    const tr = tag.data;
    title.textContent = repNameDisplay(tr.report_name);
    title.style.color = tr.break_layer ? 'var(--fail)' : 'var(--pass)';
    const concl = tr.break_layer ? tf('chrome.tree_concl_fail', { title: tag.breakTitle }) : t('chrome.tree_concl_ok');
    ev.textContent = concl + '\r\n\r\n' + t('chrome.tree_pass_hint') + (tr.verdict_all_pass || '');
    label.textContent = t('chrome.label_note');
  } else if (tag.type === 'root') {
    title.textContent = tag.title;
    title.style.color = tag.exitCode === 0 ? 'var(--pass)' : 'var(--fail)';
    ev.textContent = tf('chrome.root_concl', { v: exitHuman(tag.exitCode) }) + '\r\n' + tf('chrome.root_time', { t: tag.time }) + '\r\n\r\n' + t('chrome.root_html_hint');
    label.textContent = t('chrome.label_note');
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
  $('#pct-label').textContent = tf('chrome.pct_items', { a: 0, b: 0 });
  $('#run-card').classList.add('hidden');
  $('#select-card').classList.remove('disabled');
  $$('#select-card input').forEach((i) => { i.disabled = false; });
  const all = $('#chk-all');
  if (all.checked) $$('.tree-item').forEach((it) => { it.querySelector('input').disabled = true; it.classList.add('disabled'); });
  const btn = $('#btn-run');
  btn.textContent = t('chrome.run');
  btn.classList.remove('running');
  setCurrent(t('chrome.preparing'));
  setStatus(t('chrome.status_ready'), '');
  updateSelUi();
  updateResultsShell();
}

/* 复制问题清单：把结果一段纯文本复制出去求助（组名+严重度+人话检查名） */
function buildCopyList() {
  const es = S.entries || [];
  const fails = es.filter((e) => e.status === 'FAIL');
  const lines = [];
  if (!fails.length) {
    lines.push(tf('chrome.copy_list_none', { n: es.length }));
  } else {
    PROBLEM_GROUPS.forEach((g) => {
      const items = fails.filter((e) => groupFor(e.name).id === g.id)
        .sort((x, y) => SEV_RANK[checkSeverity(x.name)] - SEV_RANK[checkSeverity(y.name)]);
      if (!items.length) return;
      const sev = checkSeverity(items[0].name);
      lines.push('【' + (sev === 'high' ? t('chrome.sev_high') : sev === 'medium' ? t('chrome.sev_medium') : t('chrome.sev_low')) + '】' + groupTitle(g.id) + '：' +
        items.map((e) => humanCheck(e.name)).join('、'));
    });
    const ungrouped = fails.filter((e) => groupFor(e.name).id === 'other');
    ungrouped.forEach((e) => lines.push(t('chrome.copy_list_other') + humanCheck(e.name)));
  }
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const dt = d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  return tf('chrome.copy_list_title', { dt, n: es.length, extra: fails.length ? tf('chrome.copy_list_fails', { n: fails.length }) : '' }) +
    '\n\n' + lines.join('\n') + '\n\n' + t('chrome.copy_list_foot');
}
$('#btn-copylist').addEventListener('click', () => {
  doCopy(buildCopyList(), $('#btn-copylist'), t('chrome.copy_list'));
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
    btn.textContent = t('chrome.copied');
    setTimeout(() => { btn.textContent = resetLabel; }, 1200);
  } else {
    showCopyFallback(text);
    btn.textContent = resetLabel;
  }
}
$('#btn-copy').addEventListener('click', () => {
  if (!S.currentSuggestion) return;
  doCopy(S.currentSuggestion, $('#btn-copy'), t('chrome.copy_fix'));
});

/* ---------- 修复中心 ---------- */
const LV_META = {
  green: { get word() { return t('chrome.lv_green'); }, cls: 'green' },
  yellow: { get word() { return t('chrome.lv_yellow'); }, cls: 'yellow' },
  red: { get word() { return t('chrome.lv_red'); }, cls: 'red' },
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
/* launcher 组（v1.4.0）：「一键直达系统窗口」绿级零修改动作——只拉起系统窗口并指路，
   不改任何设置；单列一节常驻（不依赖体检结果），给红卡手动步骤配套「在哪」这一步减负。
   文案口径（1025 用户吐槽「帮你打开设备管理器都说安全可修」→业界调研定稿）：按钮=动词本身
   「打开」（微软 WAC/Win32 文案指南：按钮名=用户动作的动词）、开窗类零安全声明零撤销说明
   （微软 support/CCleaner/Geek/微软电脑管家等开窗文案均无「安全/可撤销」字样）、说明只留一句
   （微软指南「能一句说清就不写补充段」）、中文业界惯用词「一键直达」（微软电脑管家/360/联想）。 */
function appendLauncherFold(box, launchers) {
  if (!launchers.length) return;
  const sec = document.createElement('div');
  sec.className = 'rep-sec';
  sec.textContent = t('chrome.launcher_sec');
  box.appendChild(sec);
  const note = document.createElement('div');
  note.className = 'rep-sec-note';
  note.textContent = t('chrome.launcher_note');
  box.appendChild(note);
  const wrap = document.createElement('div');
  wrap.className = 'launcher-grid';
  launchers.forEach((a) => wrap.appendChild(buildLauncherCard(a)));
  box.appendChild(wrap);
}
/* launcher 专用精简卡：窗口名+一句用途+「打开」按钮+官方文档链接——不渲染等级徽章/
   三行说明/步骤折叠（业界惯例：开窗类辅助动作不配安全声明；等级语义属修复动作） */
function buildLauncherCard(a) {
  const card = document.createElement('div');
  card.className = 'action-card lv-green launcher-card';
  card.dataset.actionId = a.id;
  const badge = document.createElement('div');
  badge.className = 'ac-badge';
  badge.innerHTML = '<b>' + esc(actField(a, 'name')) + '</b>';
  card.appendChild(badge);
  const desc = actField(a, 'desc');
  if (desc) {
    const d = document.createElement('div');
    d.className = 'lc-desc';
    d.textContent = desc;
    card.appendChild(d);
  }
  if (a.sources && a.sources.length) {
    const src = document.createElement('div');
    src.className = 'lc-src';
    const link = document.createElement('a');
    link.href = a.sources[0].url;
    link.target = '_blank';
    link.rel = 'noopener';
    link.textContent = t('chrome.doc_link');
    src.appendChild(link);
    card.appendChild(src);
  }
  const btnRow = document.createElement('div');
  btnRow.className = 'ac-btns';
  const btn = document.createElement('button');
  btn.className = 'btn act-run';
  btn.dataset.actionId = a.id;
  btn.textContent = t('chrome.launcher_open');
  btn.addEventListener('click', () => onGreenRun(a, btn, card, true));
  btnRow.appendChild(btn);
  card.appendChild(btnRow);
  if (S.repairDoneIds[a.id]) {
    const done = document.createElement('div');
    done.className = 'ac-result';
    renderRepairResult(done, S.repairDoneIds[a.id], true);
    card.appendChild(done);
  }
  return card;
}
function buildRepairList() {
  const box = $('#repair-list');
  if (!box) return;
  const commons = (S.repairActions || []).filter((a) => a.common && !a.launcher);
  const launchers = (S.repairActions || []).filter((a) => a.launcher);
  const appendCommonsFold = () => {
    if (!commons.length) return;
    const fold = document.createElement('details');
    fold.className = 'common-fold';
    const sum = document.createElement('summary');
    sum.textContent = t('chrome.commons_title');
    fold.appendChild(sum);
    const note = document.createElement('div');
    note.className = 'rep-sec-note';
    note.textContent = t('chrome.commons_note');
    fold.appendChild(note);
    commons.forEach((a) => fold.appendChild(buildActionCard(a, [])));
    box.appendChild(fold);
  };

  // 没报告：launcher 帮开窗 + 常用修复折叠（都不依赖体检结果），不冒充「查出来的问题」
  if (!S.reportPayload) {
    box.innerHTML = '';
    const c0 = $('#ri-count'); if (c0) c0.textContent = '';
    const ph = document.createElement('div');
    ph.className = 'placeholder';
    ph.textContent = commons.length
      ? t('chrome.rp_no_report_commons')
      : t('chrome.rp_no_report');
    box.appendChild(ph);
    appendLauncherFold(box, launchers);
    appendCommonsFold();
    return;
  }

  // 跨树同名 FAIL 只算一次；保留第一次出现的报告名与建议
  const failMap = new Map();
  (S.reportPayload.report.trees || []).forEach((t) => {
    (t.layers || []).forEach((l) => {
      (l.checks || []).forEach((c) => {
        if (c.status !== 'FAIL' || !c.suggestion) return;
        if (!failMap.has(c.name)) failMap.set(c.name, { tree: t.report_name, check: c.name, sug: enSuggestion(c.name, c.suggestion, c.detail) });
      });
    });
  });
  const fails = [...failMap.values()]
    .sort((a, b) => SEV_RANK[checkSeverity(a.check)] - SEV_RANK[checkSeverity(b.check)]);
  box.innerHTML = '';
  const cnt = $('#ri-count');
  if (cnt) cnt.textContent = fails.length ? tf('chrome.rp_count', { n: fails.length }) : '';

  if (fails.length === 0) {
    const ph = document.createElement('div');
    ph.className = 'placeholder';
    ph.textContent = t('chrome.rp_none');
    box.appendChild(ph);
    appendLauncherFold(box, launchers);
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
    sec(t('chrome.sec_runnable'));
    runnable.forEach(({ a, hits }) => box.appendChild(buildActionCard(a, hits)));
  }
  if (reds.length) {
    sec(t('chrome.sec_red'));
    reds.forEach(({ a, hits }) => box.appendChild(buildActionCard(a, hits)));
  }
  if (rest.length) {
    sec(t('chrome.sec_manual'));
    rest.forEach((f) => {
      const item = document.createElement('div');
      item.className = 'repair-item sev-' + SEV_META[checkSeverity(f.check)].cls;
      item.dataset.check = f.check;
      const head = document.createElement('div');
      head.className = 'ri-head';
      const ti = document.createElement('div');
      ti.className = 'ri-title';
      ti.textContent = '【' + repNameDisplay(f.tree) + '】' + humanCheck(f.check);
      const sevb = document.createElement('span');
      sevb.className = 'sev-badge ' + SEV_META[checkSeverity(f.check)].cls;
      sevb.textContent = SEV_META[checkSeverity(f.check)].word;
      const cp = document.createElement('button');
      cp.className = 'btn';
      cp.textContent = t('chrome.copy_fix');
      cp.addEventListener('click', () => { doCopy(f.sug, cp, t('chrome.copy_fix')); });
      head.appendChild(ti); head.appendChild(sevb); head.appendChild(cp);
      item.appendChild(head);
      const fold = document.createElement('details');
      fold.className = 'steps-fold';
      const foldSum = document.createElement('summary');
      foldSum.textContent = t('chrome.ri_fold');
      fold.appendChild(foldSum);
      const pre = document.createElement('pre');
      pre.textContent = f.sug;
      fold.appendChild(pre);
      item.appendChild(fold);
      box.appendChild(item);
    });
  }
  appendLauncherFold(box, launchers);
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
  badge.innerHTML = '<b>' + esc(actField(a, 'name')) + '</b><span class="lv-tag ' + bm.cls + '">' + esc(bm.word) + '</span>';
  card.appendChild(badge);

  const caveat = actField(a, 'caveat');
  if (caveat) {
    const cv = document.createElement('div');
    cv.className = 'ac-caveat';
    cv.textContent = t('chrome.ac_caveat') + caveat;
    card.appendChild(cv);
  }

  if (hits && hits.length) {
    const seen = new Set();
    const names = hits.map((f) => humanCheck(f.check)).filter((n) => (seen.has(n) ? false : (seen.add(n), true)));
    const row = document.createElement('div');
    row.className = 'ac-row';
    row.innerHTML = '<span class="ac-key">' + esc(t('chrome.ac_fixes')) + '</span><span class="ac-val">' + esc(names.join(t('chrome.trees_join'))) +
      (hits.length > names.length ? tf('chrome.ac_hits', { n: hits.length }) : '') + '</span>';
    card.appendChild(row);
  }

  const rows = [[t('chrome.ac_what'), actField(a, 'desc')], [t('chrome.ac_affect'), actField(a, 'affect')], [t('chrome.ac_undo'), actField(a, 'undo')]];
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

  /* 权威溯源：动作卡展示官方依据链接——修复方法可溯源，禁「信我」式黑箱 */
  if (a.sources && a.sources.length) {
    const row = document.createElement('div');
    row.className = 'ac-row src-row';
    const kEl = document.createElement('span');
    kEl.className = 'ac-key';
    kEl.textContent = t('chrome.ac_official');
    const vEl = document.createElement('span');
    vEl.className = 'ac-val';
    a.sources.forEach((s, i) => {
      if (i) vEl.appendChild(document.createElement('br'));
      const link = document.createElement('a');
      link.href = s.url;
      link.target = '_blank';
      link.rel = 'noopener';
      link.textContent = actSource(a, s, i);
      vEl.appendChild(link);
    });
    row.appendChild(kEl); row.appendChild(vEl);
    card.appendChild(row);
  }

  const fold = document.createElement('details');
  fold.className = 'steps-fold';
  const foldSum = document.createElement('summary');
  foldSum.textContent = t('chrome.ac_steps_fold');
  fold.appendChild(foldSum);
  const steps = document.createElement('div');
  steps.className = 'ac-steps';
  actSteps(a).forEach((st) => {
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
    btn.textContent = a.requires_admin ? t('chrome.btn_run_green_admin') : t('chrome.btn_run_green');
    btn.addEventListener('click', () => onGreenRun(a, btn, card));
  } else if (a.level === 'yellow') {
    btn.textContent = t('chrome.btn_run_yellow');
    btn.addEventListener('click', () => showYellowConfirm(a, btn, card));
  } else {
    btn.textContent = t('chrome.btn_red_guide');
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
function onGreenRun(a, btn, card, launcherMode) {
  if (S.repairBusy || S.appState === 'running') {
    setStatus(S.appState === 'running' ? t('chrome.repair_busy_check') : t('chrome.repair_busy'), 'err');
    return;
  }
  if (a.requires_admin) showGreenConfirmModal(a, () => startRepairRun(a, btn, card));
  else startRepairRun(a, btn, card, launcherMode ? { okWord: t('chrome.launcher_opened') } : undefined);
}
function showGreenConfirmModal(a, onGo) {
  document.getElementById('rm-title').textContent = actField(a, 'name') || t('chrome.rm_title');
  const sub = document.getElementById('rm-sub');
  sub.textContent = t('chrome.green_confirm_body');
  fillModalRows(a);
  const go = document.getElementById('rm-go');
  go.textContent = t('chrome.rm_go');
  go.disabled = false;
  go.onclick = () => { hideRepairModal(); onGo(); };
  document.getElementById('rm-cancel').onclick = hideRepairModal;
  document.getElementById('repair-modal').classList.remove('hidden');
}
/* 黄级逐项确认：三行都打勾才点亮「确认执行」；可选系统还原点（建不出来自动中止） */
function showYellowConfirm(a, btn, card) {
  document.getElementById('rm-title').textContent = actField(a, 'name') || t('chrome.rm_title');
  const sub = document.getElementById('rm-sub');
  sub.textContent = t('chrome.yellow_confirm_body');
  const rows = document.getElementById('rm-rows');
  rows.innerHTML = '';
  const checks = [];
  [[t('chrome.yellow_what'), actField(a, 'desc')], [t('chrome.ac_affect'), actField(a, 'affect')], [t('chrome.ac_undo'), actField(a, 'undo') || actField(a, 'rollback_note')]].forEach(([k, v]) => {
    const lab = document.createElement('label');
    lab.className = 'rm-line';
    const ck = document.createElement('input');
    ck.type = 'checkbox';
    ck.className = 'rm-ck';
    const sp = document.createElement('span');
    sp.innerHTML = '<b>' + esc(k) + '：</b>' + esc(v || '');
    lab.appendChild(ck); lab.appendChild(sp);
    rows.appendChild(lab);
    ck.addEventListener('change', updGo);
    checks.push(ck);
  });
  const steps = document.createElement('div');
  steps.className = 'ac-steps';
  actSteps(a).forEach((st) => {
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
    sp.textContent = t('chrome.rp_checkbox');
    lab.appendChild(rp); lab.appendChild(sp);
    rows.appendChild(lab);
  }
  const go = document.getElementById('rm-go');
  go.textContent = t('chrome.btn_confirm_run');
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
  [[t('chrome.ac_what'), actField(a, 'desc')], [t('chrome.ac_affect'), actField(a, 'affect')], [t('chrome.ac_undo'), actField(a, 'undo') || actField(a, 'rollback_note')]].forEach(([k, v]) => {
    if (!v) return;
    const row = document.createElement('div');
    row.className = 'ac-row';
    row.innerHTML = '<span class="ac-key">' + esc(k) + '</span><span class="ac-val">' + esc(v) + '</span>';
    rows.appendChild(row);
  });
  const steps = document.createElement('div');
  steps.className = 'ac-steps';
  actSteps(a).forEach((st) => {
    const line = document.createElement('div');
    line.textContent = '· ' + (st.desc || '') + '（' + stepCmdText(st) + '）';
    steps.appendChild(line);
  });
  const rbNote = actField(a, 'rollback_note');
  if (rbNote) {
    const rb = document.createElement('div');
    rb.textContent = t('chrome.rollback_pkg') + rbNote;
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
  btn.textContent = t('chrome.btn_red_armed');
  btn.setAttribute('aria-label', t('chrome.btn_red_armed'));
  setTimeout(() => { if (btn.dataset.armed === '1') { btn.dataset.armed = ''; btn.textContent = old; btn.setAttribute('aria-label', old); } }, 4000);
}
let guideText = '';
/* 分步指南五要素：红卡/指南步可带 how={at,click,type,ok,fail}——
   在哪/点什么/输入什么/算成功/失败了先，一行一要素零废话；渲染与整段复制共用（词条=chrome.bb_*，术语表五要素口径） */
const BB_KEYS = [['at', 'chrome.bb_at'], ['click', 'chrome.bb_click'], ['type', 'chrome.bb_type'], ['ok', 'chrome.bb_ok'], ['fail', 'chrome.bb_fail']];
function howHtml(st) {
  return '<div class="bb-lines">' + BB_KEYS.filter(([k]) => st.how[k]).map(([k, w]) =>
    '<div class="bb-line"><span class="bb-key">' + esc(t(w)) + '</span><span class="bb-val">' + esc(st.how[k]) + '</span></div>').join('') + '</div>';
}
function howText(st) {
  return BB_KEYS.filter(([k]) => st.how[k]).map(([k, w]) => '　' + t(w) + '：' + st.how[k]).join('\n');
}
function guideTextFor(a) {
  const lines = [];
  lines.push(actField(a, 'name') || t('chrome.guide_fallback_name'));
  lines.push(t('chrome.guide_red_line'));
  lines.push('');
  const gDesc = actField(a, 'desc');
  if (gDesc) lines.push(t('chrome.guide_what') + gDesc);
  const gAffect = actField(a, 'affect');
  if (gAffect) lines.push(t('chrome.guide_affect') + gAffect);
  const undo = actField(a, 'undo') || actField(a, 'rollback_note');
  if (undo) lines.push(t('chrome.guide_undo') + undo);
  lines.push('');
  lines.push(t('chrome.guide_steps'));
  actSteps(a).forEach((st, i) => {
    lines.push((i + 1) + '. ' + (st.how ? (st.desc || '') : (st.desc || '') + '（' + stepCmdText(st) + '）'));
    if (st.how) lines.push(howText(st));
  });
  lines.push('');
  lines.push(t('chrome.guide_foot'));
  return lines.join('\n');
}
function showRedGuide(a) {
  a = a || {};
  guideText = guideTextFor(a);
  const gdTitle = document.getElementById('gd-title');
  if (gdTitle) gdTitle.textContent = tf('chrome.guide_title_fmt', { name: actField(a, 'name') || t('chrome.guide_fallback_name') });
  document.getElementById('gd-sub').textContent = (actField(a, 'desc') || '') + t('chrome.gd_sub_suffix');
  const rows = document.getElementById('gd-rows');
  rows.innerHTML = '';
  [[t('chrome.guide_affect'), actField(a, 'affect')], [t('chrome.guide_undo'), actField(a, 'undo') || actField(a, 'rollback_note')]].forEach(([k, v]) => {
    if (!v) return;
    const row = document.createElement('div');
    row.className = 'ac-row';
    row.innerHTML = '<span class="ac-key">' + esc(k) + '</span><span class="ac-val">' + esc(v) + '</span>';
    rows.appendChild(row);
  });
  const steps = document.createElement('div');
  steps.className = 'ac-steps';
  actSteps(a).forEach((st, i) => {
    if (st.how) {
      const line = document.createElement('div');
      line.className = 'bb-step';
      const num = document.createElement('span');
      num.className = 'bb-num';
      num.textContent = String(i + 1);
      const body = document.createElement('div');
      body.className = 'bb-body';
      if (st.desc) {
        const dt = document.createElement('div');
        dt.className = 'bb-title';
        dt.textContent = st.desc;
        body.appendChild(dt);
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
  doCopy(guideText || t('chrome.guide_empty_copy'), btn, t('chrome.gd_copy'));
});

async function startRepairRun(a, btn, card, opts) {
  opts = opts || {};
  S.lastRepairCtx = { a, btn, card };  // 还原点中止等场景「跳过还原点直接修」重试要用
  setRepairBusy(true, btn);
  setStatus(tf('chrome.repairing', { name: actField(a, 'name'), extra: a.level === 'yellow' ? t('chrome.repairing_yellow') : t('chrome.repairing_ellipsis') }), '', 'run');
  let slot = card.querySelector('.ac-result');
  if (!slot) { slot = document.createElement('div'); slot.className = 'ac-result'; card.appendChild(slot); }
  slot.innerHTML = '<div class="rr-big running">' + esc(tf('chrome.rr_running', { name: actField(a, 'name') })) + '</div>' +
    '<div class="rr-sub">' + esc(tf('chrome.rr_todo', { steps: actSteps(a).map((s) => s.desc).join('；') })) + '</div>';
  try {
    const r = await fetch('/api/repair/run', {
      method: 'POST', cache: 'no-store',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: a.id, restore_point: !!opts.restorePoint, skip_restore_point: !!opts.skipRp }),
    });
    const j = await r.json();
    if (!j.ok) { renderRepairResult(slot, { ok: false, human: j.error || t('chrome.start_fail') }); return; }
    for (let i = 0; i < 200; i++) {
      await new Promise((res) => setTimeout(res, 700));
      let st;
      try { st = await (await fetch('/api/repair/status', { cache: 'no-store' })).json(); }
      catch (e) { continue; }
      if (st.state === 'done' && st.result) { S.repairDoneIds[a.id] = st.result; renderRepairResult(slot, st.result, opts.okWord); if (st.result.ok) scheduleSense(a); return; }
      if (st.state === 'idle') { renderRepairResult(slot, { ok: false, human: t('chrome.rr_stale') }); return; }
    }
    renderRepairResult(slot, { ok: false, human: t('chrome.rr_timeout') });
  } catch (e) {
    renderRepairResult(slot, { ok: false, human: t('chrome.conn_lost') });
  } finally {
    setRepairBusy(false, btn);
    setStatus(t('chrome.status_ready'), '');
  }
}
function setRepairBusy(busy, btn) {
  S.repairBusy = busy;
  if (busy) { $$('.act-run').forEach((b) => { b.dataset.origLabel = b.textContent; b.disabled = true; }); if (btn) btn.textContent = t('chrome.repair_busy_btn'); }
  else { $$('.act-run').forEach((b) => { b.disabled = false; if (b.dataset.origLabel) b.textContent = b.dataset.origLabel; }); REPH.stale = true; }
}
/* ---------- 修复小史：最近修过什么、成没成（数据根 repair-log.json 经 server 精简投影） ---------- */
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
    if (h.ok) res = '<span class="rh-ok">' + esc(t('chrome.hist_ok')) + '</span>';
    else if (h.rp === 'failed') res = '<span class="rh-bad">' + esc(t('chrome.hist_rp_fail')) + '</span>';
    else res = '<span class="rh-bad">' + esc(tf('chrome.hist_bad', { stage: h.fail_stage ? tf('chrome.hist_stage', { stage: h.fail_stage }) : '' })) + '</span>';
    return '<div class="rh-row"><span class="rh-time">' + esc(h.time) + '</span><span class="rh-name">' + esc(h.name) + '</span>' +
      (lv ? '<span class="rh-lv lv-' + esc(h.level) + '">' + esc(lv) + '</span>' : '') + res + '</div>';
  }).join('');
  wrap.classList.remove('hidden');
}
/* 修复结果：大结论 + 复查提炼 + 下一步；五段明细折叠，失败默认展开 */
function renderRepairResult(slot, res, okWord) {
  slot.innerHTML = '';
  if (!res || !res.stages) {
    slot.appendChild(rrBig('bad', '✗ ' + ((res && res.human) || t('chrome.rr_no_result_msg'))));
    return;
  }
  const ok = !!res.ok;
  slot.appendChild(rrBig(ok ? 'ok' : 'bad', okWord || ((ok ? t('chrome.rr_ok_word') : t('chrome.rr_bad_word')) + ' · ' + (res.human || ''))));
  const vf = res.stages.verify;
  if (vf && (vf.checks || []).length) {
    vf.checks.forEach((c) => {
      const l = document.createElement('div');
      l.className = 'rr-verify ' + (c.status === 'PASS' ? 'st-pass' : c.status === 'FAIL' ? 'st-fail' : 'st-skip');
      l.textContent = c.status === 'PASS' ? tf('chrome.verify_pass', { name: humanCheck(c.name) })
        : c.status === 'FAIL' ? tf('chrome.verify_fail', { name: humanCheck(c.name) })
        : tf('chrome.verify_skip', { name: humanCheck(c.name) });
      slot.appendChild(l);
    });
  }
  const next = document.createElement('div');
  next.className = 'rr-next' + (ok ? '' : ' bad');
  if (ok) {
    const sp = document.createElement('span');
    sp.textContent = t('chrome.rr_next_ok');
    const btn = document.createElement('button');
    btn.className = 'btn';
    btn.textContent = t('chrome.btn_recheck');
    btn.addEventListener('click', () => switchView('wizard'));
    next.appendChild(sp); next.appendChild(btn);
  } else {
    const sp = document.createElement('span');
    // 还原点没建成的安全中止：给两条出路而不是一句「重试」（1024 用户实锤：看不懂原因也不知道下一步）
    const rpAborted = res.fail_stage === 'rollback_pkg' && res.stages.pkg && res.stages.pkg.restore_point &&
      res.stages.pkg.restore_point.requested && !res.stages.pkg.restore_point.ok;
    if (rpAborted) {
      sp.textContent = t('chrome.rp_disabled');
      const skip = document.createElement('button');
      skip.className = 'btn';
      skip.textContent = t('chrome.btn_skip_rp');
      skip.addEventListener('click', () => {
        const c = S.lastRepairCtx;
        if (c && c.a) startRepairRun(c.a, c.btn, c.card, { skipRp: true });
      });
      next.appendChild(sp); next.appendChild(skip);
      slot.appendChild(next);
      appendRepairDetailFold(slot, res);
      return;
    }
    sp.textContent = t('chrome.rr_retry');
    next.appendChild(sp);
  }
  slot.appendChild(next);

  appendRepairDetailFold(slot, res);
}
/* 修复五段明细折叠（预检/回滚包/执行/复查/记录）——成功默认收起、失败自动展开 */
function appendRepairDetailFold(slot, res) {
  const ok = !!res.ok;
  const fold = document.createElement('details');
  fold.className = 'steps-fold';
  const foldSum = document.createElement('summary');
  foldSum.textContent = t('chrome.detail_fold');
  fold.appendChild(foldSum);
  const body = document.createElement('div');
  const st = res.stages;
  const pre = st.precheck;
  if (pre) {
    const l = document.createElement('div');
    l.className = 'stage-line ' + (pre.ok ? 'st-pass' : 'st-fail');
    l.textContent = pre.ok ? t('chrome.pre_ok') : tf('chrome.pre_fail', { notes: (pre.notes || []).join('；') });
    body.appendChild(l);
  }
  const pkg = st.pkg;
  if (pkg) {
    const rp = pkg.restore_point || {};
    let rpTxt = '';
    if (rp.requested) rpTxt = rp.ok ? t('chrome.rp_ready') : t('chrome.rp_failed');
    const l = document.createElement('div');
    l.className = 'stage-line ' + (pkg.ok ? 'st-pass' : 'st-fail');
    if (pkg.ok) {
      const uf = String(pkg.undo_file || '').split(/[\\/]/).pop();
      l.textContent = tf('chrome.pkg_ok', { file: uf, rp: rpTxt });
    } else {
      l.textContent = tf('chrome.pkg_fail', { note: pkg.note || t('chrome.pkg_none'), rp: rpTxt });
    }
    body.appendChild(l);
  }
  if (st.exec) {
    (st.exec.steps || []).forEach((s) => {
      const l = document.createElement('div');
      l.className = 'stage-line ' + (s.exit === 0 && !s.timed_out ? 'st-pass' : 'st-fail');
      l.textContent = (s.exit === 0 && !s.timed_out ? t('chrome.exec_ok_mark') : t('chrome.exec_fail_mark')) + (s.desc || '') +
        (s.timed_out ? t('chrome.exec_timeout') : (s.exit !== 0 ? tf('chrome.exec_fail', { n: s.exit }) : tf('chrome.exec_ms', { n: ((s.ms || 0) / 1000).toFixed(1) })));
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
      l.textContent = t('chrome.exec_skip_mark') + st.exec.note;
      body.appendChild(l);
    }
  }
  const vf = st.verify;
  if (vf) {
    if ((vf.checks || []).length) {
      (vf.checks || []).forEach((c) => {
        const l = document.createElement('div');
        l.className = 'stage-line ' + (c.status === 'PASS' ? 'st-pass' : c.status === 'FAIL' ? 'st-fail' : 'st-skip');
        l.textContent = (c.status === 'PASS' ? t('chrome.vf_ok_mark') : c.status === 'FAIL' ? t('chrome.vf_fail_mark') : t('chrome.vf_skip_mark')) +
          humanCheck(c.name) + (c.status === 'PASS' ? t('chrome.vf_ok_tail') : c.status === 'FAIL' ? t('chrome.vf_fail_tail') : t('chrome.vf_skip_tail'));
        body.appendChild(l);
      });
    } else if (vf.note) {
      const l = document.createElement('div');
      l.className = 'stage-line st-skip';
      l.textContent = t('chrome.vf_skip_mark') + vf.note;
      body.appendChild(l);
    }
  }
  const lg = st.log;
  if (lg) {
    const l = document.createElement('div');
    l.className = 'stage-line ' + (lg.ok ? 'st-dim' : 'st-fail');
    l.textContent = lg.ok ? t('chrome.log_ok') : tf('chrome.log_fail', { err: lg.err || '' });
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

/* ---------- 外观：明暗 + 强调色 + 背景原画 + 语言（合并为一个菜单） ---------- */
const ACCENTS = { blue: '#4cc2ff', cyan: '#2dd4bf', green: '#3fd68f', violet: '#a78bfa', orange: '#ffb35c', pink: '#ff7b9c' };
function accentName(k) { return t('chrome.accent_' + k); }
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
  let cfg = { t: 'auto', a: 'cyan' }; // 新用户默认跟随系统明暗；老用户已存的 dark/light 手选不动
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
    s.title = accentName(k);
    s.setAttribute('aria-label', tf('chrome.accent_aria', { name: accentName(k) }));
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
  const entries = glossaryEntries();
  Object.keys(entries).forEach((k) => {
    const dt = document.createElement('dt');
    dt.textContent = k;
    const dd = document.createElement('dd');
    dd.textContent = entries[k];
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
    setStatus(t('chrome.conn_lost'), 'err');
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
      const recTreeSet = treeArg === 'all' ? null : new Set(String(treeArg).split(','));
      S.meta.trees.forEach((t) => {
        if (recTreeSet && !recTreeSet.has(t.id)) return;
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
      btn.textContent = t('chrome.cancel'); btn.disabled = false; btn.classList.add('running');
      startPolling(); startElapsed();
      setStatus(t('chrome.running_status_resumed'), '', 'run');
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
      $('#btn-run').textContent = t('chrome.run_again');
      updateSelUi();
      markGuided(); // server 侧已跑完＝跑过一轮体检：首次引导卡同样永久收起（防跑完瞬间刷新回潮）
    }
  } catch (e) {}
  updateResultsShell();
  renderLastRun();
  renderFirstGuide();
})();

/* ---------- 历史对比（报告列表+两次对比+问题数趋势；纯前端展示层，判定零碰） ---------- */
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
/* 和上次比：结果页顶部一行摘要——本次 vs 上一份历史报告；
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
    if (better && worse) txt = tf('chrome.delta_both', { when, b: better, w: worse });
    else if (better) txt = tf('chrome.delta_better', { when, b: better });
    else if (worse) txt = tf('chrome.delta_worse', { when, w: worse });
    else txt = tf('chrome.delta_same', { when });
    el.innerHTML = '<div class="delta-txt">' + esc(txt) + '</div><button class="btn" id="delta-go">' + esc(t('chrome.delta_go')) + '</button>';
    el.classList.remove('hidden');
    $('#delta-go').addEventListener('click', () => switchView('history'));
  } catch (e) { el.classList.add('hidden'); }
}
function histFailCount(map) { return Object.values(map).filter((v) => v.status === 'FAIL').length; }
function histHuman(name) { return humanCheck(name); }

async function loadHistory(force) {
  if (HIST.loaded && !force) return;
  let list = [];
  try {
    const r = await fetch('/api/reports/list', { cache: 'no-store' });
    const j = await r.json();
    list = j.reports || [];
  } catch (e) {
    $('#hist-list').innerHTML = '<div class="placeholder">' + esc(t('chrome.hist_unreadable')) + '</div>';
    return;
  }
  // 逐份拉详情（只取每份的结构化摘要：时间/树/检查状态/FAIL 数）
  const items = [];
  for (const it of list) {
    try {
      const rr = await fetch('/reports/' + encodeURIComponent(it.file), { cache: 'no-store' });
      const rep = await rr.json();
      const map = histCheckMap(rep);
      items.push({ file: it.file, mtime: it.mtime, treeNames: (rep.trees || []).map((x) => x.report_name || x.tree), map, fails: histFailCount(map) });
    } catch (e) { /* 单份坏档跳过，不拖垮整页 */ }
  }
  HIST.reports = items.map((x) => Object.assign({}, x, { trees: x.treeNames ? x.treeNames.map(repNameDisplay).join('+') : '' }));
  HIST.loaded = true;

  const listEl = $('#hist-list');
  if (!items.length) {
    listEl.innerHTML = '<div class="placeholder">' + esc(t('chrome.hist_placeholder')) + '</div>';
    $('#hist-compare-card').hidden = true;
    $('#hist-trend-card').hidden = true;
    return;
  }
  listEl.innerHTML = HIST.reports.map((r) =>
    '<div class="hist-item"><span class="hist-time">' + esc(r.mtime) + '</span>' +
    '<span class="hist-tree">' + esc(r.trees) + '</span>' +
    '<span class="hist-fail ' + (r.fails ? 'bad' : 'ok') + '">' + esc(r.fails === 1 ? t('chrome.hist_fail_1') : tf('chrome.hist_fails', { n: r.fails })) + '</span></div>'
  ).join('');

  // 趋势（时间升序：改善还是恶化一眼可看）
  $('#hist-trend-card').hidden = false;
  const asc = HIST.reports.slice().reverse();
  const maxF = Math.max(1, ...asc.map((r) => r.fails));
  $('#trend-list').innerHTML = asc.map((r) =>
    '<div class="trend-row"><span class="trend-time">' + esc(r.mtime) + '</span>' +
    '<span class="trend-bar"><i class="' + (r.fails ? 'bad' : 'ok') + '" style="width:' + Math.round(r.fails / maxF * 100) + '%"></i></span>' +
    '<span class="trend-val">' + r.fails + '</span></div>'
  ).join('');

  // 对比卡（≥2 份才开）：两个下拉候选都放开到全量历史，任意两份可互比（同选一份走 cmp_same_default 占位）
  if (HIST.reports.length >= 2) {
    $('#hist-compare-card').hidden = false;
    const opt = (sel, arr) => sel.innerHTML = arr.map((r) => '<option value="' + esc(r.file) + '">' + esc(r.fails === 1 ? tf('chrome.opt_line_1', { time: r.mtime, trees: r.trees }) : tf('chrome.opt_line', { time: r.mtime, trees: r.trees, n: r.fails })) + '</option>').join('');
    opt($('#cmp-old'), HIST.reports);
    opt($('#cmp-new'), HIST.reports);
    // 默认选中=最新 vs 次新，与放开前视觉等价（列表按新到旧排序）
    $('#cmp-new').selectedIndex = 0;
    $('#cmp-old').selectedIndex = 1;
  }
}

function buildCmpRows(om, nm) {
  const rows = [];
  let better = 0, worse = 0;
  // 只展示「有信息量」的行：状态变化了、或两次都是 FAIL（还没修好的老问题）
  Object.keys(nm).forEach((name) => {
    const n = nm[name], o = om[name];
    if (!o) { rows.push({ name, tag: t('chrome.cmp_tag_new'), cls: 'worse', txt: tf('chrome.cmp_new_row', { st: n.status }) }); if (n.status === 'FAIL') worse++; return; }
    if (o.status === n.status) {
      if (n.status === 'FAIL') rows.push({ name, tag: t('chrome.cmp_tag_still'), cls: 'still', txt: t('chrome.cmp_still_row') });
      return;
    }
    if (n.status === 'FAIL') { rows.push({ name, tag: t('chrome.cmp_tag_worse'), cls: 'worse', txt: tf('chrome.cmp_to_fail', { st: o.status }) }); worse++; }
    else if (o.status === 'FAIL') { rows.push({ name, tag: t('chrome.cmp_tag_better'), cls: 'better', txt: tf('chrome.cmp_from_fail', { st: n.status }) }); better++; }
    else { rows.push({ name, tag: t('chrome.cmp_tag_change'), cls: 'still', txt: o.status + ' → ' + n.status }); }
  });
  Object.keys(om).forEach((name) => {
    if (!nm[name]) rows.push({ name, tag: t('chrome.cmp_tag_unchecked'), cls: 'still', txt: t('chrome.cmp_unchecked_row') });
  });
  return { rows, better, worse };
}
function buildCmpHtml(om, nm, oldFails, newFails, sameWord) {
  const r = buildCmpRows(om, nm);
  const sum = tf('chrome.cmp_sum_html', { o: oldFails, n: newFails }) +
    '<span class="better">' + esc(tf('chrome.cmp_better', { n: r.better })) + '</span>　<span class="worse">' + esc(tf('chrome.cmp_worse', { n: r.worse })) + '</span>';
  const table = r.rows.length
    ? '<div class="cmp-rows">' + r.rows.map((r2) =>
        '<div class="cmp-row ' + r2.cls + '"><span class="cmp-tag">' + esc(r2.tag) + '</span><span class="cmp-name">' + esc(histHuman(r2.name)) + '</span><span class="cmp-txt">' + esc(r2.txt) + '</span></div>'
      ).join('') + '</div>'
    : '<div class="placeholder">' + esc(sameWord || t('chrome.cmp_same_default')) + '</div>';
  return '<div class="cmp-sum">' + sum + '</div>' + table;
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
  $('#cmp-out').innerHTML = '<div class="placeholder">' + esc(t('chrome.cmp_running')) + '</div>';
  renderCompare(a, b);
});


/* ---------- 修复后感知（修复成功→自动对关联树快扫→修复前后对比+再感知一次；复用历史对比引擎） ---------- */
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
  setStatus(t('chrome.sense_status'), '', 'run');
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
    host.innerHTML = '<div class="card-title">' + esc(t('chrome.sense_title')) + '</div><div class="placeholder">' + esc(t('chrome.sense_empty')) + '</div>';
    appendSenseBtn(host);
    return;
  }
  const om = histCheckMap(repOf(before)), nm = histCheckMap(repOf(after));
  const title = '<div class="card-title">' + esc(t('chrome.sense_title_full')) + '</div>';
  host.innerHTML = title + buildCmpHtml(om, nm, histFailCount(om), histFailCount(nm), t('chrome.sense_same'));
  appendSenseBtn(host);
}
function appendSenseBtn(host) {
  const btn = document.createElement('button');
  btn.className = 'btn';
  btn.style.marginTop = '10px';
  btn.textContent = t('chrome.sense_again');
  btn.onclick = () => {
    if (!S.lastSenseAction) return;
    scheduleSense(S.lastSenseAction);
  };
  host.appendChild(btn);
}

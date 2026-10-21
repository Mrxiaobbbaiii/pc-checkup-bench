'use strict';
/* diag ui v0.9.2 「电脑体检台」—— 纯原生 JS，零构建零 CDN（断网可用）
   文案口径=design 详版第十四节对照表（与 v0.7.1 GUI 逐句对齐）；功能对齐 v0.7.1：
   树勾选（全勾/单勾，勾 2-4 禁用）+进度+日志三态着色+结果树+FAIL 复制+取消+关闭确认（网页内弹层）
   v0.9.2：小白/专家双视图退役（大字态转正唯一档）；原始证据/修复卡命令行改 <details> 折叠；
   检查项挂人话名映射 CHECK_HUMAN（纯显示层，数据与匹配逻辑零改动，leaf 悬停可见英文原名）；
   版本串收敛 APP_VERSION 常量——v0.9 坑③计时器硬编码版本盖静态页脚的根治 */

const APP_VERSION = 'v0.9.2';

const $ = (s) => document.querySelector(s);

const S = {
  meta: null,            // /api/meta：五棵树定义（层/检查项/文案）
  expectSeq: [],         // 本轮预期检查序列 [{tree, layer, layerTitle, check}]
  seqPos: 0,
  fast: false,
  appState: 'idle',      // idle | running | done | cancelled | error
  lastSeq: 0,
  htmlUrl: '',
  reportPayload: null,   // /api/report 缓存（结果树+修复中心共用）
  currentSuggestion: '',
  runStartAt: 0,
  pollTimer: null,
  elapsedTimer: null,
  beatFail: 0,
  repairActions: null,   // v0.8.1 /api/repair/list 缓存（null=还没拿到）
  repairBusy: false,     // 本地镜像：修复进行中（禁其他修复/按钮态）
  repairDoneIds: {},     // 已执行过的动作 id → 结果（防重复渲染）
  lastNode: null,        // 结果树最后选中节点
};

const STATUS_WORD = { PASS: '✓ 正常', FAIL: '✗ 有问题', SKIP: '– 没查成' };
const LAYER_NUM = ['①', '②', '③', '④', '⑤', '⑥'];

/* 检查项人话名映射（v0.9.2 纯显示层：界面不出现英文裸名；未收录项原样显示 id）
   数据源与修复匹配逻辑仍用英文原名，零改动 */
const CHECK_HUMAN = {
  net_adapter_list: '网卡与连线', net_ip_dhcp: 'IP 地址获取', net_gateway_conflict: '网关配置冲突',
  net_gateway_ping: '网关连通', net_public_ping: '公网连通', net_dns_deadaddr: 'DNS 死地址',
  net_dns_default: '默认 DNS 配置', net_dns_gateway_proxy: 'DNS 网关代理', net_dns_public: '公共 DNS 解析',
  bs_event_history: '蓝屏记录（近 90 天）', bs_powerloss_distinction: '断电与蓝屏区分', bs_code_frequency: '蓝屏码频次',
  bs_whea_hardware: '硬件报错记录', bs_minidump_inventory: '转储文件盘点', bs_suspect_drivers: '嫌疑驱动名单',
  hw_disk_health: '磁盘健康', hw_smart_predict: 'SMART 健康预测', hw_battery_wear: '电池损耗',
  hw_thermal: '温度热区', hw_memdiag_history: '内存诊断史',
  dv_driver_signature: '驱动签名', dv_driver_age: '驱动年代', dv_thirdparty_inventory: '第三方驱动数量',
  dv_network_filters: '网络过滤驱动', dv_device_errors: '设备错误（黄三角）', dv_driver_load_failures: '驱动加载失败',
  pf_boot_duration: '开机用时', pf_boot_degradation_events: '开机变慢事件', pf_startup_items: '开机自启项',
  pf_service_timeouts: '服务超时', pf_disk_space: '磁盘剩余空间', pf_memory_pressure: '内存压力',
  pf_disk_saturation: '磁盘繁忙度',
};
function humanCheck(n) { return CHECK_HUMAN[n] || n; }

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
  document.querySelectorAll('.view').forEach((v) => v.classList.remove('active'));
  $('#view-' + name).classList.add('active');
  document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.dataset.view === name));
  if (name === 'repair') buildRepairList();
}
$('#tabs').addEventListener('click', (e) => {
  const t = e.target.closest('.tab');
  if (t) switchView(t.dataset.view);
});

/* ---------- 心跳（页面存活=server 存活；窗关=心跳断→server 杀引擎自杀） ---------- */
setInterval(() => {
  fetch('/api/heartbeat', { method: 'POST', cache: 'no-store' }).catch(() => {});
}, 1000);

/* ---------- 勾选逻辑（对齐 v0.7.1：勾全面=五树联动勾选并禁用单改） ---------- */
function buildChecks() {
  const grid = $('#check-grid');
  S.meta.trees.forEach((t) => {
    const label = document.createElement('label');
    label.className = 'check-item tree-item';
    label.dataset.tree = t.id;
    label.title = t.tip;
    label.innerHTML = '<input type="checkbox" class="chk-tree" checked>' +
      '<span class="box"></span>' +
      '<span class="txt"><b>' + esc(t.name) + '（' + esc(t.desc) + '）</b><small>' + esc(t.tip) + '</small></span>';
    grid.appendChild(label);
  });
  const all = $('#chk-all');
  all.addEventListener('change', () => {
    document.querySelectorAll('.tree-item').forEach((it) => {
      it.querySelector('input').checked = all.checked;
      it.classList.toggle('disabled', all.checked);
    });
    updateSelUi();
  });
  document.querySelectorAll('.tree-item input').forEach((inp) => {
    inp.addEventListener('change', updateSelUi);
  });
  $('#chk-fast').addEventListener('change', updateSelUi);
}
function getSelectionForm() {
  const picked = [...document.querySelectorAll('.tree-item input')].filter((i) => i.checked).map((i) => i.closest('.tree-item').dataset.tree);
  if (picked.length === 5) return 'all';
  if (picked.length === 1) return picked[0];
  if (picked.length === 0) return 'none';
  return 'invalid-2-4';
}
function updateSelUi() {
  if (S.appState === 'running') return;
  const btn = $('#btn-run');
  btn.classList.remove('running', 'danger');
  const sel = getSelectionForm();
  const hint = $('#sel-hint');
  if (S.appState === 'idle') {
    if (sel === 'invalid-2-4') { btn.disabled = true; hint.textContent = '只支持查一项或全部——勾 2 到 4 项不行'; hint.className = 'hint warn'; setStatus('只支持查一项或全部——勾 2 到 4 项不行', ''); }
    else if (sel === 'none') { btn.disabled = true; hint.textContent = '先勾选要查的项目'; hint.className = 'hint warn'; setStatus('先勾选要查的项目', ''); }
    else { btn.disabled = false; hint.textContent = '选好后点「开始体检」'; hint.className = 'hint'; setStatus('就绪', ''); }
  } else {
    btn.disabled = false;
    btn.textContent = '再跑一次';
    hint.textContent = '上轮已结束，点「再跑一次」重新选、重新查';
    hint.className = 'hint';
  }
}

/* ---------- 跑批启动 / 取消 ---------- */
$('#btn-run').addEventListener('click', () => {
  if (S.appState === 'running') { cancelRun(); return; }
  if (S.appState !== 'idle') { resetToIdle(); return; }
  startRun();
});

async function startRun() {
  const sel = getSelectionForm();
  if (sel === 'none' || sel === 'invalid-2-4') return;
  const treeArg = sel;
  S.fast = $('#chk-fast').checked;
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
  S.appState = 'running';
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
  document.querySelectorAll('#select-card input').forEach((i) => (i.disabled = true));
  const btn = $('#btn-run');
  btn.textContent = '取消';
  btn.disabled = false;
  btn.classList.add('running');
  addLog('—— 开始' + name + ' ——', 'st-dim');
  if (S.expectSeq.length > 0) setNextCurrent(0);
  setStatus('正在检查（共 ' + S.expectSeq.length + ' 项）…', '');
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

/* ---------- 轮询 /api/events（500ms，对齐 GUI DispatcherTimer） ---------- */
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
    // 页面刷新后恢复：server 还在跑
    recoverRunning(payload);
  }
}

function handleEvent(ev) {
  if (ev.event === 'check') {
    const sec = ev.ms ? (ev.ms / 1000).toFixed(1) + ' 秒' : '';
    addLog(statusWord(ev.status) + '  ' + humanCheck(ev.check) + ' · ' + sec, stClass(ev.status));
    S.seqPos++;
    const pct = S.expectSeq.length ? Math.round((S.seqPos / S.expectSeq.length) * 100) : 0;
    $('#progress-fill').style.width = pct + '%';
    $('#pct-label').textContent = S.seqPos + ' / ' + S.expectSeq.length + ' 项';
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
      $('#pct-label').textContent = S.seqPos + ' / ' + S.expectSeq.length + ' 项';
    }
  } else if (ev.event === 'tree_done') {
    const t = S.meta.trees.find((x) => x.id === ev.tree);
    const name = t ? t.name : ev.tree;
    addLog('—— ' + name + '完成：' + (ev.status === 'FAIL' ? '发现问题' : '全部正常') + ' ——', 'st-dim');
  } else if (ev.event === 'done') {
    // htmlUrl/jsonUrl 在 finalize 经 /api/report 取
  }
}
function stClass(st) { return st === 'PASS' ? 'st-pass' : st === 'FAIL' ? 'st-fail' : 'st-skip'; }

function recoverRunning(payload) {
  S.appState = 'running';
  S.lastSeq = 0;
  // 重放全量事件重建日志与进度
  $('#log-box').innerHTML = '';
  addLog('—— 页面刷新过，接着显示进度 ——', 'st-dim');
  (payload.events || []).forEach((ev) => handleEvent(ev));
  S.lastSeq = payload.lastSeq;
  S.runStartAt = Date.now() - (payload.elapsedSec || 0) * 1000;
  S.fast = payload.runFull === false;
  const btn = $('#btn-run');
  btn.textContent = '取消'; btn.disabled = false; btn.classList.add('running');
  document.querySelectorAll('#select-card input').forEach((i) => (i.disabled = true));
  $('#run-card').classList.remove('hidden');
  $('#pct-label').textContent = S.seqPos + ' / ' + S.expectSeq.length + ' 项';
  startElapsed();
  setStatus('正在检查…（页面刷新过）', '');
}

function finalize(payload) {
  stopPolling(); stopElapsed();
  S.appState = payload.state;
  const secHuman = Math.max(1, Math.round((Date.now() - S.runStartAt) / 1000)) || (payload.elapsedSec || 0);
  $('#view-wizard').classList.remove('running');
  if (payload.state === 'done') {
    S.htmlUrl = payload.htmlUrl || '';
    addLog('—— 检查完成（' + secHuman + ' 秒）· ' + (payload.exit === 0 ? '全部正常' : '发现问题') + ' ——',
      payload.exit === 0 ? 'st-pass' : 'st-fail');
    $('#progress-fill').style.width = '100%';
    setCurrent('查完了。左边看每项结果，也可以点「浏览器看完整报告」');
    setStatus('检查完成（' + secHuman + ' 秒）· ' + exitHuman(payload.exit), payload.exit === 0 ? '' : 'err');
    loadReport().then(() => {
      switchView('results');
      updateSelUi();
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

/* ---------- 用时（状态栏右侧，对齐 GUI 每秒刷） ---------- */
function startElapsed() {
  stopElapsed();
  S.elapsedTimer = setInterval(() => {
    const s = Math.floor((Date.now() - S.runStartAt) / 1000);
    const mm = String(Math.floor(s / 60)).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    $('#status-right').textContent = '电脑体检台 ' + APP_VERSION + ' · 用时 ' + mm + ':' + ss;
  }, 1000);
}
function stopElapsed() {
  if (S.elapsedTimer) { clearInterval(S.elapsedTimer); S.elapsedTimer = null; }
  $('#status-right').textContent = '电脑体检台 ' + APP_VERSION;
}

/* ---------- 报告与结果树（数据源=/api/report → engine JSON 报告，B 案） ---------- */
async function loadReport() {
  try {
    const r = await fetch('/api/report', { cache: 'no-store' });
    const j = await r.json();
    if (j.error || !j.report) { S.reportPayload = null; return false; }
    S.reportPayload = j;
    buildResultTree();
    buildRepairList();
    return true;
  } catch (e) { return false; }
}

function buildResultTree() {
  const tree = $('#result-tree');
  tree.innerHTML = '';
  if (!S.reportPayload) {
    tree.innerHTML = '<div class="placeholder">查完的结果会显示在这里</div>';
    return;
  }
  const j = S.reportPayload.report;
  const time = (j.time || '').replace(/:\d\d$/, '');
  const isAll = (j.trees || []).length > 1;
  const exit = S.reportPayload.exit;
  const rootText = isAll ? '全面体检报告  ' + time : ((j.trees[0] || {}).report_name || '体检报告') + '  ' + time;

  const root = document.createElement('details');
  root.open = true;
  const rootSum = document.createElement('summary');
  rootSum.style.fontWeight = '700';
  rootSum.style.fontSize = '13.5px';
  rootSum.style.color = exit === 0 ? 'var(--pass)' : 'var(--fail)';
  rootSum.appendChild(document.createTextNode(rootText));
  root.appendChild(rootSum);
  root.__data = { type: 'root', title: rootText, exitCode: exit, time: time };
  rootSum.addEventListener('click', (e) => { e.stopPropagation(); selectNode(rootSum.parentElement); });

  const children = document.createElement('div');
  children.className = 'node-children';
  (j.trees || []).forEach((t) => {
    children.appendChild(buildTreeSection(t));
  });
  root.appendChild(children);
  tree.appendChild(root);
  const treeCard = document.querySelector('.tree-card');
  if (treeCard) treeCard.scrollTop = 0;
  selectNode(root);
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
  sum.addEventListener('click', (e) => { e.stopPropagation(); selectNode(sum.parentElement); });

  const kids = document.createElement('div');
  kids.className = 'node-children';
  (t.layers || []).forEach((l, i) => {
    kids.appendChild(buildLayerNode(t, l, i));
  });
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
  sum.style.color = mcls === 'fail' ? 'var(--fail)' : mcls === 'skip' ? 'var(--skip)' : 'var(--pass)';
  sum.appendChild(tSpan);
  sum.appendChild(markSpan);
  det.appendChild(sum);
  det.__data = { type: 'layer', data: l, treeName: t.report_name };
  sum.addEventListener('click', (e) => { e.stopPropagation(); selectNode(sum.parentElement); });

  const kids = document.createElement('div');
  kids.className = 'node-children';
  (l.checks || []).forEach((c) => {
    const leaf = document.createElement('div');
    leaf.className = 'leaf';
    leaf.style.color = c.status === 'PASS' ? 'var(--pass)' : c.status === 'FAIL' ? 'var(--fail)' : 'var(--skip)';
    leaf.title = c.name;
    leaf.appendChild(document.createTextNode(statusWord(c.status) + '  ' + humanCheck(c.name)));
    leaf.__data = { type: 'check', data: c, treeName: t.report_name };
    leaf.addEventListener('click', () => selectNode(leaf));
    kids.appendChild(leaf);
  });
  det.appendChild(kids);
  return det;
}

/* ---------- 选中渲染（对齐 GUI：check/layer/tree/root 四型） ---------- */
function selectNode(node) {
  const tag = node.__data;
  if (!tag) return;
  S.lastNode = node;
  const title = $('#sel-title');
  const ev = $('#ev-box');
  const sug = $('#sug-box');
  const copyBtn = $('#btn-copy');
  S.currentSuggestion = '';
  copyBtn.disabled = true;
  copyBtn.textContent = '复制修复方法';
  ev.textContent = '';
  sug.textContent = '';
  // v0.9.2 折叠逻辑：check 型=原始记录收起（每次选中新节点重置）；layer/tree/root 型=说明展开直接可见
  const fold = $('#ev-fold');
  const isCheck = tag.type === 'check';
  $('#ev-label').textContent = isCheck ? '看原始记录（这一项查了什么）' : '这一步的说明';
  fold.open = !isCheck;
  if (tag.type === 'check') {
    const c = tag.data;
    title.textContent = humanCheck(c.name) + '  ' + statusWord(c.status);
    title.style.color = c.status === 'PASS' ? 'var(--pass)' : c.status === 'FAIL' ? 'var(--fail)' : 'var(--skip)';
    ev.textContent = c.evidence || '';
    if (c.suggestion) {
      sug.textContent = c.suggestion;
      if (c.status === 'FAIL') { S.currentSuggestion = c.suggestion; copyBtn.disabled = false; }
    } else {
      sug.textContent = c.status === 'FAIL' ? '（这项有问题但没给修复方法——异常，请反馈）' : '（这项正常，不需要修）';
    }
  } else if (tag.type === 'layer') {
    const l = tag.data;
    title.textContent = l.title;
    title.style.color = l.state === 'BREAK' ? 'var(--fail)' : (l.state || '').indexOf('SKIPPED') === 0 ? 'var(--skip)' : 'var(--pass)';
    const stateHuman = l.state === 'BREAK' ? '这一步查出了问题'
      : (l.state === 'PASS' || l.state === 'PASSED-EARLIER') ? '这一步全部正常'
      : (l.state || '').indexOf('SKIPPED') === 0 ? '快速模式下这一步没有查' : l.state;
    ev.textContent = stateHuman + '\r\n\r\n这一步说明：' + (l.verdict_fail || '');
    sug.textContent = '（点开这一步下面的具体项目，看怎么修）';
  } else if (tag.type === 'tree') {
    const t = tag.data;
    title.textContent = t.report_name;
    title.style.color = t.break_layer ? 'var(--fail)' : 'var(--pass)';
    const concl = t.break_layer ? '问题出在这一步：' + tag.breakTitle : '全部正常';
    ev.textContent = concl + '\r\n\r\n这项检查正常时会看到：' + (t.verdict_all_pass || '');
    sug.textContent = '（点开左边的步骤看每项详情）';
  } else if (tag.type === 'root') {
    title.textContent = tag.title;
    title.style.color = tag.exitCode === 0 ? 'var(--pass)' : 'var(--fail)';
    ev.textContent = '总结论：' + exitHuman(tag.exitCode) + '\r\n报告时间：' + tag.time + '\r\n\r\n想看带样式的完整报告：点上方「浏览器看完整报告」';
    sug.textContent = '（点开左边的树和步骤，查看每项详情）';
  }
}

/* ---------- 结果中心按钮 ---------- */
$('#btn-browser').addEventListener('click', () => {
  if (S.htmlUrl) window.open(S.htmlUrl, '_blank');
});
$('#btn-folder').addEventListener('click', async () => {
  try { await fetch('/api/open-reports', { method: 'POST', cache: 'no-store' }); } catch (e) {}
});
$('#btn-again').addEventListener('click', () => { resetToIdle(); switchView('wizard'); });

function resetToIdle() {
  S.appState = 'idle';
  S.seqPos = 0; S.lastSeq = 0; S.htmlUrl = '';
  $('#log-box').innerHTML = '';
  $('#progress-fill').style.width = '0%';
  $('#pct-label').textContent = '0 / 0 项';
  $('#run-card').classList.add('hidden');
  $('#select-card').classList.remove('disabled');
  document.querySelectorAll('#select-card input').forEach((i) => (i.disabled = false));
  const btn = $('#btn-run');
  btn.textContent = '开始体检';
  btn.classList.remove('running');
  setCurrent('选好后点「开始体检」');
  setStatus('就绪', '');
  updateSelUi();
}

/* ---------- 复制（localhost=安全上下文，clipboard API 可用；execCommand 兜底；
   都失败=极端环境（页面失焦/无手势），弹选中文本层让用户 Ctrl+C，永不留死路） ---------- */
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

/* ---------- 修复中心（v0.8.1：按报告 FAIL 项匹配动作；绿=可代跑，黄=确认弹层，红=指南页） ---------- */
const LV_META = {
  green: { word: '绿色 · 安全可撤销', cls: 'green' },
  yellow: { word: '黄色 · 要你确认', cls: 'yellow' },
  red: { word: '红色 · 只给步骤', cls: 'red' },
};
const CMD_MAP = {
  'ipconfig.exe /flushdns': 'ipconfig /flushdns',
  'arp.exe -d *': 'arp -d *',
  'ipconfig.exe /registerdns': 'ipconfig /registerdns',
  'netsh.exe winsock reset': 'netsh winsock reset',
  'netsh.exe int ipv4 reset': 'netsh int ipv4 reset',
  'netsh.exe int ipv6 reset': 'netsh int ipv6 reset',
  'netsh.exe int tcp reset': 'netsh int tcp reset',
};
function stepCmdText(st) {
  const raw = st.exe + ' ' + (st.args || []).join(' ');
  return CMD_MAP[raw] || raw;
}

function buildRepairList() {
  const box = $('#repair-list');
  if (!box) return;
  if (!S.reportPayload) return; // 占位文案保持
  const fails = [];
  (S.reportPayload.report.trees || []).forEach((t) => {
    (t.layers || []).forEach((l) => {
      (l.checks || []).forEach((c) => {
        if (c.status === 'FAIL' && c.suggestion) fails.push({ tree: t.report_name, check: c.name, sug: c.suggestion });
      });
    });
  });
  box.innerHTML = '';
  if (fails.length === 0) {
    box.innerHTML = '<div class="placeholder">这一轮体检没有查出问题，或问题项没有修复步骤。</div>';
    return;
  }
  fails.forEach((f) => {
    const item = document.createElement('div');
    item.className = 'repair-item';
    const head = document.createElement('div');
    head.className = 'ri-head';
    const ti = document.createElement('div');
    ti.className = 'ri-title';
    ti.textContent = '【' + f.tree + '】' + humanCheck(f.check);
    const cp = document.createElement('button');
    cp.className = 'btn';
    cp.textContent = '复制修复方法';
    cp.addEventListener('click', () => { doCopy(f.sug, cp, '复制修复方法'); });
    head.appendChild(ti); head.appendChild(cp);
    item.appendChild(head);

    const matched = (S.repairActions || []).filter((a) => (a.match_checks || []).indexOf(f.check) >= 0);
    matched.forEach((a) => { item.appendChild(buildActionCard(a)); });

    const pre = document.createElement('pre');
    pre.textContent = f.sug;
    item.appendChild(pre);
    box.appendChild(item);
  });
}

function buildActionCard(a) {
  const card = document.createElement('div');
  card.className = 'action-card lv-' + (LV_META[a.level] ? a.level : 'green');
  const badge = document.createElement('div');
  badge.className = 'ac-badge';
  const bm = LV_META[a.level] || LV_META.green;
  badge.innerHTML = '<b>' + esc(a.name) + '</b><span class="lv-tag ' + bm.cls + '">' + bm.word + '</span>';
  card.appendChild(badge);

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

  // v0.9.2：卡片内命令行折叠收起；黄级确认弹层/红级指南里的步骤不折叠（安全知情全量）
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
    setStatus(S.appState === 'running' ? '正在检查中，请等这轮结束再修复' : '正在修复中，请等它结束', 'err');
    return;
  }
  if (a.requires_admin) {
    showGreenConfirmModal(a, () => startRepairRun(a, btn, card));
  } else {
    startRepairRun(a, btn, card);
  }
}
function showGreenConfirmModal(a, onGo) {
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
/* 黄级逐项确认（v0.9 真流程替换预告弹层）：三行（将做什么/影响什么/怎么撤销）逐项打勾才点亮
   「确认执行」；可选系统还原点勾选（默认勾，建不出来执行器自动中止）；回滚包先行由执行器保证 */
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
  const note = document.createElement('div');
  note.className = 'rm-note';
  note.textContent = '执行中可能短暂断网，请等它跑完再操作；一次只做一个修复，不做并发。';
  rows.appendChild(note);
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
  document.getElementById('rm-title').textContent = a.name || '修复动作';
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
  setTimeout(() => { if (btn.dataset.armed === '1') { btn.dataset.armed = ''; btn.textContent = old; } }, 4000);
}
function showRedGuide(a) {
  a = a || {};
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
    const line = document.createElement('div');
    line.textContent = (i + 1) + '. ' + (st.desc || '') + '（' + stepCmdText(st) + '）';
    steps.appendChild(line);
  });
  rows.appendChild(steps);
  document.getElementById('guide-overlay').classList.remove('hidden');
}
document.getElementById('gd-ok').addEventListener('click', () => {
  document.getElementById('guide-overlay').classList.add('hidden');
});

async function startRepairRun(a, btn, card, opts) {
  opts = opts || {};
  setRepairBusy(true, btn);
  setStatus('正在修复：' + a.name + (a.level === 'yellow' ? '（先生成回滚包，再执行）…' : ' …'), '');
  let slot = card.querySelector('.ac-result');
  if (!slot) { slot = document.createElement('div'); slot.className = 'ac-result'; card.appendChild(slot); }
  slot.innerHTML = '<div class="stage-line st-dim">修复中…（要做的事：' + esc((a.steps || []).map((s) => s.desc).join('；')) + '）</div>';
  try {
    const r = await fetch('/api/repair/run', {
      method: 'POST', cache: 'no-store',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: a.id, restore_point: !!opts.restorePoint }),
    });
    const j = await r.json();
    if (!j.ok) { renderRepairResult(slot, { ok: false, human: j.error || '启动失败' }); return; }
    for (let i = 0; i < 200; i++) {
      await new Promise((res) => setTimeout(res, 700));
      let st;
      try { st = await (await fetch('/api/repair/status', { cache: 'no-store' })).json(); }
      catch (e) { continue; }
      if (st.state === 'done' && st.result) { S.repairDoneIds[a.id] = st.result; renderRepairResult(slot, st.result); return; }
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
  if (busy) { document.querySelectorAll('.act-run').forEach((b) => { b.dataset.origLabel = b.textContent; b.disabled = true; }); if (btn) btn.textContent = '修复中…'; }
  else { document.querySelectorAll('.act-run').forEach((b) => { b.disabled = false; if (b.dataset.origLabel) b.textContent = b.dataset.origLabel; }); }
}
function renderRepairResult(slot, res) {
  slot.innerHTML = '';
  if (!res || !res.stages) {
    const l = document.createElement('div');
    l.className = 'stage-line st-fail';
    l.textContent = '✗ ' + ((res && res.human) || '没有拿到修复结果');
    slot.appendChild(l);
    return;
  }
  const okLine = document.createElement('div');
  okLine.className = 'stage-line ' + (res.ok ? 'st-pass' : 'st-fail');
  okLine.textContent = (res.ok ? '✓ ' : '✗ ') + (res.human || '');
  slot.appendChild(okLine);
  const st = res.stages;
  const pre = st.precheck;
  if (pre) {
    const l = document.createElement('div');
    l.className = 'stage-line ' + (pre.ok ? 'st-pass' : 'st-fail');
    l.textContent = (pre.ok ? '✓ ① 预检通过' : '✗ ① 预检没过：' + (pre.notes || []).join('；'));
    slot.appendChild(l);
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
    slot.appendChild(l);
  }
  if (st.exec) {
    (st.exec.steps || []).forEach((s) => {
      const l = document.createElement('div');
      l.className = 'stage-line ' + (s.exit === 0 && !s.timed_out ? 'st-pass' : 'st-fail');
      l.textContent = (s.exit === 0 && !s.timed_out ? '✓ ③ ' : '✗ ③ ') + (s.desc || '') +
        (s.timed_out ? '：超时被停' : (s.exit !== 0 ? '：没跑成（退出码 ' + s.exit + '）' : '（' + (s.ms || 0) + ' 毫秒）'));
      slot.appendChild(l);
      if (s.out_head) {
        const o = document.createElement('div');
        o.className = 'stage-out';
        o.textContent = s.out_head;
        slot.appendChild(o);
      }
    });
    if (!(st.exec.steps || []).length && st.exec.note) {
      const l = document.createElement('div');
      l.className = 'stage-line st-skip';
      l.textContent = '– ③ ' + st.exec.note;
      slot.appendChild(l);
    }
  }
  const vf = st.verify;
  if (vf) {
    if ((vf.checks || []).length) {
      (vf.checks || []).forEach((c) => {
        const l = document.createElement('div');
        l.className = 'stage-line ' + (c.status === 'PASS' ? 'st-pass' : c.status === 'FAIL' ? 'st-fail' : 'st-skip');
        l.textContent = (c.status === 'PASS' ? '✓ ④ 复查 ' : c.status === 'FAIL' ? '✗ ④ 复查 ' : '– ④ 复查 ') +
          c.name + (c.status === 'PASS' ? '：正常' : c.status === 'FAIL' ? '：仍有问题（看下面建议）' : '：没查成');
        slot.appendChild(l);
      });
    } else if (vf.note) {
      const l = document.createElement('div');
      l.className = 'stage-line st-skip';
      l.textContent = '– ④ ' + vf.note;
      slot.appendChild(l);
    }
  }
  const lg = st.log;
  if (lg) {
    const l = document.createElement('div');
    l.className = 'stage-line ' + (lg.ok ? 'st-dim' : 'st-fail');
    l.textContent = lg.ok ? '✓ ⑤ 已记入修复台账（reports/repair-log.json）' : '✗ ⑤ 台账没写上：' + (lg.err || '');
    slot.appendChild(l);
  }
}

/* ---------- 关闭确认（网页内弹层；跑批中才拦） ---------- */
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
// 关窗/关标签时必达的告别信标（pagehide 兜底必发；后台节流不影响 sendBeacon）
window.addEventListener('pagehide', () => {
  try { navigator.sendBeacon('/api/bye'); } catch (e) {}
});

/* ---------- 主题（CSS 变量；localStorage 记住） ---------- */
const ACCENTS = { blue: '#4cc2ff', cyan: '#2dd4bf', green: '#3fd68f', violet: '#a78bfa', orange: '#ffb35c', pink: '#ff7b9c' };
function applyTheme(theme, accent) {
  const h = document.documentElement;
  h.dataset.theme = theme;
  h.dataset.accent = accent;
  try { localStorage.setItem('diag-theme', JSON.stringify({ t: theme, a: accent })); } catch (e) {}
  document.querySelectorAll('[data-theme-opt]').forEach((b) => b.classList.toggle('active', b.dataset.themeOpt === theme));
  document.querySelectorAll('.swatch').forEach((s) => s.classList.toggle('active', s.dataset.accentKey === accent));
}
function initTheme() {
  let cfg = { t: 'dark', a: 'blue' };
  try { const raw = localStorage.getItem('diag-theme'); if (raw) cfg = JSON.parse(raw); } catch (e) {}
  if (!ACCENTS[cfg.a]) cfg.a = 'blue';
  const row = $('#accent-row');
  Object.keys(ACCENTS).forEach((k) => {
    const s = document.createElement('button');
    s.className = 'swatch';
    s.dataset.accentKey = k;
    s.title = k;
    s.style.background = ACCENTS[k];
    s.addEventListener('click', () => applyTheme(document.documentElement.dataset.theme || 'dark', k));
    row.appendChild(s);
  });
  document.querySelectorAll('[data-theme-opt]').forEach((b) => {
    b.addEventListener('click', () => applyTheme(b.dataset.themeOpt, document.documentElement.dataset.accent || 'blue'));
  });
  applyTheme(cfg.t, cfg.a);
  $('#btn-theme').addEventListener('click', () => $('#theme-overlay').classList.remove('hidden'));
  $('#theme-done').addEventListener('click', () => $('#theme-overlay').classList.add('hidden'));
}

/* ---------- 背景图原画弹层（点任意处关闭；图缺失时 server 404=img 不渲染，层仍可开不致命） ---------- */
$('#btn-bg').addEventListener('click', () => $('#bg-overlay').classList.remove('hidden'));
$('#bg-overlay').addEventListener('click', () => $('#bg-overlay').classList.add('hidden'));

/* ---------- 工具 ---------- */
function esc(s) {
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/* ---------- 启动 ---------- */
// 探针（仅 ?probe 出现时激活）：视口实测写进窗口标题，UIA/Get-Process 可读（自动化诊断用，产品态零影响）
if (/[?&]probe/.test(location.search)) {
  const updProbe = () => {
    document.title = 'PROBE iw=' + window.innerWidth + ' sw=' + document.documentElement.scrollWidth + ' dpr=' + window.devicePixelRatio;
  };
  updProbe();
  window.addEventListener('resize', updProbe);
}
(async function init() {
  initTheme();
  try {
    const r = await fetch('/api/meta', { cache: 'no-store' });
    S.meta = await r.json();
  } catch (e) {
    setStatus('连接不上本地服务，请关掉窗口重新打开', 'err');
    return;
  }
  buildChecks();
  updateSelUi();
  // v0.8.1 修复动作清单（失败不致命：修复中心只是少了代跑卡片）
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
      // 重建 expectSeq
      const treeArg = p.runTree || 'all';
      S.fast = p.runFull === false;
      S.expectSeq = [];
      S.meta.trees.forEach((t) => {
        if (treeArg !== 'all' && t.id !== treeArg) return;
        t.layers.forEach((l) => l.checks.forEach((c) => S.expectSeq.push({ tree: t.id, layer: l.name, layerTitle: l.title, check: c })));
      });
      S.appState = 'running';
      $('#select-card').classList.add('disabled');
      document.querySelectorAll('#select-card input').forEach((i) => (i.disabled = true));
      $('#run-card').classList.remove('hidden');
      S.runStartAt = Date.now() - (p.elapsedSec || 0) * 1000;
      (p.events || []).forEach((ev) => handleEvent(ev));
      S.lastSeq = p.lastSeq;
      const btn = $('#btn-run');
      btn.textContent = '取消'; btn.disabled = false; btn.classList.add('running');
      startPolling(); startElapsed();
      setStatus('正在检查…（页面刷新过，接着显示）', '');
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
    }
  } catch (e) {}
})();

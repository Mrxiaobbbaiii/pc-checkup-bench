'use strict';
/* diag ui v0.8 —— 纯原生 JS，零构建零 CDN（断网可用）
   文案口径=design 详版第十四节对照表（与 v0.7.1 GUI 逐句对齐）；功能对齐 v0.7.1：
   树勾选（全勾/单勾，勾 2-4 禁用）+进度+日志三态着色+结果树+FAIL 复制+取消+关闭确认（网页内弹层）+浏览器看报告 */

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
};

const STATUS_WORD = { PASS: '✓ 正常', FAIL: '✗ 有问题', SKIP: '– 没查成' };
const LAYER_NUM = ['①', '②', '③', '④', '⑤', '⑥'];

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
  setTimeout(() => { $('#run-card').scrollIntoView({ behavior: 'smooth', block: 'nearest' }); }, 60);
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
    addLog(statusWord(ev.status) + '  ' + ev.check + ' · ' + sec, stClass(ev.status));
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
        addLog('– 没查成  ' + nx.check + '（快速模式提前结束）', 'st-skip');
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
    $('#status-right').textContent = 'diag v0.8 · 用时 ' + mm + ':' + ss;
  }, 1000);
}
function stopElapsed() {
  if (S.elapsedTimer) { clearInterval(S.elapsedTimer); S.elapsedTimer = null; }
  $('#status-right').textContent = 'diag v0.8';
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
    leaf.appendChild(document.createTextNode(statusWord(c.status) + '  ' + c.name));
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
  const title = $('#sel-title');
  const ev = $('#ev-box');
  const sug = $('#sug-box');
  const copyBtn = $('#btn-copy');
  S.currentSuggestion = '';
  copyBtn.disabled = true;
  copyBtn.textContent = '复制修复方法';
  ev.textContent = '';
  sug.textContent = '';
  if (tag.type === 'check') {
    const c = tag.data;
    title.textContent = c.name + '  ' + statusWord(c.status);
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

/* ---------- 修复中心（v0.8 占位：只列 FAIL+给步骤文本，零代跑） ---------- */
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
    ti.textContent = '【' + f.tree + '】' + f.check;
    const cp = document.createElement('button');
    cp.className = 'btn';
    cp.textContent = '复制修复方法';
    cp.addEventListener('click', () => { doCopy(f.sug, cp, '复制修复方法'); });
    head.appendChild(ti); head.appendChild(cp);
    const pre = document.createElement('pre');
    pre.textContent = f.sug;
    item.appendChild(head); item.appendChild(pre);
    box.appendChild(item);
  });
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

/* ---------- 工具 ---------- */
function esc(s) {
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/* ---------- 启动 ---------- */
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

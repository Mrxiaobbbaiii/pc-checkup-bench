// i18n_actions_check.mjs —— 修复卡英文映射静态对齐校验（1026 方案 B·M3 收口）
// 断言：en-US.js actions 节与 repair/actions/*.json 双侧字段对齐 + 按真实消费语义
// （app.js actField/actSteps/actSource）模拟 console.warn 触发条件 = 0 warn。
// 输出纯 ASCII（run_tests.ps1 ⑧ 节起本脚本，退出码 0=全绿）。
// 铁律：repair/actions/*.json 是执行层真源禁改——本脚本只读。
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

// load en-US.js (browser script assigning window.I18N_EN) in a sandbox
const sandbox = { window: {}, console: { warn: () => {} } };
vm.createContext(sandbox);
vm.runInContext(readFileSync(join(root, 'ui/i18n/en-US.js'), 'utf8'), sandbox);
const EN = sandbox.window.I18N_EN && sandbox.window.I18N_EN.actions;
if (!EN) { console.log('FAIL en_actions_present :: actions table missing'); process.exit(1); }

const files = readdirSync(join(root, 'repair/actions')).filter((f) => f.endsWith('.json')).sort();
const jsons = files.map((f) => JSON.parse(readFileSync(join(root, 'repair/actions', f), 'utf8')));

let fails = 0, checks = 0;
function assert(name, ok, why) {
  checks++;
  if (!ok) { fails++; console.log('FAIL ' + name + (why ? ' :: ' + why : '')); }
}

// A1 key sets both ways: en keys == action ids (no orphans, no missing)
const enKeys = Object.keys(EN).sort();
const jsonIds = jsons.map((j) => j.id).sort();
assert('A1_keyset_bothways', enKeys.join(',') === jsonIds.join(','),
  'en-only:[' + enKeys.filter((k) => jsonIds.indexOf(k) < 0) + '] json-only:[' + jsonIds.filter((k) => enKeys.indexOf(k) < 0) + ']');

const CJK = /[\u4e00-\u9fff\u3010\u3011]/; // han chars or 【】 markers
function val(o, k) { const v = o ? o[k] : undefined; return (typeof v === 'string') ? v : undefined; }

for (const j of jsons) {
  const en = EN[j.id] || {};
  // A2 core fields non-empty strings (fields consumed for every card)
  for (const f of ['name', 'desc', 'affect', 'undo']) {
    assert('A2_' + j.id + '.' + f, !!val(en, f), 'empty/missing');
  }
  // A3 caveat aligned: json non-empty <=> en non-empty (empty originals need no translation)
  const cvRaw = (j.caveat || '').trim();
  assert('A3_' + j.id + '.caveat', cvRaw ? !!val(en, 'caveat') : true, 'json has caveat but en missing/empty');
  // A4 rollback_note: json non-empty => en non-empty (fillModalRows consumes it standalone)
  const rbRaw = (j.rollback_note || '').trim();
  assert('A4_' + j.id + '.rollback_note', rbRaw ? !!val(en, 'rollback_note') : true, 'json has rollback_note but en missing/empty');
  // A5 steps: equal length + every step desc non-empty + how subfields aligned when present
  const js = j.steps || [];
  const es = en.steps;
  assert('A5_' + j.id + '.steps_len', Array.isArray(es) && es.length === js.length,
    'json=' + js.length + ' en=' + (Array.isArray(es) ? es.length : 'n/a'));
  js.forEach((st, i) => {
    assert('A5_' + j.id + '.steps[' + i + '].desc', !!(es && es[i] && val(es[i], 'desc')), 'empty/missing');
    if (st.how && es && es[i]) {
      for (const hk of ['at', 'click', 'type', 'ok', 'fail']) {
        if (st.how[hk] !== undefined) assert('A5_' + j.id + '.steps[' + i + '].how.' + hk, !!val(es[i].how, hk), 'empty/missing');
      }
    }
  });
  // A6 sources: equal length + every title non-empty string
  const jsrc = j.sources || [];
  assert('A6_' + j.id + '.sources_len', Array.isArray(en.sources) && en.sources.length === jsrc.length,
    'json=' + jsrc.length + ' en=' + (Array.isArray(en.sources) ? en.sources.length : 'n/a'));
  (en.sources || []).forEach((s, i) => assert('A6_' + j.id + '.source#' + i, typeof s === 'string' && !!s, 'empty/missing'));
}

// A7 no CJK / 【】 residue in any en actions string value
(function () {
  const bad = [];
  (function walk(v, path) {
    if (typeof v === 'string') { if (CJK.test(v)) bad.push(path); return; }
    if (Array.isArray(v)) { v.forEach((x, i) => walk(x, path + '[' + i + ']')); return; }
    if (v && typeof v === 'object') { for (const k of Object.keys(v)) walk(v[k], path + '.' + k); }
  })(EN, 'actions');
  assert('A7_no_cjk_residue', bad.length === 0, bad.slice(0, 8).join(' '));
})();

// A8 warn-semantics simulation: replay actField/actSteps/actSource trigger conditions
// over the real consumption surface (buildActionCard / buildLauncherCard / fillModalRows),
// including the raw-empty short-circuit — expected total warns = 0.
(function () {
  const warns = [];
  function actFieldSim(j, en, field) {
    const raw = j[field];
    if (raw === undefined || raw === null || raw === '') return; // empty original: nothing to translate, no warn
    const v = en ? en[field] : undefined;
    if (typeof v === 'string' && v) return;
    warns.push(j.id + '.' + field);
  }
  function actStepsSim(j, en) {
    const raw = j.steps || [];
    if (!en || !Array.isArray(en.steps)) { warns.push(j.id + '.steps'); return; }
    // index merge: shorter en array silently falls back per-step; a strict cover demands equal length
    if (en.steps.length !== raw.length) warns.push(j.id + '.steps(len ' + en.steps.length + '!=' + raw.length + ')');
  }
  function actSourceSim(j, en, i) {
    const v = en && Array.isArray(en.sources) ? en.sources[i] : undefined;
    if (typeof v === 'string' && v) return;
    warns.push(j.id + '.source#' + i);
  }
  for (const j of jsons) {
    const en = EN[j.id];
    // every card: name + desc (buildActionCard & buildLauncherCard both consume)
    actFieldSim(j, en, 'name'); actFieldSim(j, en, 'desc');
    if (j.launcher) continue; // launcher cards stop at name/desc + doc link label
    // non-launcher: full action card + confirm modal rows
    for (const f of ['affect', 'undo', 'caveat', 'rollback_note']) actFieldSim(j, en, f);
    actStepsSim(j, en);
    (j.sources || []).forEach((s, i) => actSourceSim(j, en, i));
  }
  assert('A8_warn_semantics_zero', warns.length === 0, warns.slice(0, 8).join(' '));
})();

console.log('================ i18n_actions_check: ' + (checks - fails) + '/' + checks + ' PASS ================');
process.exit(fails ? 1 : 0);

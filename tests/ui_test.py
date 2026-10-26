# -*- coding: utf-8 -*-
"""
diag UI 自动测试套件：CDP 驱动 headless Edge 的 DOM 断言回归网。
覆盖：A 静态向导页 / B 页签交互 / C mock 跑批全链（dns_deadaddr 断点场景+net_dns_public 超时）/ D 修复中心联动 / E 历史对比 / F 修复后感知。
跑法：python -X utf8 tests/ui_test.py   （退出码 0=全过）
工艺：起 server(-MockDir)+headless Edge(随机调试端口)→CDP evaluate 断言→bye 收尾零残留。
"""
import json, os, shutil, subprocess, sys, time, urllib.request

import os as _os; DIAG = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
sys.path.insert(0, '') if False else None
try:
    import websocket  # websocket-client
except ImportError:
    print('FATAL: pip install websocket-client'); sys.exit(2)

# ---------- mock 数据（dns_deadaddr_breakpoint 场景，tests/scenarios.ps1 同源复刻） ----------
ROUTE = "Active Routes:\nNetwork Destination        Netmask          Gateway       Interface  Metric\n          0.0.0.0          0.0.0.0      192.168.1.1     192.168.1.108     35\n"
ADAPTER = "Admin State    State          Type             Interface Name\n-------------------------------------------------------------------------\nEnabled        Connected      Dedicated        WLAN\n"
IPPASS = "Configuration for interface \"WLAN\"\n    DHCP enabled:                         Yes\n    IP Address:                           192.168.1.108\n    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)\n    Default Gateway:                      192.168.1.1\n"
GWOK = "###GW 192.168.1.1\n\nPinging 192.168.1.1 with 32 bytes of data:\nReply from 192.168.1.1: bytes=32 time=2ms TTL=64"
PUBOK = "###SRC 192.168.1.108\n\nPinging 223.5.5.5 with 32 bytes of data:\nReply from 223.5.5.5: bytes=32 time=30ms TTL=50"
DNSDEAD = "Configuration for interface \"WLAN\"\n    Statically Configured DNS Servers:    192.168.137.1\n    Register with which suffix:           Primary only\n===PART===\nConfiguration for interface \"WLAN\"\n    DHCP enabled:                         Yes\n    IP Address:                           192.168.1.108\n    Subnet Prefix:                        192.168.1.0/24 (mask 255.255.255.0)\n"
NSTIMEOUT = "DNS request timed out.\n    timeout was 2 seconds."
NSOKPUB = "Server:  public1.alidns.com\nAddress:  223.5.5.5\n\nNon-authoritative answer:\nName:    qq.com\nAddresses:  113.108.81.189"
MOCKS = {
    'net_adapter_list': ADAPTER, 'net_ip_dhcp': IPPASS,
    'net_gateway_conflict': ROUTE,
    'net_gateway_ping': ROUTE + '\n===PART===\n' + GWOK,
    'net_public_ping': ROUTE + '\n===PART===\n' + PUBOK,
    'net_dns_deadaddr': DNSDEAD, 'net_dns_default': NSTIMEOUT,
    'net_dns_gateway_proxy': ROUTE + '\n===PART===\n###GW 192.168.1.1\n' + NSTIMEOUT,
    # 公共 DNS 也超时（F 段前提：net_dns_public FAIL 才会让「刷新 DNS 缓存」绿卡
    # 出现在「能代跑的修复」——match_checks=net_dns_public；场景=DNS 全瘫）。
    # F 段点击修复前会把本项 mock 文件覆写回 NSOKPUB，模拟刷新缓存修复生效→快扫 PASS→改善行。
    'net_dns_public': NSTIMEOUT,
    # I 段（建议正文英译 M1）：安全树/性能树单树跑批用 mock；缺 mock 的其余检查=SKIP（missing-mock）
    'sec_uac_level': 'EnableLUA=1\nConsentPromptBehaviorAdmin=0\nPromptOnSecureDesktop=1',
    'pf_boot_duration': '10-20 | Warning | 95300\n10-19 | Warning | 88210\n10-18 | Information | 41200',
    # I 段 M2 抽验（1026 全量轮）：defender 状态/磁盘空间（嵌套 disks 真对象）/内存 lowmem 变体分支
    'sec_defender_status': 'AMRunningMode=Normal\nAntivirusEnabled=True\nRealTimeProtectionEnabled=False\nAntivirusSignatureAge=0\nAntivirusSignatureLastUpdated=2026/10/25 0:31:48\n',
    'pf_disk_space': 'C: | 237 | 11.2 | sys\nD: | 931 | 512 | -\n',
    'pf_memory_pressure': '2.0 | 31.9 | 3.1\n',
}

def http_json(url, method='GET', body=None, timeout=8):
    req = urllib.request.Request(url, method=method)
    req.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(req, body and body.encode() or None, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))

class CDP:
    def __init__(self, ws_url):
        self.ws = websocket.create_connection(ws_url, timeout=15)
        self._id = 0
    def _send(self, method, params=None):
        self._id += 1
        msg = {'id': self._id, 'method': method}
        if params: msg['params'] = params
        self.ws.send(json.dumps(msg))
        while True:
            r = json.loads(self.ws.recv())
            if r.get('id') == self._id:
                return r
    def activate(self):
        # headless pages get throttled (visibility/lifecycle) - timers stall and UI never
        # refreshes; force active lifecycle + focus emulation so the page JS polls normally
        try:
            self._send('Page.setWebLifecycleState', {'state': 'active'})
            self._send('Emulation.setFocusEmulationEnabled', {'enabled': True})
        except Exception:
            pass
    def eval(self, expr):
        self._id += 1
        self.ws.send(json.dumps({'id': self._id, 'method': 'Runtime.evaluate',
                                 'params': {'expression': expr, 'returnByValue': True}}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get('id') == self._id:
                if 'exceptionDetails' in msg:
                    raise RuntimeError('eval exception: ' + str(msg['exceptionDetails'])[:200])
                return msg['result'].get('result', {}).get('value')
    def wait_ready(self, tries=40):
        for _ in range(tries):
            if self.eval('document.readyState') == 'complete':
                return
            time.sleep(0.5)
        raise RuntimeError('page never ready')

RESULTS = []
def check(name, cond, detail=''):
    RESULTS.append((name, bool(cond)))
    print(('[PASS] ' if cond else '[FAIL] ') + name + (' :: ' + detail if detail and not cond else ''))

def main():
    tmp = os.path.join(os.environ['TEMP'], 'diag-uitest-' + str(os.getpid()))
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(os.path.join(tmp, 'mocks'), exist_ok=True)
    for k, v in MOCKS.items():
        open(os.path.join(tmp, 'mocks', k + '.txt'), 'w', encoding='utf-8').write(v)
    portfile = os.path.join(tmp, 'port.tmp')

    # 1) server with mocks; DIAG_DATA_ROOT redirects all report writes into the test sandbox
    # (round-1 mechanism; keeps the real reports/ dir clean)
    env = dict(os.environ)
    env['DIAG_DATA_ROOT'] = os.path.join(tmp, 'dataroot')
    os.makedirs(env['DIAG_DATA_ROOT'], exist_ok=True)
    server = subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        os.path.join(DIAG, 'server.ps1'), '-NoBrowser', '-PortFile', portfile, '-MockDir', os.path.join(tmp, 'mocks')],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    port = 0
    for _ in range(60):
        if os.path.exists(portfile):
            try: port = int(open(portfile).read().strip()); break
            except Exception: pass
        time.sleep(0.5)
    if not port:
        print('FATAL: server port never ready'); server.kill(); sys.exit(2)
    print('server port', port)
    for _ in range(30):
        try:
            http_json('http://127.0.0.1:%d/api/meta' % port); break
        except Exception: time.sleep(0.5)

    # pre-seed two synthetic reports into the test data root (E section: history+compare).
    # older = everything PASS; newer = dns_deadaddr FAIL -> compare must show it as worsening.
    def mk_report(name, checks):
        return {'engine': 'test', 'trees': [{'tree': 'network', 'layers': [
            {'name': 'dns', 'checks': [{'name': n, 'status': st, 'evidence': '', 'suggestion': ''} for n, st in checks]}]}]}
    rep_old = mk_report('old', [('net_dns_deadaddr', 'PASS'), ('net_dns_default', 'PASS')])
    rep_new = mk_report('new', [('net_dns_deadaddr', 'FAIL'), ('net_dns_default', 'PASS')])
    dr_reports = os.path.join(tmp, 'dataroot', 'reports')
    os.makedirs(dr_reports, exist_ok=True)
    open(os.path.join(dr_reports, 'diag-network-20260101-000001.json'), 'w', encoding='utf-8').write(json.dumps(rep_old, ensure_ascii=False))
    open(os.path.join(dr_reports, 'diag-network-20260102-000002.json'), 'w', encoding='utf-8').write(json.dumps(rep_new, ensure_ascii=False))

    # 2) headless Edge
    dbg = 19333
    edges = [os.path.expandvars(r'%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe'),
             os.path.expandvars(r'%ProgramFiles%\Microsoft\Edge\Application\msedge.exe')]
    edge_exe = next((e for e in edges if os.path.exists(e)), None)
    if not edge_exe:
        print('FATAL: msedge not found'); server.kill(); sys.exit(2)
    edge_p = subprocess.Popen([edge_exe, '--headless=new', '--remote-debugging-port=%d' % dbg,
        '--user-data-dir=' + os.path.join(tmp, 'edge-profile'), '--no-first-run',
        'about:blank'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cdp = None
    for _ in range(40):
        time.sleep(0.5)
        try:
            targets = http_json('http://127.0.0.1:%d/json/list' % dbg)
            page = next((t for t in targets if t['type'] == 'page'), None)
            if page:
                cdp = CDP(page['webSocketDebuggerUrl']); cdp.activate(); break
        except Exception: pass
    if not cdp:
        print('FATAL: no CDP page target'); cleanup(server, edge_p, tmp); sys.exit(2)

    try:
        cdp.eval('location.href="http://127.0.0.1:%d/"' % port)
        cdp.wait_ready()
        time.sleep(2)

        # ---- A 静态向导页 ----
        check('A1 五棵单树卡', cdp.eval("document.querySelectorAll('.check-item').length") >= 5,
              str(cdp.eval("document.querySelectorAll('.check-item').length")))
        check('A2 开始体检按钮在', cdp.eval("!!document.querySelector('#btn-run')"))
        check('A3 版本串 v1.7.1', 'v1.7.1' in str(cdp.eval("document.querySelector('.ver-chip')?.textContent || document.body.innerText")))
        check('A4 只读承诺文案', '只看、不动你电脑的任何设置' in str(cdp.eval('document.body.innerText')))
        # 首次启动引导：全新 profile（localStorage 空）→三步引导卡可见
        check('A5 首次启动引导卡在', cdp.eval("!!document.querySelector('#first-guide') && !document.querySelector('#first-guide').classList.contains('hidden')"))
        # 打磨轮：引导卡确认制——点「知道了」立即收起并写键；清键还原让 C5 继续测跑批路径
        cdp.eval("document.getElementById('fg-got-it').click()")
        a6_ok = cdp.eval("document.querySelector('#first-guide').classList.contains('hidden')") is True             and cdp.eval("!!localStorage.getItem('diag-guided')") is True
        check('A6 引导卡知道了按钮', a6_ok)
        cdp.eval("localStorage.removeItem('diag-guided')")

        # ---- A7-A9 v1.6.1 多选组合（勾选交互；跑批仍走 C 段 API 直发不受影响） ----
        # 先取消「全面体检」联动（勾着时单树被禁改），再勾两棵 → 组合可跑
        cdp.eval("document.querySelector('#chk-all').click()")
        cdp.eval("[...document.querySelectorAll('.tree-item')].filter(el => ['network','bluescreen'].includes(el.dataset.tree)).forEach(el => el.querySelector('input').click())")
        a7_hint = str(cdp.eval("document.querySelector('#sel-hint')?.textContent || ''"))
        check('A7 两类组合可跑+组合提示', cdp.eval("!document.querySelector('#btn-run').disabled") is True and '组合' in a7_hint, a7_hint)
        # 只留一棵 → 单树语义不受多选改动影响
        cdp.eval("[...document.querySelectorAll('.tree-item input')].forEach(i => { if (i.checked) i.click() })")
        cdp.eval("[...document.querySelectorAll('.tree-item')].filter(el => el.dataset.tree==='network').forEach(el => el.querySelector('input').click())")
        a8_hint = str(cdp.eval("document.querySelector('#sel-hint')?.textContent || ''"))
        check('A8 单树提示不劣化', cdp.eval("!document.querySelector('#btn-run').disabled") is True and '这一类' in a8_hint, a8_hint)
        # 恢复「全面体检」默认态
        cdp.eval("document.querySelector('#chk-all').click()")
        check('A9 恢复全面体检默认态', cdp.eval("document.querySelector('#chk-all').checked") is True)

        # ---- A10-A16 v1.7.1 体验修批（进度条双图层 / ui\custom 静态层 / 运行选项行 / 组合提示） ----
        # 静态通路 custom 层优先：临时写 ui\custom\bg.jpg 哨兵 → /bg.jpg 应回哨兵 → 删除后回落包内 JPEG
        cust_dir = os.path.join(DIAG, 'ui', 'custom')
        os.makedirs(cust_dir, exist_ok=True)
        cust_file = os.path.join(cust_dir, 'bg.jpg')
        sent = b'UITEST-CUSTOM-SENTINEL-' + str(os.getpid()).encode()
        open(cust_file, 'wb').write(sent)
        try:
            with urllib.request.urlopen('http://127.0.0.1:%d/bg.jpg' % port, timeout=8) as r:
                got = r.read()
            check('A10 静态通路 custom 层优先', got == sent, 'got ' + str(got[:40]))
        finally:
            os.remove(cust_file)
        with urllib.request.urlopen('http://127.0.0.1:%d/bg.jpg' % port, timeout=8) as r:
            check('A11 custom 移除后回落包内原图', r.read()[:3] == b'\xff\xd8\xff')
        # 运行态进度条=双图层（流光在前+强调色色层在后）；只写流光层会整体顶掉色层（浅色白叠白隐形根因）
        pr = cdp.eval("(() => { const v = document.querySelector('#btn-run').closest('.view'); v.classList.add('running'); const cs = getComputedStyle(document.querySelector('.progress-fill')); const r = [cs.backgroundImage, cs.backgroundSize]; v.classList.remove('running'); return r; })()")
        check('A12 运行态进度条双图层(流光+色层)', isinstance(pr, list) and str(pr[0]).count('linear-gradient') >= 2
              and '110deg' in str(pr[0]) and str(pr[1]).replace(' ', '') == '220%100%,100%100%', str(pr)[:240])
        # 浅色主题强调色加深变体（v1.7.1 补齐六色）：blue 此前连规则都没有，回落亮蓝近白
        la = cdp.eval("(() => { const h = document.documentElement; const ot = h.dataset.theme; const oa = h.dataset.accent; h.dataset.theme = 'light'; h.dataset.accent = 'blue'; const a1 = getComputedStyle(h).getPropertyValue('--accent').trim(); h.dataset.accent = 'orange'; const a2 = getComputedStyle(h).getPropertyValue('--accent').trim(); h.dataset.theme = ot; h.dataset.accent = oa; return [a1, a2]; })()")
        check('A13 浅色 blue/orange 强调色加深变体', isinstance(la, list) and la[0] == '#0a6ebd' and la[1] == '#b45309', str(la))
        # 运行选项行：快速模式独立容器（在 run-opts 内、不在勾选格内）
        check('A14 快速模式独立运行选项行', cdp.eval("!!document.querySelector('#run-opts #chk-fast-item') && !document.querySelector('#check-grid #chk-fast-item')"))
        # 组合提示实时反映快速开关（全面体检勾选态下切换快速）
        cdp.eval("document.querySelector('#chk-fast').click()")
        a15_hint = str(cdp.eval("document.querySelector('#sel-hint')?.textContent || ''"))
        check('A15 全面+快速组合提示', '全面' in a15_hint and '快速模式' in a15_hint, a15_hint)
        cdp.eval("document.querySelector('#chk-fast').click()")
        a16_hint = str(cdp.eval("document.querySelector('#sel-hint')?.textContent || ''"))
        check('A16 取消快速后提示回全查口径', '全面' in a16_hint and '快速模式' not in a16_hint, a16_hint)

        # ---- B 页签交互 ----
        cdp.eval("document.querySelector('[data-view=\"repair\"]')?.click() || document.querySelectorAll('.tab')[2].click()")
        time.sleep(0.6)
        check('B1 修复中心激活', cdp.eval("document.querySelector('#view-repair')?.classList.contains('active')"))
        check('B2 三色分级文案', '直接代跑' in str(cdp.eval("document.querySelector('#view-repair').innerText")) and '逐项确认' in str(cdp.eval("document.querySelector('#view-repair').innerText")))
        # 默认主题=自动跟随系统（首次无记忆 → auto 激活且实际渲染=系统明暗）
        check('B3 主题默认跟随系统', cdp.eval("document.querySelector('[data-theme-opt=\"auto\"]').classList.contains('active')") is True
              and cdp.eval("document.documentElement.dataset.theme === (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')") is True)

        # ---- C mock 跑批全链 ----
        http_json('http://127.0.0.1:%d/api/start' % port, method='POST', body='{"tree":"network"}')
        done = False
        for _ in range(90):
            time.sleep(2)
            ev = http_json('http://127.0.0.1:%d/api/events?since=0' % port)
            if any(e.get('event') == 'done' for e in ev.get('events', [])):
                done = True; break
        check('C1 跑批完成(done事件)', done)
        # headless page timers may be throttled during the run - reload re-plays the event
        # buffer via the F5-restore path (server replays since=0 + pulls report), then render
        cdp.eval('location.reload()')
        cdp.wait_ready()
        time.sleep(2.5)
        results_txt = str(cdp.eval("document.querySelector('#view-results')?.innerText || ''"))
        check('C2 大结论横幅发现问题', '发现问题' in results_txt, results_txt[:120])
        check('C3 DNS 死地址人话名', '死地址' in results_txt or 'DNS' in results_txt, results_txt[:200])
        check('C4 零断点黑话', '断点' not in results_txt)
        # 跑过一轮体检后引导卡永久收起（localStorage diag-guided；reload 后仍隐藏）
        check('C5 跑批后引导卡收起', cdp.eval("document.querySelector('#first-guide')?.classList.contains('hidden')") is True
              and cdp.eval("!!localStorage.getItem('diag-guided')") is True)
        # 结果页「和上次比」摘要行（本次 vs 预塞 new 份 → 新增项文案）
        check('C6 和上次比摘要行', (lambda t: '和上次体检' in t and ('新冒出来' in t or '修好了' in t or '没有变化' in t))
              (str(cdp.eval("document.querySelector('#delta-bar')?.innerText || ''"))))
        # 「先修这个」：根因关联行动区（本场景 DNS 三项 FAIL → dns_side 规则命中 → 合并行动项）
        ff_txt = str(cdp.eval("document.querySelector('#first-fix')?.innerText || ''"))
        check('C7 先修这个行动区渲染', '先修这个' in ff_txt and 'DNS' in ff_txt, ff_txt[:160])
        check('C8 根因合并项出现', '一个方向' in ff_txt and '去处理' in ff_txt, ff_txt[:200])
        # 点「去处理」→ 跳修复中心「改为公共 DNS」卡（target.action=net_dns_public_set）
        cdp.eval("Array.from(document.querySelectorAll('#first-fix button')).find(b => b.textContent === '去处理')?.click()")
        time.sleep(1.2)
        rep_on = cdp.eval("document.querySelector('#view-repair')?.classList.contains('active')") is True
        card_on = cdp.eval("!!document.querySelector('.action-card[data-action-id=net_dns_public_set]')")
        check('C9 行动项跳转修复卡', rep_on and card_on)

        # ---- D 修复中心联动 ----
        cdp.eval("document.querySelectorAll('.tab')[2].click()")
        time.sleep(0.8)
        rep_txt = str(cdp.eval("document.querySelector('#view-repair').innerText"))
        check('D1 问题清单联动', '这轮查出来的问题' in rep_txt, rep_txt[:120])
        # 权威溯源：动作卡渲染「官方依据」链接（微软官方域 href）
        src_link = cdp.eval("(document.querySelector('.action-card .src-row a') || {}).href || ''")
        check('D2 官方依据链接在场', 'microsoft.com' in str(src_link), str(src_link))
        # launcher 组（「一键直达」+按钮=动词「打开」）：
        # 卡上不出现等级徽章「绿色 · 安全可自动修」（开窗类辅助动作零安全声明）
        la_txt = str(cdp.eval("document.querySelector('#view-repair').innerText"))
        la_cnt = cdp.eval("document.querySelectorAll('.launcher-grid .action-card').length")
        check('D3 一键直达区渲染', '一键直达系统窗口' in la_txt and la_cnt >= 5, 'cards=' + str(la_cnt))
        la_btn = str(cdp.eval("(document.querySelector('.launcher-grid .action-card button') || {}).textContent || ''")).strip()
        check('D4 launcher 按钮=打开', la_btn == '打开', repr(la_btn))
        la_badge = str(cdp.eval("document.querySelector('.launcher-grid .launcher-card')?.innerText || ''"))
        check('D5 launcher 卡零安全声明', '安全可自动修' not in la_badge and '怎么撤销' not in la_badge, la_badge[:80])

        # ---- E 历史对比（预塞两份+本轮跑批一份） ----
        cdp.eval("document.querySelector('[data-view=\"history\"]').click()")
        time.sleep(2.5)
        hist_txt = str(cdp.eval("document.querySelector('#view-history')?.innerText || ''"))
        hist_items = cdp.eval("document.querySelectorAll('.hist-item').length")
        check('E1 历史列表3份(预塞2+跑批1)', hist_items == 3, str(hist_items) + ' :: ' + hist_txt[:160])
        check('E2 趋势区渲染', '问题数趋势' in hist_txt)
        cmp_visible = cdp.eval("document.querySelector('#hist-compare-card')?.hidden === false")
        check('E3 对比卡可见(>=2份)', cmp_visible)
        if cmp_visible:
            cdp.eval("document.querySelector('#btn-compare').click()")
            time.sleep(1.2)
            cmp_txt = str(cdp.eval("document.querySelector('#cmp-out')?.innerText || ''"))
            check('E4 对比渲染问题数', '问题数' in cmp_txt and '改善' in cmp_txt, cmp_txt[:200])
            check('E5 死地址恶化/新增行', ('恶化' in cmp_txt or '新增' in cmp_txt) and '死地址' in cmp_txt, cmp_txt[:300])

        # ---- F 修复后感知（真实点击修复→自动快扫→对比卡） ----
        # 模拟修复生效：把 net_dns_public 的 mock 换回成功输出。修复前快照来自内存
        # S.reportPayload（FAIL 版），快扫 engine 会读新 mock → PASS → 感知卡出「改善」行。
        open(os.path.join(tmp, 'mocks', 'net_dns_public.txt'), 'w', encoding='utf-8').write(NSOKPUB)
        cdp.activate()  # E 段 reload 后生命周期可能重置，重新压 active 防轮询节流
        cdp.eval("document.querySelector('[data-view=\"repair\"]').click()")
        time.sleep(1.5)
        armed = cdp.eval("(() => { const cards = Array.from(document.querySelectorAll('.action-card')); " + \
                "const c = cards.find(x => (x.innerText || '').indexOf('刷新 DNS 缓存') >= 0); " + \
                "if (!c) return 'NO-CARD'; const b = c.querySelector('button.act-run') || c.querySelector('button'); " + \
                "if (!b) return 'NO-BTN'; b.click(); return 'ARMED'; })()")
        clicked = 'NO-CARD'
        if armed == 'ARMED':
            # requires_admin 动作：先弹「管理员确认」modal，再点「执行」才真正 startRepairRun
            for _ in range(10):
                time.sleep(0.5)
                if cdp.eval("!document.querySelector('#repair-modal')?.classList.contains('hidden')"):
                    cdp.eval("document.getElementById('rm-go').click()")
                    clicked = 'CLICKED'
                    break
            else:
                clicked = 'NO-MODAL'
        check('F1 找到并点击修复卡', clicked == 'CLICKED', str(armed) + '/' + str(clicked))
        if clicked == 'CLICKED':
            sense_on = False
            for _ in range(36):
                time.sleep(5)
                if cdp.eval("!!document.querySelector('#fix-sense-card')"):
                    sense_on = True; break
            check('F2 修复后感知卡出现', sense_on)
            if sense_on:
                fs_txt = str(cdp.eval("document.querySelector('#fix-sense-card').innerText"))
                check('F3 感知对比渲染', '问题数' in fs_txt and '改善' in fs_txt, fs_txt[:250])
                check('F4 再查一次按钮在', '再查一次' in fs_txt)
            # 修复小史——修完切回修复中心，历史区在场且含本次动作
            cdp.eval("document.querySelector('[data-view=\"repair\"]').click()")
            time.sleep(1.2)
            rh_txt = str(cdp.eval("document.querySelector('#repair-hist')?.textContent || ''"))
            check('F5 修复小史含本次动作', '刷新 DNS 缓存' in rh_txt and '修好了' in rh_txt, rh_txt[:160])

        # ---- G 版本更新弹窗（打磨轮：老用户升级后弹一次，知道了后不再弹） ----
        cdp.eval("localStorage.setItem('diag-guided','1'); localStorage.removeItem('diag-seen-ver')")
        cdp.eval('location.reload()')
        cdp.wait_ready(); time.sleep(2)
        g1 = cdp.eval("!document.querySelector('#update-modal').classList.contains('hidden')") is True             and '更新到' in str(cdp.eval("document.querySelector('#um-title')?.textContent || ''"))
        check('G1 升级用户更新弹窗在', g1)
        cdp.eval("document.getElementById('um-ok').click()")
        g2 = cdp.eval("document.querySelector('#update-modal').classList.contains('hidden')") is True             and cdp.eval("localStorage.getItem('diag-seen-ver')") is not None
        cdp.eval('location.reload()'); cdp.wait_ready(); time.sleep(1.5)
        g3 = cdp.eval("document.querySelector('#update-modal').classList.contains('hidden')") is True
        check('G2 知道了后收起且不再弹', g2 and g3)

        # ---- H 语言切换（1025 i18n 轮：外观菜单→语言行；localStorage diag-lang 记忆；默认 zh-CN 行为不变） ----
        # 切英文：点外观按钮开菜单 → 点 English seg → applyLang 写 localStorage 并 reload → 页签/按钮变英文
        cdp.eval("document.getElementById('btn-appearance').click()")
        time.sleep(0.4)
        lang_btn = cdp.eval("!!document.querySelector('#lang-seg [data-lang-opt=\"en-US\"]')")
        cdp.eval("document.querySelector('#lang-seg [data-lang-opt=\"en-US\"]').click()")
        cdp.wait_ready(); time.sleep(2.5)  # reload + init
        h1 = 'Checkup Wizard' in str(cdp.eval("document.querySelector('.tab[data-view=\"wizard\"] .tab-full')?.textContent || ''"))
        check('H1 切英文页签变 Checkup Wizard', lang_btn and h1, 'lang_btn=' + str(lang_btn))
        # 前面 C/F 段跑完一轮后按钮处于「Run Again」态——点结果页「Run Again」回 idle，开始按钮才回到 Start Checkup
        cdp.eval("document.getElementById('btn-again')?.click()")
        time.sleep(1)
        check('H2 开始按钮变 Start Checkup', cdp.eval("document.querySelector('#btn-run')?.textContent") == 'Start Checkup',
              str(cdp.eval("document.querySelector('#btn-run')?.textContent")))
        # 切回中文：同一路径点中文 seg
        cdp.eval("document.getElementById('btn-appearance').click()")
        time.sleep(0.4)
        cdp.eval("document.querySelector('#lang-seg [data-lang-opt=\"zh-CN\"]').click()")
        cdp.wait_ready(); time.sleep(2.5)
        cdp.eval("document.getElementById('btn-again')?.click()")
        time.sleep(1)
        h3 = cdp.eval("document.querySelector('.tab[data-view=\"wizard\"] .tab-full')?.textContent") == '体检向导'             and cdp.eval("document.querySelector('#btn-run')?.textContent") == '开始体检'
        check('H3 切回中文恢复', h3, str(cdp.eval("document.querySelector('#btn-run')?.textContent")))
        # 重启记忆：再 reload 一次，语言保持中文（localStorage diag-lang=zh-CN）
        cdp.eval('location.reload()')
        cdp.wait_ready(); time.sleep(2)
        h4 = cdp.eval("document.querySelector('.tab[data-view=\"wizard\"] .tab-full')?.textContent") == '体检向导'             and str(cdp.eval("localStorage.getItem('diag-lang') || ''")) == 'zh-CN'
        check('H4 localStorage 语言记忆保持', h4, str(cdp.eval("localStorage.getItem('diag-lang')")))

        # ---- I 建议正文英译（1026 方案 B M1：mock 跑批→切英文→详情建议=英文模板+detail 回填） ----
        def sug_of(check_id):
            # headless 页在 API 驱动跑批期间会被节流（C 段同款坑）：先 reload 走启动恢复路径
            # 拉最新报告，再点问题清单项读建议框
            cdp.eval('location.reload()'); cdp.wait_ready(); time.sleep(2.5)
            cdp.activate()
            cdp.eval("document.querySelector('.tab[data-view=\"results\"]').click()")
            cdp.eval("document.querySelector('.pc-item[data-check=\"%s\"]')?.click()" % check_id)
            time.sleep(0.4)
            return str(cdp.eval("document.querySelector('#sug-box')?.innerText || ''"))
        def run_tree(tree_id, full=False):
            # 必须=轮询 /api/events：server 的 jsonReport 指针与 running→done 收割都挂在
            # Read-NewEvents（events 通路）上，只轮 /api/report 会永远等不到新报告；
            # 且事件缓冲每轮清空（Start-Engine 内 events=@()），开跑后缓冲里的 done 必属本轮。
            # full=True=全树跑完不断点：M2 起安全/性能树有多项 FAIL mock，快速模式断点
            # 即停会把后排层截成 SKIPPED（I2c/I3c/I3d 读不到项的根因）。
            body = json.dumps({'tree': tree_id, 'full': bool(full)})
            http_json('http://127.0.0.1:%d/api/start' % port, method='POST', body=body)
            for _ in range(120):
                time.sleep(2)
                ev = http_json('http://127.0.0.1:%d/api/events?since=0' % port)
                if ev.get('state') == 'done' and any(e.get('event') == 'done' for e in ev.get('events', [])):
                    return True
            return False
        # I1 网络树报告（C 段跑批仍在 server 内存）：切英文→死地址建议=英文模板+死地址列表+命令
        cdp.eval("document.getElementById('btn-appearance').click()")
        time.sleep(0.4)
        cdp.eval("document.querySelector('#lang-seg [data-lang-opt=\"en-US\"]').click()")
        cdp.wait_ready(); time.sleep(2.5)
        cdp.activate()
        i1 = sug_of('net_dns_deadaddr')
        check('I1 en 死地址建议=英文模板+死地址回填',
              ('192.168.137.1' in i1) and ('netsh interface ip set dns' in i1) and ('223.5.5.5' in i1)
              and ('【' not in i1) and ('死地址' not in i1), i1[:120])
        # I1b 渐进覆盖回退护栏（M2 全量翻完无未翻项：改运行时删模板键，验证回退仍工作；不动主仓文件）
        cdp.eval('location.reload()'); cdp.wait_ready(); time.sleep(2.5); cdp.activate()
        cdp.eval("delete window.I18N_EN.suggestions['net_dns_default_timeout']")
        cdp.eval("document.querySelector('.tab[data-view=\"results\"]').click()")
        cdp.eval("document.querySelector('.pc-item[data-check=\"net_dns_default\"]')?.click()")
        time.sleep(0.4)
        i1b = str(cdp.eval("document.querySelector('#sug-box')?.innerText || ''"))
        check('I1b 缺模板键回退中文原文（运行时删键）', ('【' in i1b), i1b[:100])
        # I2 安全树跑批→UAC 建议英文（纯静态模板）
        check('I2 安全树跑批完成', run_tree('security', full=True))
        time.sleep(1.5)
        i2 = sug_of('sec_uac_level')
        check('I2b en UAC 建议=英文（useraccountcontrolsettings 路径在场）',
              ('useraccountcontrolsettings' in i2) and ('Never notify' in i2) and ('【' not in i2), i2[:120])
        # I2c M2 抽验：defender 状态静态模板（安全树 mock 已在，同一次跑批带出）
        i2c = sug_of('sec_defender_status')
        check('I2c en Defender 状态建议=英文（Real-time protection 指引）',
              ('Real-time protection' in i2c) and ('Virus & threat protection' in i2c) and ('【' not in i2c), i2c[:120])
        # I3 性能树跑批（2×Warning）→慢启动标记分支英文+数字回填
        check('I3 性能树跑批完成', run_tree('performance', full=True))
        time.sleep(1.5)
        i3 = sug_of('pf_boot_duration')
        check('I3b en 开机建议=marks 分支（flagged 2 of the last 5）',
              ('flagged 2 of the last 5 boots' in i3) and ('Ctrl+Shift+Esc' in i3) and ('【' not in i3), i3[:120])
        # I3c M2 抽验：磁盘空间=合并键+嵌套 disks 真对象派生回填（engine 升 -Depth 12 后数组对象直达）
        i3c = sug_of('pf_disk_space')
        check('I3c en 磁盘空间建议=嵌套 disks 回填（11.2GB (4.7%)）',
              ('11.2GB' in i3c) and ('4.7%' in i3c) and ('Storage Sense' in i3c) and ('【' not in i3c), i3c[:120])
        # I3d M2 抽验：内存 lowmem 变体分支（physicalGB<4 走 lowmem 键）+直通占位符回填
        i3d = sug_of('pf_memory_pressure')
        check('I3d en 内存建议=lowmem 变体分支（2GB below the official minimum）',
              ('2GB' in i3d) and ('4GB' in i3d) and ('【' not in i3d), i3d[:120])
        # I4 换 avg mock 再跑性能树→均值分支：75 秒换算（78000+72000 → avg 75000ms → 75s）
        open(os.path.join(tmp, 'mocks', 'pf_boot_duration.txt'), 'w', encoding='utf-8').write(
            '10-20 | Information | 78000\n10-19 | Information | 72000')
        check('I4 性能树二跑完成', run_tree('performance', full=True))
        time.sleep(1.5)
        i4 = sug_of('pf_boot_duration')
        check('I4b en 开机建议=avg 分支（averaged 75 seconds）',
              ('averaged 75 seconds' in i4) and ('60-second' in i4) and ('【' not in i4), i4[:120])
        # I5 中英数字一致：同一份 avg 报告切回中文，建议含「75 秒」（与 I4b 同源 detail）
        cdp.eval("document.getElementById('btn-appearance').click()")
        time.sleep(0.4)
        cdp.eval("document.querySelector('#lang-seg [data-lang-opt=\"zh-CN\"]').click()")
        cdp.wait_ready(); time.sleep(2.5)
        i5 = sug_of('pf_boot_duration')
        check('I5 zh 同报告均值 75 秒（数字中英一致）', '75 秒' in i5 and '60 秒' in i5, i5[:120])

        # ---- J 修复卡英文收口（1026 方案 B·M3：三色常驻卡抽验+确认 modal+console.warn 真页清零） ----
        # warn 收集：新文档注入 hook（applyLang 切语言会 reload，hook 每次加载重挂）；
        # 全量 33 卡×全字段的对齐由 tests/i18n_actions_check.mjs（run_tests ⑧ 节）静态保证，
        # 本段=真页面实证渲染面（launcher 区+commons 折叠+命中卡+确认 modal）。
        cdp._send('Page.addScriptToEvaluateOnNewDocument', {'source':
            "window.__i18nWarns=[]; const __w=console.warn.bind(console);"
            " console.warn=function(){ const s=Array.from(arguments).join(' ');"
            " if(s.indexOf('[i18n]')>=0) window.__i18nWarns.push(s); __w.apply(null,arguments); };"})
        cdp.eval("document.getElementById('btn-appearance').click()")
        time.sleep(0.4)
        cdp.eval("document.querySelector('#lang-seg [data-lang-opt=\"en-US\"]').click()")
        cdp.wait_ready(); time.sleep(2.5); cdp.activate()
        cdp.eval("document.querySelector('[data-view=\"repair\"]').click()")
        time.sleep(1.2)
        # commons 折叠与卡内 steps 折叠全部展开，innerText 才含步骤文本
        cdp.eval("document.querySelectorAll('#repair-list details').forEach(d=>{d.open=true;})")
        time.sleep(0.5)
        # J1 红卡=commons 常驻 net_hosts_clean：英文名+步骤英文教学+零【】中文标记
        j1 = str(cdp.eval("(document.querySelector('.action-card[data-action-id=net_hosts_clean]')||{}).innerText || ''"))
        check('J1 en 红卡 hosts 清卡=英文（Step 1..3 教学在场）',
              ('Manual hosts cleanup' in j1) and ('Step 1: back up + open hosts' in j1)
              and ('Step 3: flush the cache' in j1) and ('【' not in j1), j1[:160])
        # J2 黄卡=commons 常驻 net_wininet_proxy_off：英文名+影响栏英文
        j2 = str(cdp.eval("(document.querySelector('.action-card[data-action-id=net_wininet_proxy_off]')||{}).innerText || ''"))
        check('J2 en 黄卡关代理=英文（Turn off the user-level proxy）',
              ('Turn off the user-level proxy' in j2) and ('【' not in j2), j2[:160])
        # J3 绿卡=launcher 区常驻 open_devmgr：英文名（launcher 卡精简面）
        j3 = str(cdp.eval("(document.querySelector('.launcher-grid .action-card[data-action-id=open_devmgr]')||{}).innerText || ''"))
        check('J3 en 绿卡设备管理器=英文（Device Manager）',
              ('Device Manager' in j3) and ('【' not in j3), j3[:120])
        # J4 绿卡 admin 确认 modal：点执行→showGreenConfirmModal→fillModalRows（rollback_note 真消费点）
        # →三行+步骤+回滚包附注英文+行内标点半角→取消不真跑
        cdp.eval("(() => { const b = document.querySelector('.action-card[data-action-id=sys_time_sync] button.act-run'); if (b) b.click(); return !!b; })()")
        time.sleep(0.8)
        modal_on = cdp.eval("!document.querySelector('#repair-modal')?.classList.contains('hidden')")
        j4 = str(cdp.eval("(document.getElementById('rm-rows')||{}).innerText || ''"))
        check('J4 en 确认 modal=英文（回滚包附注 rollback_note 译文在场+标点半角）',
              modal_on and ('No rollback needed: syncing the clock' in j4) and ('【' not in j4)
              and ('（' not in j4) and ('：' not in j4), j4[:200])
        cdp.eval("document.getElementById('rm-cancel')?.click()")
        time.sleep(0.5)
        # J5 真页 console.warn 扫描：[i18n] missing action 类告警清零
        j5 = cdp.eval("(window.__i18nWarns||[]).filter(s=>s.indexOf('missing action')>=0).length")
        j5_all = cdp.eval("(window.__i18nWarns||[]).length")
        check('J5 en 修复中心 console.warn 清零（missing action 类）',
              j5 == 0, 'missing-action=' + str(j5) + ' all-i18n-warns=' + str(j5_all) + ' :: '
              + str(cdp.eval("(window.__i18nWarns||[]).slice(0,3)")))
        # J6 手工修复条目标题方括号随语言切换（1026 flash 验收揪出的【】硬编码漏网点）
        # C 段 network 场景 net_dns_gateway_proxy FAIL 无动作卡匹配 → rest 区条目常驻
        j6 = str(cdp.eval("Array.from(document.querySelectorAll('.repair-item .ri-title')).map(x=>x.textContent).join(' | ') || ''"))
        check('J6 en 手工修复条目标题=[Tree] 式半角方括号',
              (j6 == '' or ('[' in j6 and '【' not in j6)), j6[:160])
        # 收尾：切回中文，H 段语义闭环（后续无段依赖语言态，恢复默认态收尾）
        cdp.eval("document.getElementById('btn-appearance').click()")
        time.sleep(0.4)
        cdp.eval("document.querySelector('#lang-seg [data-lang-opt=\"zh-CN\"]').click()")
        cdp.wait_ready(); time.sleep(2)

        passing = sum(1 for _, ok in RESULTS if ok)
        print('\n================ UI-TESTS: %d/%d PASS ================' % (passing, len(RESULTS)))
        rc = 0 if passing == len(RESULTS) else 1
    finally:
        try: http_json('http://127.0.0.1:%d/api/bye' % port, timeout=3)
        except Exception: pass
        time.sleep(3)
        cleanup(server, edge_p, tmp)
    sys.exit(rc)

def cleanup(server, edge_p, tmp):
    for p in (edge_p, server):
        try: p.kill()
        except Exception: pass
    time.sleep(1)
    shutil.rmtree(tmp, ignore_errors=True)

if __name__ == '__main__':
    main()

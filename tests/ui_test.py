# -*- coding: utf-8 -*-
"""
diag UI 自动测试套件（1024 轮3 固化）：CDP 驱动 headless Edge 的 DOM 断言回归网。
覆盖：A 静态向导页 / B 页签交互 / C mock 跑批全链（dns_deadaddr 断点场景）/ D 修复中心联动。
跑法：python -X utf8 tests/ui_test.py   （退出码 0=全过）
工艺：起 server(-MockDir)+headless Edge(随机调试端口)→CDP evaluate 断言→bye 收尾零残留。
"""
import json, os, shutil, subprocess, sys, time, urllib.request

DIAG = r'F:\Zcode genius\diag'
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
    'net_dns_public': NSOKPUB,
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

    # 1) server with mocks
    server = subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        os.path.join(DIAG, 'server.ps1'), '-NoBrowser', '-PortFile', portfile, '-MockDir', os.path.join(tmp, 'mocks')],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
        check('A3 版本串 v1.2.0', 'v1.2.0' in str(cdp.eval("document.querySelector('.ver-chip')?.textContent || document.body.innerText")))
        check('A4 只读承诺文案', '只看、不动你电脑的任何设置' in str(cdp.eval('document.body.innerText')))

        # ---- B 页签交互 ----
        cdp.eval("document.querySelector('[data-view=\"repair\"]')?.click() || document.querySelectorAll('.tab')[2].click()")
        time.sleep(0.6)
        check('B1 修复中心激活', cdp.eval("document.querySelector('#view-repair')?.classList.contains('active')"))
        check('B2 三色分级文案', '直接代跑' in str(cdp.eval("document.querySelector('#view-repair').innerText")) and '逐项确认' in str(cdp.eval("document.querySelector('#view-repair').innerText")))

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

        # ---- D 修复中心联动 ----
        cdp.eval("document.querySelectorAll('.tab')[2].click()")
        time.sleep(0.8)
        rep_txt = str(cdp.eval("document.querySelector('#view-repair').innerText"))
        check('D1 问题清单联动', '这轮查出来的问题' in rep_txt, rep_txt[:120])

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

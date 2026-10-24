# -*- coding: utf-8 -*-
# 一次性诊断探针：mock 跑批后 dump 修复中心实际渲染的 FAIL 项与动作卡名单（跑完即删）
import json, os, shutil, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import ui_test as U

tmp = os.path.join(os.environ['TEMP'], 'diag-probe-' + str(os.getpid()))
shutil.rmtree(tmp, ignore_errors=True)
os.makedirs(os.path.join(tmp, 'mocks'), exist_ok=True)
for k, v in U.MOCKS.items():
    open(os.path.join(tmp, 'mocks', k + '.txt'), 'w', encoding='utf-8').write(v)
portfile = os.path.join(tmp, 'port.tmp')
env = dict(os.environ)
env['DIAG_DATA_ROOT'] = os.path.join(tmp, 'dataroot')
os.makedirs(env['DIAG_DATA_ROOT'], exist_ok=True)
server = subprocess.Popen(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    os.path.join(U.DIAG, 'server.ps1'), '-NoBrowser', '-PortFile', portfile, '-MockDir', os.path.join(tmp, 'mocks')],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
port = 0
for _ in range(60):
    if os.path.exists(portfile):
        try: port = int(open(portfile).read().strip()); break
        except Exception: pass
    time.sleep(0.5)
assert port, 'no port'
for _ in range(30):
    try: U.http_json('http://127.0.0.1:%d/api/meta' % port); break
    except Exception: time.sleep(0.5)

edge_exe = os.path.expandvars(r'%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe')
dbg = 19444
edge_p = subprocess.Popen([edge_exe, '--headless=new', '--remote-debugging-port=%d' % dbg,
    '--user-data-dir=' + os.path.join(tmp, 'edge-profile'), '--no-first-run', 'about:blank'],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
cdp = None
for _ in range(40):
    time.sleep(0.5)
    try:
        targets = U.http_json('http://127.0.0.1:%d/json/list' % dbg)
        page = next((t for t in targets if t['type'] == 'page'), None)
        if page:
            cdp = U.CDP(page['webSocketDebuggerUrl']); cdp.activate(); break
    except Exception: pass
assert cdp, 'no cdp'
try:
    cdp.eval('location.href="http://127.0.0.1:%d/"' % port)
    cdp.wait_ready(); time.sleep(2)
    # mock 跑批 network
    U.http_json('http://127.0.0.1:%d/api/start' % port, method='POST', body='{"tree":"network"}')
    for _ in range(90):
        time.sleep(2)
        ev = U.http_json('http://127.0.0.1:%d/api/events?since=0' % port)
        if any(e.get('event') == 'done' for e in ev.get('events', [])): break
    cdp.eval('location.reload()'); cdp.wait_ready(); time.sleep(2.5)
    # 切 repair
    cdp.eval("document.querySelector('[data-view=\"repair\"]').click()")
    time.sleep(1.5)
    fails = cdp.eval("(() => { const out=[]; (S.reportPayload?.report?.trees||[]).forEach(t=>(t.layers||[]).forEach(l=>(l.checks||[]).forEach(c=>{ if(c.status!=='PASS') out.push(c.name+'='+c.status+' sug='+(c.suggestion?'Y':'N')); }))); return out.join(' | ') || 'EMPTY'; })()")
    print('REPORT NON-PASS:', fails)
    nacts = cdp.eval("Array.from(document.querySelectorAll('#repair-list .action-card')).map(c=>(c.querySelector('b')?.textContent||'?')+' [checks='+(c.dataset.checks||'')+']').join(' | ') || 'NONE'")
    print('ACTION CARDS:', nacts)
    secs = cdp.eval("Array.from(document.querySelectorAll('#repair-list .rep-sec')).map(x=>x.textContent).join(' | ') || 'NONE'")
    print('SECTIONS:', secs)
    items = cdp.eval("Array.from(document.querySelectorAll('#repair-list .repair-item')).map(x=>x.dataset.check).join(' | ') || 'NONE'")
    print('REPAIR ITEMS(no action):', items)
    nra = cdp.eval("(S.repairActions||[]).length")
    print('S.repairActions count:', nra)
finally:
    try: U.http_json('http://127.0.0.1:%d/api/bye' % port, timeout=3)
    except Exception: pass
    time.sleep(3)
    U.cleanup(server, edge_p, tmp)

import Foundation

/// 电脑浏览器访问 `/__admin/` 时显示的页面
enum AdminPage {
    /// 两个页面共用的样式
    private static let baseStyle = #"""
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#ffffff;--fg:#1d1d1f;--muted:#6e6e73;--line:#d2d2d7;--soft:#f5f5f7;--fill:#e8e8ed;
--accent:#0071e3;--accentSoft:rgba(0,113,227,.1);--ok:#1d8a3a;--danger:#e30000;--radius:18px}
@media(prefers-color-scheme:dark){:root{--bg:#000000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#a1a1a6;--line:#38383a;--soft:#2c2c2e;--fill:#3a3a3c;
--accent:#2997ff;--accentSoft:rgba(41,151,255,.16);--ok:#30d158;--danger:#ff453a}}
*{box-sizing:border-box}
html,body{margin:0}
body{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue","PingFang SC","Microsoft YaHei",sans-serif;background:var(--bg);color:var(--fg);-webkit-font-smoothing:antialiased;letter-spacing:-.01em}
button{font:inherit;cursor:pointer;border:0;background:none;color:inherit}
.btn{display:inline-flex;align-items:center;gap:6px;font-size:14px;font-weight:500;border-radius:980px;padding:8px 16px;background:var(--accent);color:#fff;transition:opacity .15s;text-decoration:none}
.btn:hover{opacity:.88}.btn:active{opacity:.75}
.btn.ghost{background:var(--fill);color:var(--fg)}
.btn.small{padding:6px 13px;font-size:13px}
.btn svg{width:15px;height:15px}
.brand{display:flex;align-items:center;gap:10px;font-weight:600;font-size:17px}
.logo{width:30px;height:30px;border-radius:8px;background:var(--fg);display:grid;place-items:center;color:var(--bg)}
.logo svg{width:17px;height:17px}
#toast{position:fixed;left:50%;bottom:28px;transform:translate(-50%,20px);opacity:0;background:rgba(29,29,31,.92);color:#fff;padding:11px 20px;border-radius:980px;font-size:14px;max-width:min(90vw,520px);transition:.25s;pointer-events:none;z-index:50}
#toast.show{opacity:1;transform:translate(-50%,0)}
"""#

    // MARK: - 配对页

    /// 未配对的浏览器看到的页面：输入手机上显示的 6 位配对码
    static let pairingHTML = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>与 iPhone 配对 · 本地服务器</title>
<style>
"""# + baseStyle + #"""
body{min-height:100vh;display:grid;place-items:center;padding:20px}
.card{width:100%;max-width:460px;background:var(--card);border-radius:24px;padding:44px 32px 32px;text-align:center}
.hero{width:64px;height:64px;margin:0 auto 22px;border-radius:18px;background:var(--fill);display:grid;place-items:center;color:var(--fg)}
.hero svg{width:36px;height:36px}
h1{font-size:32px;font-weight:700;letter-spacing:-.03em;margin:0 0 10px}
p.lead{color:var(--muted);font-size:17px;line-height:1.5;margin:0 0 30px}
.pin{display:flex;justify-content:center;gap:8px;margin-bottom:6px}
.pin input{width:50px;height:60px;border-radius:12px;border:1px solid var(--line);background:var(--bg);color:var(--fg);font-size:26px;font-weight:700;text-align:center;font-variant-numeric:tabular-nums;transition:border-color .15s,box-shadow .15s}
.pin input:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 4px var(--accentSoft)}
.pin .gap{width:8px}
.pin.shake{animation:shake .4s}
.pin.ok input{border-color:var(--ok);color:var(--ok)}
@keyframes shake{20%,60%{transform:translateX(-8px)}40%,80%{transform:translateX(8px)}}
#status{min-height:22px;font-size:13px;color:var(--muted);margin:14px 0 18px}
#status.err{color:var(--danger)}#status.ok{color:var(--ok)}
.foot{display:flex;justify-content:center;gap:8px;flex-wrap:wrap}
.steps{text-align:left;border-top:1px solid var(--line);padding-top:20px;margin-top:26px;font-size:13px;color:var(--muted);line-height:1.8}
.steps b{color:var(--fg)}
@media(max-width:400px){.pin input{width:40px;height:50px;font-size:22px}}
</style>
</head>
<body>
<div class="card">
  <div class="hero"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="2" width="10" height="20" rx="2.5"/><path d="M11 18h2"/></svg></div>
  <h1>与 iPhone 配对</h1>
  <p class="lead">手机上的「本地服务器」已弹出 6 位配对码，<br>在下方输入即可开始管理文件。</p>
  <div class="pin" id="pin">
    <input inputmode="numeric" autocomplete="one-time-code" maxlength="6" aria-label="第 1 位">
    <input inputmode="numeric" maxlength="6" aria-label="第 2 位">
    <input inputmode="numeric" maxlength="6" aria-label="第 3 位">
    <span class="gap"></span>
    <input inputmode="numeric" maxlength="6" aria-label="第 4 位">
    <input inputmode="numeric" maxlength="6" aria-label="第 5 位">
    <input inputmode="numeric" maxlength="6" aria-label="第 6 位">
  </div>
  <div id="status">等待输入配对码…</div>
  <div class="foot"><button class="btn ghost small" id="resend">没有看到配对码？再通知一次</button></div>
  <div class="steps">
    没有弹出配对码？请确认：<br>
    · 手机上的 <b>本地服务器</b> App 正在运行<br>
    · 在 App 的 <b>服务</b> 页 › <b>电脑管理</b> 中也能看到当前配对码<br>
    · 配对一次后，这个浏览器以后会直接进入
  </div>
</div>
<div id="toast"></div>
<script>
const boxes = [...document.querySelectorAll('#pin input')];
const pinBox = document.getElementById('pin');
const statusEl = document.getElementById('status');
let busy = false;

function setStatus(text, cls) { statusEl.textContent = text; statusEl.className = cls || ''; }
function digits() { return boxes.map(b => b.value).join(''); }
function clear() { boxes.forEach(b => b.value = ''); boxes[0].focus(); }

function fill(text, start) {
  const d = text.replace(/\D/g, '');
  for (let k = 0; k < d.length && start + k < boxes.length; k++) boxes[start + k].value = d[k];
  boxes[Math.min(start + d.length, boxes.length - 1)].focus();
  maybeSubmit();
}

boxes.forEach((box, i) => {
  box.addEventListener('input', () => {
    const v = box.value.replace(/\D/g, '');
    if (v.length > 1) { box.value = ''; fill(v, i); return; }
    box.value = v;
    if (v && i < boxes.length - 1) boxes[i + 1].focus();
    maybeSubmit();
  });
  box.addEventListener('keydown', e => {
    if (e.key === 'Backspace' && !box.value && i > 0) { e.preventDefault(); boxes[i - 1].value = ''; boxes[i - 1].focus(); }
    else if (e.key === 'ArrowLeft' && i > 0) boxes[i - 1].focus();
    else if (e.key === 'ArrowRight' && i < boxes.length - 1) boxes[i + 1].focus();
  });
  box.addEventListener('paste', e => {
    const t = (e.clipboardData || window.clipboardData).getData('text') || '';
    if (t.replace(/\D/g, '')) { e.preventDefault(); fill(t, 0); }
  });
  box.addEventListener('focus', () => box.select());
});

async function post(name, body) {
  const r = await fetch('/__admin/api/' + name, {method: 'POST', headers: {'X-LocalServer': '1'}, body: body || ''});
  const j = await r.json().catch(() => ({}));
  return {r, j};
}

async function maybeSubmit() {
  const pin = digits();
  if (pin.length !== boxes.length || busy) return;
  busy = true;
  setStatus('正在配对…');
  try {
    const {r, j} = await post('pair', pin);
    if (r.ok) {
      pinBox.classList.add('ok');
      setStatus('配对成功，正在进入…', 'ok');
      setTimeout(() => location.reload(), 600);
      return;
    }
    pinBox.classList.remove('shake'); void pinBox.offsetWidth; pinBox.classList.add('shake');
    setStatus(j.error || ('配对失败（' + r.status + '）'), 'err');
    clear();
  } catch (_) {
    setStatus('无法连接手机，请确认 App 正在运行', 'err');
  }
  busy = false;
}

async function requestPairing(manual) {
  try {
    const {j} = await post('pair-request');
    if (j.paired) { location.reload(); return; }
    if (manual) { const t = document.getElementById('toast'); t.textContent = '已通知手机，请查看配对码'; t.classList.add('show'); setTimeout(() => t.classList.remove('show'), 2200); }
  } catch (_) {
    setStatus('无法连接手机，请确认 App 正在运行', 'err');
  }
}
document.getElementById('resend').onclick = () => requestPairing(true);
requestPairing(false);
boxes[0].focus();
</script>
</body>
</html>
"""#

    // MARK: - 管理页

    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>文件管理 · 本地服务器</title>
<style>
"""# + baseStyle + #"""
header{position:sticky;top:0;z-index:10;background:var(--bg);backdrop-filter:saturate(180%) blur(20px);-webkit-backdrop-filter:saturate(180%) blur(20px);background:color-mix(in srgb,var(--bg) 82%,transparent);border-bottom:1px solid var(--line)}
.bar{max-width:1120px;margin:0 auto;padding:12px 22px;display:flex;align-items:center;gap:10px}
.bar .spacer{flex:1}
.brand small{display:block;font-weight:400;font-size:12px;color:var(--muted)}
main{max-width:1120px;margin:0 auto;padding:28px 22px 96px;display:grid;grid-template-columns:320px 1fr;gap:22px;align-items:start}
@media(max-width:880px){main{grid-template-columns:1fr}}
.card{background:var(--card);border-radius:var(--radius);padding:22px}
.card h2{font-size:19px;font-weight:600;letter-spacing:-.02em;margin:0 0 16px;display:flex;align-items:center;gap:8px}
.card h2 .count{font-size:12px;font-weight:500;color:var(--muted);background:var(--fill);border-radius:980px;padding:2px 8px}
.side{display:flex;flex-direction:column;gap:22px;position:sticky;top:78px}
@media(max-width:880px){.side{position:static}}
#drop{border:1.5px dashed var(--line);border-radius:14px;padding:28px 16px;text-align:center;transition:.2s;background:var(--bg)}
#drop.over{border-color:var(--accent);background:var(--accentSoft)}
#drop .icon{width:48px;height:48px;margin:0 auto 12px;border-radius:50%;background:var(--fill);color:var(--fg);display:grid;place-items:center}
#drop .icon svg{width:24px;height:24px}
#drop p{margin:0 0 14px;color:var(--muted);font-size:13px;line-height:1.6}
#drop p b{color:var(--fg);font-size:15px;font-weight:600}
.row{display:flex;gap:8px;justify-content:center;flex-wrap:wrap}
.opt{display:flex;align-items:center;gap:8px;margin-top:14px;font-size:13px;color:var(--muted);cursor:pointer;user-select:none}
.opt input{accent-color:var(--accent);width:16px;height:16px}
#queue{display:flex;flex-direction:column;gap:12px;max-height:340px;overflow:auto}
.q{display:grid;grid-template-columns:1fr auto;gap:4px 10px;align-items:center;font-size:13px}
.q .nm{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.q .st{font-size:12px;color:var(--muted)}.q.done .st{color:var(--ok)}.q.fail .st{color:var(--danger)}
.q .track{grid-column:1/3;height:3px;background:var(--fill);border-radius:2px;overflow:hidden}
.q .fill{height:100%;width:0;background:var(--accent);transition:width .15s}
.q.done .fill{background:var(--ok)}.q.fail .fill{background:var(--danger);width:100%!important}
.empty-q{font-size:13px;color:var(--muted);text-align:center;padding:6px 0}
.toolbar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:10px;min-height:36px}
.crumbs{flex:1;min-width:160px;display:flex;flex-wrap:wrap;align-items:center;gap:2px;font-size:15px}
.crumbs a{color:var(--muted);text-decoration:none;cursor:pointer;padding:4px 8px;border-radius:8px}
.crumbs a:hover{background:var(--fill);color:var(--fg)}
.crumbs a.cur{color:var(--fg);font-weight:600}
.crumbs .sep{color:var(--line)}
.search{position:relative}
.search input{font:inherit;font-size:13px;padding:8px 14px 8px 32px;border-radius:980px;border:0;background:var(--fill);color:var(--fg);width:170px}
.search input:focus{outline:2px solid var(--accent)}
.search svg{position:absolute;left:11px;top:50%;transform:translateY(-50%);width:14px;height:14px;color:var(--muted)}
#selbar{display:none;align-items:center;gap:8px;flex-wrap:wrap;background:var(--accentSoft);border-radius:12px;padding:8px 10px 8px 14px;margin-bottom:10px}
#selbar.show{display:flex}
#selbar .n{flex:1;font-size:14px;font-weight:600;color:var(--accent)}
.head,.item{display:grid;grid-template-columns:28px 36px minmax(0,1fr) 84px 128px 40px;gap:10px;align-items:center;padding:8px 8px;border-radius:12px}
.head{font-size:12px;color:var(--muted);padding-top:2px;padding-bottom:6px}
.item{transition:background .12s}
.item:hover{background:var(--bg)}
.item.sel{background:var(--accentSoft)}
.ck{width:16px;height:16px;accent-color:var(--accent);cursor:pointer;margin:0}
.item .ic{width:36px;height:36px;border-radius:9px;display:grid;place-items:center;font-size:9px;font-weight:700;letter-spacing:.3px;color:var(--muted);background:var(--fill)}
.item .ic svg{width:18px;height:18px}
.item .ic.dir{color:var(--accent)}
.item .nm{min-width:0;display:flex;align-items:center;gap:8px}
.item .nm span.t{font-size:15px;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item .nm span.t:hover{color:var(--accent)}
.item .sz,.item .dt{font-size:12px;color:var(--muted);text-align:right;white-space:nowrap}
.more{width:32px;height:32px;border-radius:50%;display:grid;place-items:center;color:var(--muted)}
.more:hover{background:var(--fill);color:var(--fg)}
.more svg{width:18px;height:18px}
.tag{font-size:11px;font-weight:600;color:var(--muted);background:var(--fill);border-radius:980px;padding:2px 8px;white-space:nowrap}
.tag.off{color:var(--danger)}
.switch{position:relative;width:36px;height:22px;flex:none;cursor:pointer}
.switch input{opacity:0;width:0;height:0;position:absolute}
.switch span{position:absolute;inset:0;background:var(--line);border-radius:980px;transition:.2s}
.switch span:before{content:"";position:absolute;width:18px;height:18px;left:2px;top:2px;background:#fff;border-radius:50%;transition:.2s;box-shadow:0 1px 2px rgba(0,0,0,.2)}
.switch input:checked+span{background:var(--ok)}
.switch input:checked+span:before{transform:translateX(14px)}
.off-row .nm span.t,.off-row .ic{opacity:.55}
@media(max-width:680px){.head,.item{grid-template-columns:24px 32px minmax(0,1fr) 36px}.item .sz,.item .dt,.head .sz,.head .dt{display:none}.search input{width:120px}}
.empty{text-align:center;color:var(--muted);padding:56px 12px;font-size:15px}
.empty svg{width:44px;height:44px;color:var(--line);display:block;margin:0 auto 12px}
#overlay{position:fixed;inset:0;background:var(--accentSoft);border:2px dashed var(--accent);border-radius:20px;margin:10px;display:none;place-items:center;z-index:40;pointer-events:none;font-size:21px;font-weight:600;color:var(--accent)}
#overlay.show{display:grid}
.menu{position:fixed;z-index:60;min-width:200px;background:var(--card);border-radius:14px;padding:6px;box-shadow:0 10px 40px rgba(0,0,0,.18),0 0 0 1px var(--line);display:none}
.menu.show{display:block}
.menu button{display:flex;align-items:center;gap:10px;width:100%;text-align:left;padding:8px 12px;border-radius:9px;font-size:14px}
.menu button:hover{background:var(--fill)}
.menu button.danger{color:var(--danger)}
.menu hr{border:0;border-top:1px solid var(--line);margin:5px 6px}
.menu svg{width:16px;height:16px;color:var(--muted)}
.menu button.danger svg{color:var(--danger)}
.modal-bg{position:fixed;inset:0;background:rgba(0,0,0,.32);z-index:70;display:grid;place-items:center;padding:20px;animation:fade .15s}
@keyframes fade{from{opacity:0}}
.modal{background:var(--card);border-radius:20px;width:100%;max-width:420px;padding:26px 24px 20px;box-shadow:0 20px 60px rgba(0,0,0,.25);animation:pop .18s}
@keyframes pop{from{transform:scale(.96);opacity:0}}
.modal h3{margin:0 0 8px;font-size:19px;font-weight:600;letter-spacing:-.02em}
.modal p{margin:0 0 16px;color:var(--muted);font-size:14px;line-height:1.55;word-break:break-all}
.modal input[type=text]{width:100%;font:inherit;font-size:15px;padding:10px 12px;border-radius:10px;border:1px solid var(--line);background:var(--bg);color:var(--fg);margin-bottom:16px}
.modal input[type=text]:focus{outline:2px solid var(--accent);border-color:transparent}
.modal .acts{display:flex;justify-content:flex-end;gap:8px;flex-wrap:wrap}
.modal .btn.danger{background:var(--danger)}
.modal.wide{max-width:900px;height:min(80vh,760px);display:flex;flex-direction:column}
.modal textarea{flex:1;width:100%;font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;padding:14px;border-radius:12px;border:1px solid var(--line);background:var(--bg);color:var(--fg);resize:none;margin:4px 0 14px;tab-size:2}
.modal textarea:focus{outline:2px solid var(--accent);border-color:transparent}
.picker{border:1px solid var(--line);border-radius:12px;max-height:300px;overflow:auto;margin-bottom:16px}
.picker .pc{display:flex;flex-wrap:wrap;gap:2px;padding:8px 10px;border-bottom:1px solid var(--line);font-size:13px;position:sticky;top:0;background:var(--card)}
.picker .pc a{cursor:pointer;color:var(--accent)}
.picker .pf{display:flex;align-items:center;gap:10px;padding:9px 12px;font-size:14px;cursor:pointer;border-top:1px solid var(--line)}
.picker .pf:first-of-type{border-top:0}
.picker .pf:hover{background:var(--fill)}
.picker .pf.no{opacity:.4;cursor:not-allowed}
.picker .pf svg{width:16px;height:16px;color:var(--accent)}
.picker .none{padding:14px;color:var(--muted);font-size:13px}
.kbd{font-size:12px;color:var(--muted)}
</style>
</head>
<body>
<header>
  <div class="bar">
    <div class="brand"><div class="logo"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg></div><div>本地服务器<small id="where">文件管理</small></div></div>
    <div class="spacer"></div>
    <a class="btn ghost small" href="/" target="_blank">所有站点</a>
    <button class="btn ghost small" id="unpair" style="display:none">取消配对</button>
  </div>
</header>

<main>
  <div class="side">
    <section class="card">
      <h2>上传</h2>
      <div id="drop">
        <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 16V4M7 9l5-5 5 5M5 20h14"/></svg></div>
        <p><b>拖入文件、文件夹或 zip</b><br>上传到当前打开的目录。<br>www 中的每个文件夹都是一个站点。</p>
        <div class="row">
          <button class="btn small" id="pickBtn">选择文件</button>
          <button class="btn ghost small" id="pickDirBtn">选择文件夹</button>
        </div>
      </div>
      <label class="opt"><input type="checkbox" id="unzip"> 自动解压 zip（解压到同名文件夹）</label>
      <input id="pick" type="file" multiple hidden>
      <input id="pickDir" type="file" webkitdirectory multiple hidden>
    </section>

    <section class="card">
      <h2>上传队列 <span class="count" id="qcount">0</span><span style="flex:1"></span><button class="btn ghost small" id="clearQ">清除已完成</button></h2>
      <div id="queue"><div class="empty-q">暂无上传任务</div></div>
    </section>
  </div>

  <section class="card">
    <div class="toolbar">
      <div class="crumbs" id="crumbs"></div>
      <label class="search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input id="filter" placeholder="筛选"></label>
      <button class="btn ghost small" id="newBtn">新建</button>
      <button class="btn ghost small" id="refreshBtn" title="刷新">刷新</button>
    </div>
    <div id="selbar">
      <span class="n" id="selcount"></span>
      <button class="btn ghost small" data-batch="download">下载</button>
      <button class="btn ghost small" data-batch="copy">复制到…</button>
      <button class="btn ghost small" data-batch="move">移动到…</button>
      <button class="btn ghost small" data-batch="delete" style="color:var(--danger)">删除</button>
      <button class="btn ghost small" data-batch="clear">取消</button>
    </div>
    <div class="head"><input type="checkbox" class="ck" id="checkAll" title="全选"><span></span><span>名称</span><span class="sz" style="text-align:right">大小</span><span class="dt" style="text-align:right">修改时间</span><span></span></div>
    <div id="list"></div>
    <p class="kbd" style="margin:14px 8px 0">提示：⌘/Ctrl + A 全选，Delete 删除所选，Esc 取消选择。</p>
  </section>
</main>
<div id="overlay">松开即可上传到当前目录</div>
<div class="menu" id="menu"></div>
<div id="toast"></div>

<script>
const API = '/__admin/api/';
const GUARD = {'X-LocalServer': '1'};
const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const join = (...p) => ('/' + p.join('/')).replace(/\/+/g, '/');
const encPath = p => p.split('/').map(encodeURIComponent).join('/');
const isHidden = path => path.split('/').some(s => s.startsWith('.'));
const parentOf = p => join(...p.split('/').filter(Boolean).slice(0, -1));
const nameOf = p => p.split('/').filter(Boolean).pop() || '';
const TEXT_EXT = /\.(html?|css|m?js|jsx|tsx?|vue|json|txt|md|xml|svg|csv|webmanifest|map)$/i;

let cwd = decodeURIComponent(location.hash.slice(1)) || '/';
let disabledSites = [];
let items = [];
let selected = new Set();
let queue = [];
let uploading = false;

const SVG = {
  folder: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 7a2 2 0 0 1 2-2h4.2l2 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
  more: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/></svg>',
  open: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14 21 3"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12M7 10l5 5 5-5M5 21h14"/></svg>',
  edit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
  rename: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7V5h16v2M9 19h6M12 5v14"/></svg>',
  dup: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1"/></svg>',
  copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 4h10a2 2 0 0 1 2 2v10M4 8h10a2 2 0 0 1 2 2v10H6a2 2 0 0 1-2-2z"/></svg>',
  move: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M10 13h6M13 10l3 3-3 3"/></svg>',
  site: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/></svg>',
  empty: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M3 7a2 2 0 0 1 2-2h4.2l2 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>'
};
const TYPES = [
  [/^html?$/, 'HTML'], [/^css$/, 'CSS'], [/^(m?js|jsx|ts|tsx|vue)$/, 'JS'], [/^(json|xml|map|webmanifest)$/, '{ }'],
  [/^(png|jpe?g|gif|webp|svg|ico|avif|bmp|heic)$/, 'IMG'], [/^(mp4|mov|m4v|webm)$/, 'VID'], [/^(mp3|m4a|wav|aac|ogg|flac)$/, 'AUD'],
  [/^(woff2?|ttf|otf)$/, 'Aa'], [/^pdf$/, 'PDF'], [/^zip$/, 'ZIP'], [/^(md|txt|csv)$/, 'TXT']
];
function typeLabel(name) {
  const ext = (name.split('.').pop() || '').toLowerCase();
  for (const [re, label] of TYPES) if (re.test(ext)) return label;
  return ext.slice(0, 3).toUpperCase() || 'FILE';
}

function toast(msg) {
  const t = $('#toast'); t.textContent = msg; t.classList.add('show');
  clearTimeout(toast.timer); toast.timer = setTimeout(() => t.classList.remove('show'), 2600);
}
function fmtSize(n) {
  if (n < 1024) return n + ' B';
  const u = ['KB', 'MB', 'GB']; let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return n.toFixed(n < 10 ? 1 : 0) + ' ' + u[i];
}
function fmtDate(ms) {
  const d = new Date(ms), z = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${z(d.getMonth() + 1)}-${z(d.getDate())} ${z(d.getHours())}:${z(d.getMinutes())}`;
}

async function api(method, name, params) {
  const qs = new URLSearchParams(params || {}).toString();
  const r = await fetch(API + name + (qs ? '?' + qs : ''), {method, headers: GUARD});
  const j = await r.json().catch(() => ({}));
  if (r.status === 401) { location.reload(); throw new Error('需要配对'); }
  if (!r.ok) { const e = new Error(j.error || r.statusText); e.status = r.status; e.data = j; throw e; }
  return j;
}

// ---------- 对话框 ----------
function modal(html, wide) {
  const bg = document.createElement('div');
  bg.className = 'modal-bg';
  bg.innerHTML = `<div class="modal${wide ? ' wide' : ''}">${html}</div>`;
  document.body.appendChild(bg);
  return bg;
}
function closeModal(bg) { bg.remove(); }
function topModal() { const all = document.querySelectorAll('.modal-bg'); return all[all.length - 1]; }

/** buttons: [{label, value, style}]，返回被点击按钮的 value，取消返回 null */
function dialog({title, message = '', input = null, buttons}) {
  return new Promise(resolve => {
    const bg = modal(`<h3>${esc(title)}</h3>${message ? `<p>${esc(message)}</p>` : ''}
      ${input !== null ? `<input type="text" value="${esc(input)}" spellcheck="false">` : ''}
      <div class="acts">${buttons.map((b, i) => `<button class="btn ${b.style || ''}" data-i="${i}">${esc(b.label)}</button>`).join('')}</div>`);
    const field = bg.querySelector('input');
    const finish = v => { closeModal(bg); resolve(v); };
    bg.onclick = e => { if (e.target === bg) finish(null); };
    bg.querySelectorAll('[data-i]').forEach(btn => btn.onclick = () => {
      const b = buttons[+btn.dataset.i];
      if (b.value === null) return finish(null);
      finish(field ? (b.value === true ? field.value.trim() : b.value) : b.value);
    });
    bg.esc = () => finish(null);
    if (field) {
      field.focus();
      const dot = field.value.lastIndexOf('.');
      field.setSelectionRange(0, dot > 0 ? dot : field.value.length);
      field.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); finish(field.value.trim()); } };
    } else {
      bg.querySelector('.btn:last-child').focus();
    }
  });
}
const ask = (title, input, ok = '确定') => dialog({title, input, buttons: [{label: '取消', value: null, style: 'ghost'}, {label: ok, value: true}]});
const confirmDanger = (title, message, ok = '删除') => dialog({title, message, buttons: [{label: '取消', value: null, style: 'ghost'}, {label: ok, value: true, style: 'danger'}]});

/** 选择目标文件夹，exclude 中的路径及其子文件夹不可选 */
function pickFolder(title, okLabel, exclude) {
  return new Promise(resolve => {
    let at = cwd;
    const bg = modal(`<h3>${esc(title)}</h3><div class="picker" id="pk"></div>
      <div class="acts"><button class="btn ghost" data-a="new">新建文件夹</button><span style="flex:1"></span>
      <button class="btn ghost" data-a="cancel">取消</button><button class="btn" data-a="ok"></button></div>`);
    const okBtn = bg.querySelector('[data-a=ok]');
    const blocked = p => exclude.some(x => p === x || p.startsWith(x + '/'));
    const finish = v => { closeModal(bg); resolve(v); };
    bg.esc = () => finish(null);
    bg.onclick = e => { if (e.target === bg) finish(null); };
    async function render() {
      const pk = bg.querySelector('#pk');
      okBtn.textContent = okLabel + '「' + (at === '/' ? 'www' : nameOf(at)) + '」';
      okBtn.disabled = blocked(at);
      const parts = at.split('/').filter(Boolean);
      let crumbs = `<a data-p="/">www</a>`;
      parts.forEach((p, i) => crumbs += ` / <a data-p="${esc(join(...parts.slice(0, i + 1)))}">${esc(p)}</a>`);
      let rows = '';
      try {
        const data = await api('GET', 'list', {path: at});
        const dirs = data.items.filter(it => it.dir);
        rows = dirs.map(it => {
          const p = join(at, it.name);
          return `<div class="pf${blocked(p) ? ' no' : ''}" data-p="${esc(p)}">${SVG.folder}${esc(it.name)}</div>`;
        }).join('') || '<div class="none">没有子文件夹</div>';
      } catch (e) { rows = `<div class="none">${esc(e.message)}</div>`; }
      pk.innerHTML = `<div class="pc">${crumbs}</div>${rows}`;
      pk.querySelectorAll('[data-p]').forEach(el => el.onclick = () => {
        if (el.classList.contains('no')) return;
        at = el.dataset.p; render();
      });
    }
    bg.querySelector('[data-a=cancel]').onclick = () => finish(null);
    okBtn.onclick = () => finish(at);
    bg.querySelector('[data-a=new]').onclick = async () => {
      const name = await ask('新建文件夹', '');
      if (!name) return;
      try { await api('POST', 'mkdir', {path: join(at, name)}); at = join(at, name); render(); } catch (e) { toast(e.message); }
    };
    render();
  });
}

// ---------- 在线编辑 ----------
async function editFile(path) {
  let text;
  try {
    const r = await fetch(API + 'download?path=' + encodeURIComponent(path));
    if (!r.ok) throw new Error('无法读取文件');
    text = await r.text();
  } catch (e) { return toast(e.message); }
  const bg = modal(`<h3>${esc(nameOf(path))}</h3><p style="margin-bottom:6px">${esc(path)}</p>
    <textarea spellcheck="false"></textarea>
    <div class="acts"><span class="kbd" style="flex:1;align-self:center">⌘/Ctrl + S 保存</span>
    <button class="btn ghost" data-a="close">关闭</button><button class="btn" data-a="save">保存</button></div>`, true);
  const area = bg.querySelector('textarea');
  area.value = text;
  let saved = text;
  area.focus();
  area.onkeydown = e => {
    if (e.key === 'Tab') { e.preventDefault(); const s = area.selectionStart; area.setRangeText('  ', s, area.selectionEnd, 'end'); }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(); }
  };
  async function save() {
    try {
      const r = await fetch(API + 'file?path=' + encodeURIComponent(path), {method: 'PUT', headers: GUARD, body: area.value});
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || '保存失败');
      saved = area.value; toast('已保存'); load();
    } catch (e) { toast(e.message); }
  }
  async function close() {
    if (area.value !== saved) {
      const v = await dialog({title: '有未保存的修改', message: '关闭后修改会丢失。', buttons: [{label: '继续编辑', value: null, style: 'ghost'}, {label: '不保存', value: 'discard', style: 'danger'}, {label: '保存', value: 'save'}]});
      if (v === null) return;
      if (v === 'save') await save();
    }
    closeModal(bg);
  }
  bg.esc = close;
  bg.querySelector('[data-a=save]').onclick = save;
  bg.querySelector('[data-a=close]').onclick = close;
}

// ---------- 文件列表 ----------
function siteOf(p) { return p.split('/').filter(Boolean)[0] || ''; }
function webURL(p) {
  const site = siteOf(p);
  if (site && disabledSites.includes(site)) return null;
  return encPath(p);
}
function shown() {
  const q = $('#filter').value.trim().toLowerCase();
  return items.filter(it => !q || it.name.toLowerCase().includes(q));
}

function renderCrumbs() {
  const parts = cwd.split('/').filter(Boolean);
  let html = `<a data-p="/" class="${parts.length ? '' : 'cur'}">www</a>`;
  parts.forEach((p, i) => {
    html += `<span class="sep">/</span><a data-p="${esc(join(...parts.slice(0, i + 1)))}" class="${i === parts.length - 1 ? 'cur' : ''}">${esc(p)}</a>`;
  });
  $('#crumbs').innerHTML = html;
  $('#crumbs').querySelectorAll('a').forEach(a => a.onclick = () => go(a.dataset.p));
  $('#where').textContent = cwd === '/' ? '文件管理' : cwd;
}

function renderSelection() {
  const n = selected.size;
  $('#selbar').classList.toggle('show', n > 0);
  $('#selcount').textContent = `已选择 ${n} 项`;
  const visible = shown();
  $('#checkAll').checked = visible.length > 0 && visible.every(it => selected.has(it.name));
  $('#checkAll').indeterminate = n > 0 && !$('#checkAll').checked;
  document.querySelectorAll('.item').forEach(row => {
    const on = selected.has(row.dataset.name);
    row.classList.toggle('sel', on);
    row.querySelector('.ck').checked = on;
  });
}

function renderList() {
  const list = shown();
  if (!list.length) {
    $('#list').innerHTML = `<div class="empty">${SVG.empty}${$('#filter').value ? '没有匹配的文件' : '空文件夹，拖入文件即可上传'}</div>`;
    renderSelection();
    return;
  }
  const atRoot = cwd === '/';
  $('#list').innerHTML = list.map(it => {
    const off = atRoot && it.dir && disabledSites.includes(it.name);
    const site = atRoot && it.dir
      ? `<label class="switch" title="${off ? '站点已关闭，点击开启' : '站点已开启，点击关闭'}"><input type="checkbox" data-site ${off ? '' : 'checked'}><span></span></label>${off ? '<span class="tag off">已关闭</span>' : ''}`
      : '';
    return `<div class="item${off ? ' off-row' : ''}" data-name="${esc(it.name)}">
      <input type="checkbox" class="ck">
      <div class="ic${it.dir ? ' dir' : ''}">${it.dir ? SVG.folder : typeLabel(it.name)}</div>
      <div class="nm"><span class="t" data-open title="${esc(it.name)}">${esc(it.name)}</span>${site}</div>
      <div class="sz">${it.dir ? '—' : fmtSize(it.size)}</div>
      <div class="dt">${fmtDate(it.mtime)}</div>
      <button class="more" data-more title="更多操作">${SVG.more}</button>
    </div>`;
  }).join('');
  $('#list').querySelectorAll('.item').forEach(row => {
    const it = items.find(x => x.name === row.dataset.name);
    row.querySelector('[data-open]').onclick = () => openItem(it);
    row.querySelector('.ck').onchange = e => { e.target.checked ? selected.add(it.name) : selected.delete(it.name); renderSelection(); };
    row.querySelector('[data-more]').onclick = e => { e.stopPropagation(); showMenu(e.currentTarget, it); };
    row.oncontextmenu = e => { e.preventDefault(); showMenu({getBoundingClientRect: () => ({left: e.clientX, right: e.clientX, top: e.clientY, bottom: e.clientY})}, it); };
    const sw = row.querySelector('[data-site]');
    if (sw) sw.onchange = () => toggleSite(it.name, sw.checked);
  });
  renderSelection();
}

async function load() {
  history.replaceState(null, '', cwd === '/' ? location.pathname : '#' + encodeURIComponent(cwd));
  renderCrumbs();
  try {
    const data = await api('GET', 'list', {path: cwd});
    items = data.items;
    disabledSites = data.disabledSites || [];
    $('#unpair').style.display = data.paired ? 'inline-flex' : 'none';
    const names = new Set(items.map(it => it.name));
    selected = new Set([...selected].filter(n => names.has(n)));
    renderList();
  } catch (e) {
    if (cwd !== '/') { cwd = '/'; return load(); }
    $('#list').innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}

function go(p) { cwd = p; selected.clear(); $('#filter').value = ''; load(); }

function openItem(it) {
  const p = join(cwd, it.name);
  if (it.dir) return go(p);
  const url = webURL(p);
  url ? window.open(url, '_blank') : toast('站点「' + siteOf(p) + '」已关闭，开启后才能访问');
}

function download(paths) {
  const a = document.createElement('a');
  const single = paths.length === 1 && items.find(x => join(cwd, x.name) === paths[0] && !x.dir);
  a.href = single ? API + 'download?path=' + encodeURIComponent(paths[0]) : API + 'zip?paths=' + encodeURIComponent(JSON.stringify(paths));
  a.download = '';
  document.body.appendChild(a); a.click(); a.remove();
  if (!single) toast('正在打包下载…');
}

// ---------- 菜单 ----------
function showMenu(anchor, it) {
  const p = join(cwd, it.name);
  const atRoot = cwd === '/';
  const entries = [];
  entries.push(['open', SVG.open, it.dir ? '打开文件夹' : '在新标签页打开', () => openItem(it)]);
  entries.push(['download', SVG.download, it.dir ? '打包下载' : '下载', () => download([p])]);
  if (!it.dir && TEXT_EXT.test(it.name)) entries.push(['edit', SVG.edit, '编辑', () => editFile(p)]);
  entries.push('-');
  entries.push(['rename', SVG.rename, '重命名', () => rename(it)]);
  entries.push(['dup', SVG.dup, '创建副本', () => duplicate(it)]);
  entries.push(['copy', SVG.copy, '复制到…', () => transfer([it.name], true)]);
  entries.push(['move', SVG.move, '移动到…', () => transfer([it.name], false)]);
  if (atRoot && it.dir) {
    const off = disabledSites.includes(it.name);
    entries.push('-');
    entries.push(['site', SVG.site, off ? '开启站点' : '关闭站点', () => toggleSite(it.name, off)]);
  }
  entries.push('-');
  entries.push(['delete', SVG.trash, '删除', () => removeItems([it.name]), 'danger']);

  const menu = $('#menu');
  menu.innerHTML = entries.map((e, i) => e === '-' ? '<hr>' : `<button data-i="${i}" class="${e[4] || ''}">${e[1]}${esc(e[2])}</button>`).join('');
  menu.querySelectorAll('button').forEach(b => b.onclick = () => { hideMenu(); entries[+b.dataset.i][3](); });
  menu.classList.add('show');
  const r = anchor.getBoundingClientRect();
  const mw = menu.offsetWidth, mh = menu.offsetHeight;
  let left = Math.min(r.right - mw, window.innerWidth - mw - 8);
  if (left < 8) left = Math.min(r.left, window.innerWidth - mw - 8);
  let top = r.bottom + 6;
  if (top + mh > window.innerHeight - 8) top = Math.max(8, r.top - mh - 6);
  menu.style.left = Math.max(8, left) + 'px';
  menu.style.top = top + 'px';
}
function hideMenu() { $('#menu').classList.remove('show'); }
document.addEventListener('click', e => { if (!e.target.closest('#menu')) hideMenu(); });
window.addEventListener('scroll', hideMenu, true);

// ---------- 文件操作 ----------
async function mkdir() {
  const name = await ask('新建文件夹', '');
  if (!name) return;
  try { await api('POST', 'mkdir', {path: join(cwd, name)}); toast('已创建'); load(); } catch (e) { toast(e.message); }
}

async function newFile() {
  const name = await ask('新建文件', 'index.html', '创建');
  if (!name) return;
  const path = join(cwd, name);
  if (items.some(it => it.name === name)) return toast('已存在同名项目');
  try {
    const r = await fetch(API + 'file?path=' + encodeURIComponent(path), {method: 'PUT', headers: GUARD, body: ''});
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || '创建失败');
    await load();
    if (TEXT_EXT.test(name)) editFile(path);
  } catch (e) { toast(e.message); }
}

async function rename(it) {
  const name = await ask('重命名', it.name, '重命名');
  if (!name || name === it.name) return;
  try {
    await api('POST', 'move', {from: join(cwd, it.name), to: join(cwd, name)});
    selected.delete(it.name);
    toast('已重命名'); load();
  } catch (e) { toast(e.message); }
}

async function duplicate(it) {
  try {
    const j = await api('POST', 'copy', {from: join(cwd, it.name), to: join(cwd, it.name), conflict: 'keep'});
    toast('已创建「' + j.name + '」'); load();
  } catch (e) { toast(e.message); }
}

/** 复制或移动多个项目到用户选择的文件夹；遇到同名项目时询问 */
async function transfer(names, copy) {
  const paths = names.map(n => join(cwd, n));
  const dest = await pickFolder(copy ? `复制 ${names.length} 项到` : `移动 ${names.length} 项到`, copy ? '复制到' : '移动到', copy ? [] : paths);
  if (dest === null) return;
  if (!copy && dest === cwd) return toast('已在该文件夹中');
  let remembered = null, done = 0, skipped = 0;
  for (const from of paths) {
    const to = join(dest, nameOf(from));
    let conflict = remembered;
    for (;;) {
      try {
        await api('POST', copy ? 'copy' : 'move', conflict ? {from, to, conflict} : {from, to});
        done++; break;
      } catch (e) {
        if (e.status !== 409) { toast(nameOf(from) + '：' + e.message); skipped++; break; }
        const choice = await dialog({
          title: `「${nameOf(from)}」已存在`,
          message: '目标文件夹中已有同名项目。',
          buttons: [{label: '跳过', value: 'skip', style: 'ghost'}, {label: '保留两者', value: 'keep', style: 'ghost'}, {label: '覆盖', value: 'overwrite', style: 'danger'}]
        });
        if (choice === null || choice === 'skip') { skipped++; break; }
        conflict = choice;
        if (paths.length > 1) remembered = choice;
      }
    }
  }
  selected.clear();
  toast(`${copy ? '已复制' : '已移动'} ${done} 项` + (skipped ? `，跳过 ${skipped} 项` : ''));
  load();
}

async function removeItems(names) {
  const title = names.length === 1 ? `删除「${names[0]}」？` : `删除 ${names.length} 个项目？`;
  if (!await confirmDanger(title, '删除后无法恢复，文件夹中的内容也会一并删除。')) return;
  let failed = 0;
  for (const n of names) {
    try { await api('POST', 'delete', {path: join(cwd, n)}); selected.delete(n); } catch (e) { failed++; toast(n + '：' + e.message); }
  }
  if (!failed) toast(`已删除 ${names.length} 项`);
  load();
}

async function toggleSite(name, enable) {
  try {
    await api('POST', 'site', {name, enabled: enable ? '1' : '0'});
    toast(enable ? `已开启「${name}」` : `已关闭「${name}」，无法再访问`);
  } catch (e) { toast(e.message); }
  load();
}

// ---------- 上传队列 ----------
const unzipBox = $('#unzip');
try { unzipBox.checked = localStorage.getItem('ls-unzip') !== '0'; } catch (_) { unzipBox.checked = true; }
unzipBox.onchange = () => { try { localStorage.setItem('ls-unzip', unzipBox.checked ? '1' : '0'); } catch (_) {} };

function renderQueue() {
  $('#qcount').textContent = queue.filter(q => q.state === 'wait' || q.state === 'run').length;
  if (!queue.length) { $('#queue').innerHTML = '<div class="empty-q">暂无上传任务</div>'; return; }
  $('#queue').innerHTML = queue.map(q => {
    const st = {wait: '等待中', run: Math.round(q.progress * 100) + '%', done: q.note || '完成', fail: '失败'}[q.state];
    return `<div class="q ${q.state}" title="${esc(q.error || q.path)}">
      <div class="nm">${esc(q.path)}</div><div class="st">${st}</div>
      <div class="track"><div class="fill" style="width:${q.state === 'done' ? 100 : q.progress * 100}%"></div></div>
    </div>`;
  }).join('');
}

function enqueue(entries) {
  entries = entries.filter(e => !isHidden(e.path));
  if (!entries.length) return;
  const base = cwd;
  entries.forEach(e => queue.push({file: e.file, path: e.path, dest: join(base, e.path), state: 'wait', progress: 0}));
  renderQueue();
  runQueue();
}

function putFile(q) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const extract = unzipBox.checked && /\.zip$/i.test(q.path) ? '&extract=1' : '';
    xhr.open('PUT', API + 'file?path=' + encodeURIComponent(q.dest) + extract);
    xhr.setRequestHeader('X-LocalServer', '1');
    xhr.upload.onprogress = e => { if (e.lengthComputable) { q.progress = e.loaded / e.total; renderQueue(); } };
    xhr.onload = () => {
      let j = {};
      try { j = JSON.parse(xhr.responseText); } catch (_) {}
      if (xhr.status === 401) { location.reload(); return reject(new Error('需要配对')); }
      if (xhr.status < 300) return resolve(j);
      reject(new Error(j.error || xhr.statusText));
    };
    xhr.onerror = () => reject(new Error('网络错误，手机上的 App 是否还在运行？'));
    xhr.send(q.file);
  });
}

async function runQueue() {
  if (uploading) return;
  uploading = true;
  let next;
  while ((next = queue.find(q => q.state === 'wait'))) {
    next.state = 'run'; renderQueue();
    try {
      const j = await putFile(next);
      next.state = 'done';
      if (j.folder) next.note = '已解压到「' + j.folder + '」';
    } catch (e) {
      next.state = 'fail'; next.error = e.message; toast(next.path + '：' + e.message);
    }
    renderQueue();
  }
  uploading = false;
  load();
}

$('#clearQ').onclick = () => { queue = queue.filter(q => q.state === 'wait' || q.state === 'run'); renderQueue(); };

// ---------- 拖拽上传 ----------
function walk(entry, prefix, out) {
  return new Promise(resolve => {
    if (entry.isFile) {
      entry.file(f => { out.push({file: f, path: prefix + f.name}); resolve(); }, () => resolve());
    } else if (entry.isDirectory) {
      const reader = entry.createReader(), children = [];
      const read = () => reader.readEntries(async batch => {
        if (batch.length) { children.push(...batch); read(); return; }
        for (const c of children) await walk(c, prefix + entry.name + '/', out);
        resolve();
      }, () => resolve());
      read();
    } else resolve();
  });
}

const hasFiles = e => [...(e.dataTransfer?.types || [])].includes('Files');
let dragDepth = 0;
window.addEventListener('dragenter', e => { if (!hasFiles(e)) return; e.preventDefault(); dragDepth++; $('#overlay').classList.add('show'); $('#drop').classList.add('over'); });
window.addEventListener('dragleave', e => { if (!hasFiles(e)) return; e.preventDefault(); if (--dragDepth <= 0) { dragDepth = 0; $('#overlay').classList.remove('show'); $('#drop').classList.remove('over'); } });
window.addEventListener('dragover', e => { if (hasFiles(e)) e.preventDefault(); });
window.addEventListener('drop', async e => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dragDepth = 0; $('#overlay').classList.remove('show'); $('#drop').classList.remove('over');
  // 必须在第一个 await 之前取出条目，之后 dataTransfer 会失效
  const roots = [...e.dataTransfer.items].map(i => i.webkitGetAsEntry && i.webkitGetAsEntry()).filter(Boolean);
  const files = [...e.dataTransfer.files];
  const out = [];
  if (roots.length) { for (const r of roots) await walk(r, '', out); }
  else files.forEach(f => out.push({file: f, path: f.name}));
  enqueue(out);
});

// ---------- 按钮与快捷键 ----------
$('#pickBtn').onclick = () => $('#pick').click();
$('#pickDirBtn').onclick = () => $('#pickDir').click();
$('#pick').onchange = e => { enqueue([...e.target.files].map(f => ({file: f, path: f.name}))); e.target.value = ''; };
$('#pickDir').onchange = e => { enqueue([...e.target.files].map(f => ({file: f, path: f.webkitRelativePath || f.name}))); e.target.value = ''; };
$('#newBtn').onclick = async () => {
  const v = await dialog({title: '新建', buttons: [{label: '取消', value: null, style: 'ghost'}, {label: '文件', value: 'file', style: 'ghost'}, {label: '文件夹', value: 'folder'}]});
  if (v === 'folder') mkdir(); else if (v === 'file') newFile();
};
$('#refreshBtn').onclick = load;
$('#filter').oninput = renderList;
$('#checkAll').onchange = e => {
  shown().forEach(it => e.target.checked ? selected.add(it.name) : selected.delete(it.name));
  renderSelection();
};
document.querySelectorAll('[data-batch]').forEach(b => b.onclick = () => {
  const names = [...selected];
  switch (b.dataset.batch) {
    case 'download': download(names.map(n => join(cwd, n))); break;
    case 'copy': transfer(names, true); break;
    case 'move': transfer(names, false); break;
    case 'delete': removeItems(names); break;
    case 'clear': selected.clear(); renderSelection(); break;
  }
});
$('#unpair').onclick = async () => {
  if (!await confirmDanger('取消配对？', '之后这个浏览器需要重新输入配对码才能管理文件。', '取消配对')) return;
  try { await api('POST', 'unpair'); } catch (_) {}
  location.reload();
};

document.addEventListener('keydown', e => {
  const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement?.tagName) && document.activeElement.type !== 'checkbox';
  if (e.key === 'Escape') {
    const m = topModal();
    if (m && m.esc) { m.esc(); return; }
    if ($('#menu').classList.contains('show')) { hideMenu(); return; }
    if (selected.size) { selected.clear(); renderSelection(); }
    return;
  }
  if (typing || topModal()) return;
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a') {
    e.preventDefault(); shown().forEach(it => selected.add(it.name)); renderSelection();
  } else if ((e.key === 'Delete' || e.key === 'Backspace') && selected.size) {
    e.preventDefault(); removeItems([...selected]);
  }
});

renderQueue();
load();
</script>
</body>
</html>
"""#
}

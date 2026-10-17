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
header{position:sticky;top:0;z-index:10;background:var(--bg);backdrop-filter:saturate(180%) blur(16px);-webkit-backdrop-filter:saturate(180%) blur(16px);background:color-mix(in srgb,var(--bg) 80%,transparent);border-bottom:1px solid var(--line)}
.bar{max-width:1080px;margin:0 auto;padding:12px 20px;display:flex;align-items:center;gap:12px}
.bar .spacer{flex:1}
.brand small{display:block;font-weight:500;font-size:12px;color:var(--muted)}
main{max-width:1080px;margin:0 auto;padding:22px 20px 80px;display:grid;grid-template-columns:340px 1fr;gap:20px;align-items:start}
@media(max-width:860px){main{grid-template-columns:1fr}}
.card{background:var(--card);border-radius:var(--radius);padding:22px}
.card h2{font-size:19px;font-weight:600;letter-spacing:-.02em;margin:0 0 16px;display:flex;align-items:center;gap:8px}
.card h2 .count{font-size:12px;font-weight:600;color:var(--muted);background:var(--soft);border-radius:20px;padding:2px 8px}
.side{display:flex;flex-direction:column;gap:20px;position:sticky;top:80px}
@media(max-width:860px){.side{position:static}}
#drop{border:1.5px dashed var(--line);border-radius:14px;padding:28px 16px;text-align:center;transition:.2s;background:var(--bg)}
#drop.over{border-color:var(--accent);background:var(--accentSoft)}
#drop .icon{width:48px;height:48px;margin:0 auto 12px;border-radius:50%;background:var(--fill);color:var(--fg);display:grid;place-items:center}
#drop .icon svg{width:28px;height:28px}
#drop p{margin:0 0 14px;color:var(--muted);font-size:13px;line-height:1.6}
#drop p b{color:var(--fg);font-size:15px}
.row{display:flex;gap:8px;justify-content:center;flex-wrap:wrap}
.opt{display:flex;align-items:center;gap:8px;margin-top:14px;font-size:13px;color:var(--muted);cursor:pointer;user-select:none}
.opt input{accent-color:var(--accent);width:16px;height:16px}
#queue{display:flex;flex-direction:column;gap:10px;max-height:340px;overflow:auto}
.q{display:grid;grid-template-columns:28px 1fr auto;gap:10px;align-items:center;font-size:13px}
.q .nm{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.q .meta{font-size:12px;color:var(--muted)}
.q .track{grid-column:2/4;height:4px;background:var(--line);border-radius:2px;overflow:hidden;margin-top:-4px}
.q .fill{height:100%;width:0;background:var(--accent);transition:width .15s}
.q.done .fill{background:var(--ok)}.q.fail .fill{background:var(--danger);width:100%!important}
.q .st{font-size:12px;font-weight:600;color:var(--muted)}.q.done .st{color:var(--ok)}.q.fail .st{color:var(--danger)}
.empty-q{font-size:13px;color:var(--muted);text-align:center;padding:8px 0}
.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:12px}
.crumbs{flex:1;min-width:180px;display:flex;flex-wrap:wrap;align-items:center;gap:2px;font-size:14px}
.crumbs a{color:var(--muted);text-decoration:none;cursor:pointer;padding:4px 8px;border-radius:8px;font-weight:500}
.crumbs a:hover{background:var(--soft);color:var(--fg)}
.crumbs a.cur{color:var(--fg);font-weight:700}
.crumbs .sep{color:var(--line)}
.search{position:relative}
.search input{font:inherit;font-size:13px;padding:8px 14px 8px 32px;border-radius:980px;border:0;background:var(--fill);color:var(--fg);width:190px}
.search input:focus{outline:none;border-color:var(--accent)}
.search svg{position:absolute;left:10px;top:50%;transform:translateY(-50%);width:15px;height:15px;color:var(--muted)}
.list{display:flex;flex-direction:column}
.item{display:grid;grid-template-columns:40px 1fr 90px 130px auto;gap:12px;align-items:center;padding:9px 8px;border-radius:12px;transition:background .12s}
.item:hover{background:var(--soft)}
.item .ic{width:36px;height:36px;border-radius:9px;display:grid;place-items:center;font-size:9px;font-weight:700;letter-spacing:.3px;color:var(--muted);background:var(--fill)}
.item .ic svg{width:18px;height:18px}
.item .nm{min-width:0;font-size:14px;font-weight:500;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item .nm:hover{color:var(--accent)}
.item .sz,.item .dt{font-size:12px;color:var(--muted);text-align:right;white-space:nowrap}
.acts{display:flex;gap:2px;opacity:.55;transition:opacity .12s}
.item:hover .acts{opacity:1}
.acts button,.acts a{width:32px;height:32px;border-radius:9px;display:grid;place-items:center;color:var(--muted)}
.acts button:hover,.acts a:hover{background:var(--card);color:var(--fg)}
.acts .del:hover{color:var(--danger)}
.acts svg{width:16px;height:16px}
.tag{font-size:11px;font-weight:600;color:var(--muted);background:var(--fill);border-radius:980px;padding:2px 8px;margin-left:8px;vertical-align:1px}
.tag.off{color:var(--danger)}
@media(max-width:640px){.item{grid-template-columns:36px 1fr auto}.item .sz,.item .dt{display:none}.search input{width:130px}}
.empty{text-align:center;color:var(--muted);padding:48px 12px;font-size:14px}
.empty svg{width:44px;height:44px;color:var(--line);display:block;margin:0 auto 10px}
#overlay{position:fixed;inset:0;background:var(--accentSoft);border:2px dashed var(--accent);border-radius:20px;margin:10px;display:none;place-items:center;z-index:40;pointer-events:none;font-size:20px;font-weight:700;color:var(--accent)}
#overlay.show{display:grid}
</style>
</head>
<body>
<header>
  <div class="bar">
    <div class="brand"><div class="logo"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg></div><div>本地服务器<small id="where">文件管理</small></div></div>
    <div class="spacer"></div>
    <a class="btn ghost small" href="/" target="_blank" title="所有站点"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14 21 3"/></svg>所有站点</a>
    <button class="btn ghost small" id="unpair" style="display:none">取消配对</button>
  </div>
</header>

<main>
  <div class="side">
    <section class="card">
      <h2>上传</h2>
      <div id="drop">
        <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 16l-4-4-4 4M12 12v9"/><path d="M20.4 18.4A5 5 0 0 0 18 9h-1.3A8 8 0 1 0 3 16.3"/></svg></div>
        <p><b>拖入文件、文件夹或 zip</b><br>上传到当前打开的目录。<br>www 下的每个文件夹都是一个站点。</p>
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
      <label class="search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input id="filter" placeholder="筛选文件"></label>
      <button class="btn ghost small" id="mkdirBtn"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 11v5M9.5 13.5h5"/></svg>新建文件夹</button>
      <button class="btn ghost small" id="refreshBtn" title="刷新"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/></svg></button>
    </div>
    <div class="list" id="list"></div>
  </section>
</main>
<div id="overlay">松开即可上传到当前目录</div>
<div id="toast"></div>

<script>
const API = '/__admin/api/';
const GUARD = {'X-LocalServer': '1'};
const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const join = (...p) => ('/' + p.join('/')).replace(/\/+/g, '/');
const encPath = p => p.split('/').map(encodeURIComponent).join('/');
const isHidden = path => path.split('/').some(s => s.startsWith('.'));

let cwd = decodeURIComponent(location.hash.slice(1)) || '/';
let disabledSites = [];
let items = [];
let queue = [];
let uploading = false;

const ICONS = {
  folder: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 7a2 2 0 0 1 2-2h4.2l2 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12M7 10l5 5 5-5M5 21h14"/></svg>',
  rename: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/></svg>',
  empty: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M3 7a2 2 0 0 1 2-2h4.2l2 2H19a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>'
};
const TYPES = [
  [/^html?$/, 'HTML', '#f97316'], [/^css$/, 'CSS', '#3b82f6'], [/^(m?js|jsx|ts|tsx|vue)$/, 'JS', '#eab308'],
  [/^(json|xml|map|webmanifest)$/, '{ }', '#64748b'], [/^(png|jpe?g|gif|webp|svg|ico|avif|bmp|heic)$/, 'IMG', '#22c55e'],
  [/^(mp4|mov|m4v|webm)$/, 'VID', '#a855f7'], [/^(mp3|m4a|wav|aac|ogg|flac)$/, 'AUD', '#ec4899'],
  [/^(woff2?|ttf|otf)$/, 'Aa', '#14b8a6'], [/^pdf$/, 'PDF', '#ef4444'], [/^zip$/, 'ZIP', '#8b5cf6'], [/^(md|txt|csv)$/, 'TXT', '#64748b']
];
function typeOf(name) {
  const ext = (name.split('.').pop() || '').toLowerCase();
  for (const [re, label, color] of TYPES) if (re.test(ext)) return {label, color};
  return {label: ext.slice(0, 3).toUpperCase() || 'FILE', color: '#94a3b8'};
}

function toast(msg) {
  const t = $('#toast'); t.textContent = msg; t.classList.add('show');
  clearTimeout(toast.timer); toast.timer = setTimeout(() => t.classList.remove('show'), 2800);
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
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

// ---------- 文件列表 ----------
function siteOf(p) { return p.split('/').filter(Boolean)[0] || ''; }
function webURL(p) {
  const site = siteOf(p);
  if (site && disabledSites.includes(site)) return null;
  return encPath(p);
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

function renderList() {
  const q = $('#filter').value.trim().toLowerCase();
  const shown = items.filter(it => !q || it.name.toLowerCase().includes(q));
  if (!shown.length) {
    $('#list').innerHTML = `<div class="empty">${ICONS.empty}${q ? '没有匹配的文件' : '空文件夹，拖入文件即可上传'}</div>`;
    return;
  }
  $('#list').innerHTML = shown.map(it => {
    const p = join(cwd, it.name);
    const t = it.dir ? {label: ''} : typeOf(it.name);
    const icon = it.dir ? ICONS.folder : t.label;
    const isSite = it.dir && cwd === '/';
    const tag = isSite ? (disabledSites.includes(it.name) ? '<span class="tag off">未开启</span>' : '<span class="tag">站点</span>') : '';
    const dl = it.dir ? '' : `<a href="${API}download?path=${encodeURIComponent(p)}" title="下载">${ICONS.download}</a>`;
    return `<div class="item" data-name="${esc(it.name)}">
      <div class="ic"${it.dir ? ' style="color:var(--accent)"' : ''}>${icon}</div>
      <div class="nm" data-open>${esc(it.name)}${tag}</div>
      <div class="sz">${it.dir ? '—' : fmtSize(it.size)}</div>
      <div class="dt">${fmtDate(it.mtime)}</div>
      <div class="acts">${dl}<button data-rename title="重命名">${ICONS.rename}</button><button class="del" data-del title="删除">${ICONS.trash}</button></div>
    </div>`;
  }).join('');
  $('#list').querySelectorAll('.item').forEach(row => {
    const it = items.find(x => x.name === row.dataset.name);
    row.querySelector('[data-open]').onclick = () => openItem(it);
    row.querySelector('[data-rename]').onclick = () => rename(it);
    row.querySelector('[data-del]').onclick = () => remove(it);
  });
}

async function load() {
  history.replaceState(null, '', cwd === '/' ? location.pathname : '#' + encodeURIComponent(cwd));
  renderCrumbs();
  try {
    const data = await api('GET', 'list', {path: cwd});
    items = data.items;
    disabledSites = data.disabledSites || [];
    $('#unpair').style.display = data.paired ? 'inline-flex' : 'none';
    renderList();
  } catch (e) {
    if (cwd !== '/') { cwd = '/'; return load(); }
    $('#list').innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}

function go(p) { cwd = p; $('#filter').value = ''; load(); }

function openItem(it) {
  const p = join(cwd, it.name);
  if (it.dir) return go(p);
  const url = webURL(p);
  url ? window.open(url, '_blank') : toast('站点「' + siteOf(p) + '」未开启，可以在手机上开启，或直接下载文件');
}

async function mkdir() {
  const name = prompt('新文件夹名称');
  if (!name) return;
  try { await api('POST', 'mkdir', {path: join(cwd, name)}); load(); } catch (e) { toast(e.message); }
}
async function remove(it) {
  if (!confirm(`确定删除「${it.name}」${it.dir ? '及其中所有内容' : ''}？此操作无法撤销。`)) return;
  try { await api('POST', 'delete', {path: join(cwd, it.name)}); toast('已删除'); load(); } catch (e) { toast(e.message); }
}
async function rename(it) {
  const name = prompt('新名称', it.name);
  if (!name || name === it.name) return;
  try { await api('POST', 'move', {from: join(cwd, it.name), to: join(cwd, name)}); load(); } catch (e) { toast(e.message); }
}

// ---------- 上传队列 ----------
const unzipBox = $('#unzip');
try { unzipBox.checked = localStorage.getItem('ls-unzip') !== '0'; } catch (_) { unzipBox.checked = true; }
unzipBox.onchange = () => { try { localStorage.setItem('ls-unzip', unzipBox.checked ? '1' : '0'); } catch (_) {} };

function renderQueue() {
  $('#qcount').textContent = queue.filter(q => q.state === 'wait' || q.state === 'run').length;
  if (!queue.length) { $('#queue').innerHTML = '<div class="empty-q">暂无上传任务</div>'; return; }
  $('#queue').innerHTML = queue.map((q, i) => {
    const t = typeOf(q.path);
    const st = {wait: '等待中', run: Math.round(q.progress * 100) + '%', done: q.note || '完成', fail: '失败'}[q.state];
    return `<div class="q ${q.state}" title="${esc(q.error || q.path)}">
      <div style="width:28px;height:28px;border-radius:7px;display:grid;place-items:center;font-size:8px;font-weight:700;color:var(--muted);background:var(--fill)">${t.label}</div>
      <div style="min-width:0"><div class="nm">${esc(q.path)}</div><div class="meta">${fmtSize(q.file.size)}</div></div>
      <div class="st">${st}</div>
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

// ---------- 拖拽 ----------
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

let dragDepth = 0;
window.addEventListener('dragenter', e => { e.preventDefault(); dragDepth++; $('#overlay').classList.add('show'); $('#drop').classList.add('over'); });
window.addEventListener('dragleave', e => { e.preventDefault(); if (--dragDepth <= 0) { dragDepth = 0; $('#overlay').classList.remove('show'); $('#drop').classList.remove('over'); } });
window.addEventListener('dragover', e => e.preventDefault());
window.addEventListener('drop', async e => {
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

$('#pickBtn').onclick = () => $('#pick').click();
$('#pickDirBtn').onclick = () => $('#pickDir').click();
$('#pick').onchange = e => { enqueue([...e.target.files].map(f => ({file: f, path: f.name}))); e.target.value = ''; };
$('#pickDir').onchange = e => { enqueue([...e.target.files].map(f => ({file: f, path: f.webkitRelativePath || f.name}))); e.target.value = ''; };
$('#mkdirBtn').onclick = mkdir;
$('#refreshBtn').onclick = load;
$('#filter').oninput = renderList;
$('#unpair').onclick = async () => {
  if (!confirm('取消配对后，这个浏览器需要重新输入配对码才能管理文件。')) return;
  try { await api('POST', 'unpair'); } catch (_) {}
  location.reload();
};

renderQueue();
load();
</script>
</body>
</html>
"""#
}

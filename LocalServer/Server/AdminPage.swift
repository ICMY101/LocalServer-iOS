import Foundation

/// 电脑浏览器访问 `/__admin/` 时显示的上传管理页面
enum AdminPage {
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>文件管理 · 本地服务器</title>
<style>
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--muted:#86868b;--line:#e5e5ea;--accent:#0a66d8;--danger:#d70015;--drop:#eaf2fd}
@media(prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#98989d;--line:#38383a;--accent:#4ea1ff;--danger:#ff6961;--drop:#0d2440}}
*{box-sizing:border-box}
body{margin:0;font-family:-apple-system,system-ui,"PingFang SC","Microsoft YaHei",sans-serif;background:var(--bg);color:var(--fg)}
main{max-width:860px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:24px;margin:0 0 4px}
.sub{color:var(--muted);margin:0 0 20px;font-size:14px}
.card{background:var(--card);border-radius:14px;padding:16px;margin-bottom:16px;box-shadow:0 1px 2px rgba(0,0,0,.06)}
#drop{border:2px dashed var(--line);border-radius:12px;padding:28px 16px;text-align:center;transition:.15s}
#drop.over{border-color:var(--accent);background:var(--drop)}
#drop p{margin:0 0 12px;color:var(--muted)}
button,.btn{font:inherit;font-size:14px;border:0;border-radius:8px;padding:8px 14px;cursor:pointer;background:var(--accent);color:#fff}
button.ghost{background:transparent;color:var(--accent);border:1px solid var(--line)}
button.danger{background:transparent;color:var(--danger);padding:4px 8px}
button:disabled{opacity:.5;cursor:default}
.row{display:flex;gap:8px;flex-wrap:wrap;justify-content:center}
.bar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px}
.crumbs{flex:1;min-width:0;font-size:15px;word-break:break-all}
.crumbs a{color:var(--accent);text-decoration:none;cursor:pointer}
table{width:100%;border-collapse:collapse;font-size:14px}
td{padding:9px 6px;border-top:1px solid var(--line);vertical-align:middle}
td.n{word-break:break-all}
td.n a{color:var(--fg);text-decoration:none;cursor:pointer}
td.n a:hover{color:var(--accent)}
td.m{color:var(--muted);white-space:nowrap;text-align:right;font-size:13px}
td.a{width:1%;white-space:nowrap;text-align:right}
.empty{color:var(--muted);text-align:center;padding:24px}
#progress{display:none;margin-top:14px;text-align:left}
#progress .track{height:6px;background:var(--line);border-radius:3px;overflow:hidden}
#progress .fill{height:100%;width:0;background:var(--accent);transition:width .1s}
#progress .label{font-size:13px;color:var(--muted);margin-top:6px;word-break:break-all}
#toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:rgba(0,0,0,.8);color:#fff;padding:10px 16px;border-radius:10px;font-size:14px;display:none;max-width:90%}
@media(max-width:560px){td.m.d{display:none}}
</style>
</head>
<body>
<main>
  <h1>文件管理</h1>
  <p class="sub">上传的文件会保存到 iPhone 上的网站根目录，<a href="/" target="_blank" style="color:var(--accent)">打开网站首页 ↗</a></p>

  <div class="card">
    <div id="drop">
      <p>把文件或整个文件夹拖到这里，上传到当前目录<br>同名文件会被覆盖</p>
      <div class="row">
        <button onclick="pick.click()">选择文件</button>
        <button class="ghost" onclick="pickDir.click()">选择文件夹</button>
      </div>
      <div id="progress"><div class="track"><div class="fill"></div></div><div class="label"></div></div>
    </div>
    <input id="pick" type="file" multiple hidden>
    <input id="pickDir" type="file" webkitdirectory multiple hidden>
  </div>

  <div class="card">
    <div class="bar">
      <div class="crumbs" id="crumbs"></div>
      <button class="ghost" onclick="mkdir()">新建文件夹</button>
      <button class="ghost" onclick="load()">刷新</button>
    </div>
    <table id="list"></table>
  </div>
</main>
<div id="toast"></div>
<script>
const API = '/__admin/api/';
const GUARD = {'X-LocalServer': '1'};
let cwd = decodeURIComponent(location.hash.slice(1)) || '/';
let busy = false;

const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const join = (...p) => ('/' + p.join('/')).replace(/\/+/g, '/');
const encPath = p => p.split('/').map(encodeURIComponent).join('/');
const isHidden = path => path.split('/').some(s => s.startsWith('.'));

function toast(msg) {
  const t = $('#toast'); t.textContent = msg; t.style.display = 'block';
  clearTimeout(toast.timer); toast.timer = setTimeout(() => t.style.display = 'none', 2600);
}
function fmtSize(n) {
  if (n < 1024) return n + ' B';
  const u = ['KB','MB','GB']; let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return n.toFixed(n < 10 ? 1 : 0) + ' ' + u[i];
}
function fmtDate(ms) {
  const d = new Date(ms), z = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${z(d.getMonth()+1)}-${z(d.getDate())} ${z(d.getHours())}:${z(d.getMinutes())}`;
}

async function api(method, name, params) {
  const qs = new URLSearchParams(params).toString();
  const r = await fetch(API + name + '?' + qs, {method, headers: GUARD});
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

async function load() {
  location.hash = cwd === '/' ? '' : encodeURIComponent(cwd);
  const parts = cwd.split('/').filter(Boolean);
  let html = '<a data-p="/">根目录</a>';
  parts.forEach((p, i) => { html += ' / <a data-p="' + esc(join(...parts.slice(0, i + 1))) + '">' + esc(p) + '</a>'; });
  $('#crumbs').innerHTML = html;
  $('#crumbs').querySelectorAll('a').forEach(a => a.onclick = () => go(a.dataset.p));

  let data;
  try { data = await api('GET', 'list', {path: cwd}); }
  catch (e) { if (cwd !== '/') { cwd = '/'; return load(); } $('#list').innerHTML = '<tr><td class="empty">' + esc(e.message) + '</td></tr>'; return; }

  if (!data.items.length) { $('#list').innerHTML = '<tr><td class="empty">空文件夹，拖入文件即可上传</td></tr>'; return; }
  $('#list').innerHTML = data.items.map((it, i) => `
    <tr>
      <td class="n"><a data-i="${i}">${it.dir ? '📁' : '📄'} ${esc(it.name)}</a></td>
      <td class="m">${it.dir ? '' : fmtSize(it.size)}</td>
      <td class="m d">${fmtDate(it.mtime)}</td>
      <td class="a"><button class="danger" data-r="${i}" title="重命名">✎</button><button class="danger" data-d="${i}" title="删除">✕</button></td>
    </tr>`).join('');
  $('#list').querySelectorAll('a[data-i]').forEach(a => a.onclick = () => {
    const it = data.items[a.dataset.i], p = join(cwd, it.name);
    it.dir ? go(p) : window.open(encPath(p), '_blank');
  });
  $('#list').querySelectorAll('button[data-d]').forEach(b => b.onclick = () => remove(data.items[b.dataset.d]));
  $('#list').querySelectorAll('button[data-r]').forEach(b => b.onclick = () => rename(data.items[b.dataset.r]));
}
function go(p) { cwd = p; load(); }

async function mkdir() {
  const name = prompt('文件夹名称');
  if (!name) return;
  try { await api('POST', 'mkdir', {path: join(cwd, name)}); load(); } catch (e) { toast(e.message); }
}
async function remove(it) {
  if (!confirm(`确定删除「${it.name}」${it.dir ? '及其中所有内容' : ''}？`)) return;
  try { await api('POST', 'delete', {path: join(cwd, it.name)}); load(); } catch (e) { toast(e.message); }
}
async function rename(it) {
  const name = prompt('新名称', it.name);
  if (!name || name === it.name) return;
  try { await api('POST', 'move', {from: join(cwd, it.name), to: join(cwd, name)}); load(); } catch (e) { toast(e.message); }
}

function putFile(file, path, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PUT', API + 'file?path=' + encodeURIComponent(path));
    xhr.setRequestHeader('X-LocalServer', '1');
    xhr.upload.onprogress = e => e.lengthComputable && onProgress(e.loaded);
    xhr.onload = () => {
      if (xhr.status < 300) return resolve();
      let msg = xhr.statusText;
      try { msg = JSON.parse(xhr.responseText).error || msg; } catch (_) {}
      reject(new Error(msg));
    };
    xhr.onerror = () => reject(new Error('网络错误，手机上的 App 是否还在前台运行？'));
    xhr.send(file);
  });
}

async function uploadAll(entries) {
  entries = entries.filter(e => !isHidden(e.path));
  if (!entries.length || busy) return;
  busy = true;
  const total = entries.reduce((s, e) => s + e.file.size, 0) || 1;
  let done = 0, failed = 0;
  const box = $('#progress'), fill = box.querySelector('.fill'), label = box.querySelector('.label');
  box.style.display = 'block';
  for (const [i, e] of entries.entries()) {
    label.textContent = `(${i + 1}/${entries.length}) ${e.path}`;
    try {
      await putFile(e.file, join(cwd, e.path), loaded => fill.style.width = ((done + loaded) / total * 100) + '%');
    } catch (err) { failed++; toast(e.path + '：' + err.message); }
    done += e.file.size;
    fill.style.width = (done / total * 100) + '%';
  }
  label.textContent = failed ? `完成，${failed} 个文件失败` : `已上传 ${entries.length} 个文件`;
  setTimeout(() => { box.style.display = 'none'; fill.style.width = 0; }, 2500);
  busy = false;
  load();
}

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

const drop = $('#drop');
['dragenter', 'dragover'].forEach(t => drop.addEventListener(t, e => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach(t => drop.addEventListener(t, () => drop.classList.remove('over')));
drop.addEventListener('drop', async e => {
  e.preventDefault();
  // 必须在第一个 await 之前取出条目，之后 dataTransfer 会失效
  const roots = [...e.dataTransfer.items].map(i => i.webkitGetAsEntry && i.webkitGetAsEntry()).filter(Boolean);
  const files = [...e.dataTransfer.files];
  const out = [];
  if (roots.length) { for (const r of roots) await walk(r, '', out); }
  else files.forEach(f => out.push({file: f, path: f.name}));
  uploadAll(out);
});
document.addEventListener('dragover', e => e.preventDefault());
document.addEventListener('drop', e => e.preventDefault());

$('#pick').onchange = e => { uploadAll([...e.target.files].map(f => ({file: f, path: f.name}))); e.target.value = ''; };
$('#pickDir').onchange = e => { uploadAll([...e.target.files].map(f => ({file: f, path: f.webkitRelativePath || f.name}))); e.target.value = ''; };

load();
</script>
</body>
</html>
"""#
}

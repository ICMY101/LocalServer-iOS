import Foundation

enum WelcomePage {
    /// 旧版本示例页中的标题，用于识别并迁移未改动过的旧示例页
    static let legacyMarker = "🎉 服务器运行正常"

    /// 首次启动时写入 www/示例站点/index.html 的示例页
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>示例站点</title>
<style>
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--muted:#6e6e73;--accent:#0071e3;--line:#d2d2d7}
@media(prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#a1a1a6;--accent:#2997ff;--line:#38383a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue","PingFang SC",sans-serif;-webkit-font-smoothing:antialiased;line-height:1.47;letter-spacing:-.01em}
main{max-width:980px;margin:0 auto;padding:80px 22px 96px}
.eyebrow{font-size:17px;font-weight:600;color:var(--muted);margin:0 0 8px}
h1{font-size:56px;line-height:1.07;font-weight:700;letter-spacing:-.03em;margin:0 0 16px}
.lead{font-size:24px;line-height:1.35;color:var(--muted);margin:0 0 56px;max-width:700px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:20px}
.card{background:var(--card);border-radius:18px;padding:32px 30px}
.card .n{font-size:15px;font-weight:600;color:var(--muted)}
.card h2{font-size:24px;letter-spacing:-.02em;margin:6px 0 10px}
.card p{margin:0;color:var(--muted);font-size:17px}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em;color:var(--fg)}
a{color:var(--accent);text-decoration:none}
.foot{margin-top:56px;font-size:14px;color:var(--muted)}
@media(max-width:640px){main{padding:48px 18px 64px}h1{font-size:40px}.lead{font-size:19px;margin-bottom:40px}}
</style>
</head>
<body>
<main>
  <p class="eyebrow">示例站点</p>
  <h1>服务已经就绪。</h1>
  <p class="lead">这是 www 中的「示例站点」文件夹。每个文件夹都是一个独立的站点，通过 <code>/文件夹名/</code> 访问，并以自己为根目录。</p>

  <div class="grid">
    <div class="card">
      <span class="n">01</span>
      <h2>新建站点</h2>
      <p>在 App 的「文件」页导入文件夹或 zip，每个文件夹都会成为一个站点。</p>
    </div>
    <div class="card">
      <span class="n">02</span>
      <h2>从电脑上传</h2>
      <p>电脑和手机连接同一个 Wi-Fi，打开 App 中显示的电脑管理地址，输入配对码后拖入文件。</p>
    </div>
    <div class="card">
      <span class="n">03</span>
      <h2>以 / 开头的路径</h2>
      <p>站点里引用 <code>/css/app.css</code> 这样的路径时，会自动在本站点中查找，不需要修改代码。</p>
    </div>
    <div class="card">
      <span class="n">04</span>
      <h2>开启与关闭</h2>
      <p>在 App 中可以随时关闭某个站点，关闭后无法访问，也不会出现在站点列表里。</p>
    </div>
  </div>

  <p class="foot"><a href="/">查看所有站点 ›</a></p>
</main>
</body>
</html>
"""#

    /// 在 App 内新建 HTML 文件时使用的模板
    static let blankTemplate = #"""
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>新页面</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; padding: 24px; }
  </style>
</head>
<body>
  <h1>Hello, World!</h1>
</body>
</html>

"""#
}

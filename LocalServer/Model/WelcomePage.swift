import Foundation

enum WelcomePage {
    /// 首次启动时写入网站根目录的示例首页
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>本地服务器已运行</title>
<style>
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--muted:#6e6e73;--accent:#0a66d8}
@media(prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#a1a1a6;--accent:#4ea1ff}}
body{margin:0;font-family:-apple-system,system-ui,"PingFang SC",sans-serif;background:var(--bg);color:var(--fg);line-height:1.6}
main{max-width:640px;margin:0 auto;padding:40px 16px}
h1{font-size:28px;margin:0 0 8px}
.lead{color:var(--muted);margin:0 0 24px}
.card{background:var(--card);border-radius:14px;padding:18px 20px;margin-bottom:14px}
h2{font-size:17px;margin:0 0 6px}
p,li{color:var(--muted);margin:0;font-size:15px}
ol{padding-left:20px;margin:0}
code{background:rgba(127,127,127,.15);padding:1px 6px;border-radius:5px;font-size:14px;color:var(--fg)}
a{color:var(--accent)}
</style>
</head>
<body>
<main>
  <h1>🎉 服务器运行正常</h1>
  <p class="lead">这是示例页面 <code>index.html</code>，替换成你自己的文件即可。</p>

  <div class="card">
    <h2>方式一：在 App 里导入</h2>
    <p>打开「文件」标签页，点右上角 <b>+</b>，选择「导入文件」或「导入文件夹」。</p>
  </div>

  <div class="card">
    <h2>方式二：从电脑上传</h2>
    <ol>
      <li>电脑和手机连接同一个 Wi-Fi</li>
      <li>在电脑浏览器打开 App 中显示的「上传地址」（以 <code>/__admin/</code> 结尾）</li>
      <li>把文件或整个文件夹拖进网页</li>
    </ol>
  </div>

  <div class="card">
    <h2>方式三：用「文件」App</h2>
    <p>在 iPhone「文件」App 中打开 <b>我的 iPhone › 本地服务器 › www</b>，直接把文件拷进去。</p>
  </div>

  <div class="card">
    <h2>小提示</h2>
    <p>访问目录时会自动打开其中的 <code>index.html</code>；放一个 <code>404.html</code> 可以自定义找不到页面时的显示。</p>
  </div>
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

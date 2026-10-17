import Foundation

/// 服务器生成的网页（站点列表、目录列表、错误页）共用的样式：
/// 简洁、留白充足，参考苹果官网的排版，不使用渐变。
enum WebStyle {
    static let css = #"""
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#ffffff;--fg:#1d1d1f;--muted:#6e6e73;--line:#d2d2d7;--accent:#0071e3;--soft:#e8e8ed;--ok:#1d8a3a}
@media(prefers-color-scheme:dark){:root{--bg:#000000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#a1a1a6;--line:#38383a;--accent:#2997ff;--soft:#2c2c2e;--ok:#30d158}}
*{box-sizing:border-box}
html,body{margin:0}
body{background:var(--bg);color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue","PingFang SC","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased;line-height:1.47;letter-spacing:-.01em}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
main{max-width:980px;margin:0 auto;padding:72px 22px 96px}
.eyebrow{font-size:15px;font-weight:600;color:var(--muted);margin:0 0 8px}
h1{font-size:48px;line-height:1.08;font-weight:700;letter-spacing:-.03em;margin:0 0 14px}
.lead{font-size:21px;line-height:1.4;color:var(--muted);margin:0 0 48px;max-width:640px}
.pill{display:inline-flex;align-items:center;gap:6px;background:var(--accent);color:#fff;border-radius:980px;padding:9px 20px;font-size:15px;font-weight:500}
.pill:hover{text-decoration:none;opacity:.9}
.pill.secondary{background:var(--soft);color:var(--fg)}
.card{background:var(--card);border-radius:18px}
.foot{margin-top:56px;font-size:13px;color:var(--muted)}
@media(max-width:640px){main{padding:44px 18px 64px}h1{font-size:34px}.lead{font-size:17px;margin-bottom:32px}}
"""#

    /// 生成一个完整的 HTML 页面
    static func page(title: String, body: String, extraCSS: String = "") -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title.htmlEscaped)</title>
        <style>\(css)\(extraCSS)</style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

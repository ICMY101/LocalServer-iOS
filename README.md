# 本地服务器（LocalServer for iOS）

在 iPhone / iPad 上一键启动 HTTP 服务器，托管你的 HTML、CSS、JS、图片、视频等静态文件。

## 功能

- **静态网站服务**：自动打开 `index.html`，支持目录列表、自定义 `404.html`、SPA 回退（Vue/React history 路由）、CORS
- **视频/音频可拖动播放**：支持 HTTP Range 请求；支持 ETag/304 缓存验证，改完文件刷新就能看到
- **三种上传方式**
  1. App 内「文件」页 → `+` → 导入文件 / 导入文件夹
  2. 电脑浏览器打开 `http://手机IP:8080/__admin/`，拖拽文件或整个文件夹上传
  3. 系统「文件」App → 我的 iPhone → 本地服务器 → www
- **App 内浏览器预览**：支持 `alert/confirm/prompt`，iOS 16.4+ 可以用 Mac Safari 网页检查器调试
- **局域网访问**：显示 Wi-Fi 和个人热点地址，提供二维码，其他设备扫码即可访问
- **手机上编辑**：可以直接新建、编辑 HTML/CSS/JS 文本文件，也可以重命名、删除、分享
- **后台保活**（可选）：让服务器在后台持续运行
- 纯 Swift + SwiftUI + Network.framework 实现，**不依赖任何第三方库**，支持 iOS 16 及以上

---

## 没有 Mac，怎么得到 ipa？

iOS 应用只能在 macOS 上编译。本项目自带 GitHub Actions 配置，借用 GitHub 免费的 macOS 云主机编译出 ipa，全程只需要 Windows。

### 第 1 步：上传代码到 GitHub

1. 注册或登录 <https://github.com>，点右上角 **+ → New repository**，名称填 `LocalServer-iOS`，选择 **Public**。公开仓库使用 Actions 完全免费；私有仓库每月有免费额度，但 macOS 机器按 10 倍计时。
2. 在本目录打开终端执行（把 `你的用户名` 换成你自己的）：

   ```bash
   git init
   git add .
   git commit -m "LocalServer iOS"
   git branch -M main
   git remote add origin https://github.com/你的用户名/LocalServer-iOS.git
   git push -u origin main
   ```

   首次 push 会弹出浏览器窗口，登录 GitHub 授权即可。

### 第 2 步：等待云端编译（约 5–10 分钟）

打开仓库的 **Actions** 标签页，就能看到 “Build IPA” 正在运行。

- ✅ 变绿：点进本次运行，页面底部 **Artifacts** 区域有 `LocalServer-ipa`，下载后解压得到 `LocalServer.ipa`
- ❌ 变红：下载 `build-log`，或把 “编译（不签名）” 步骤中的 `error:` 信息复制出来，就能定位问题

想要固定的下载链接，可以打一个标签：`git tag v1.0 && git push --tags`，ipa 会自动发布到仓库的 **Releases** 页面。

### 第 3 步：签名并安装到 iPhone（Windows）

云端编译出的 ipa **没有签名**，需要用你自己的 Apple ID 签名后才能安装。任选一种方式：

| 工具 | 说明 |
| --- | --- |
| **Sideloadly**（推荐）<br><https://sideloadly.io> | 安装 iTunes 和 iCloud（官网版，不要用微软商店版），用数据线连接 iPhone，把 ipa 拖进 Sideloadly，填写 Apple ID 后点 Start |
| **AltStore**<br><https://altstore.io> | 在电脑上运行 AltServer，可以通过 Wi-Fi 自动续签 |
| **TrollStore** | 仅支持部分 iOS 版本，安装后永久有效，无需签名 |

安装完成后：

1. iPhone **设置 → 通用 → VPN 与设备管理**，信任你的 Apple ID
2. iOS 16 及以上需要打开 **设置 → 隐私与安全性 → 开发者模式**，并重启手机
3. 第一次打开 App 时会询问 **本地网络** 权限，请选择允许，否则其他设备无法访问

> 用免费 Apple ID 签名的 App **7 天后会失效**，到时用 Sideloadly 重新安装一次即可，数据不会丢失。付费开发者账号（每年 99 美元）签名的有效期为 1 年。

---

## 使用说明

1. 打开 App，服务器默认自动启动，端口为 `8080`
2. 「服务器」页会显示访问地址：
   - `http://127.0.0.1:8080/`：本机访问
   - `http://192.168.x.x:8080/`：同一 Wi-Fi 下的其他设备访问
   - `http://192.168.x.x:8080/__admin/`：在电脑上打开，用来上传文件
3. 网站根目录是 `www` 文件夹，首次启动时里面会生成一个示例 `index.html`

### 关于后台运行

iOS 会在 App 切到后台约 30 秒后把它挂起，服务器随之暂停。这一点会影响下面两种用法：

- **在本机 Safari 中打开**：切到 Safari 时本 App 就进入了后台，所以请优先使用 App 内置浏览器预览
- **给其他设备提供服务**：让 App 留在前台，可以在设置里开启“保持屏幕常亮”；或者开启“后台保活”（循环播放静音音频）。后者自用没有问题，但会增加耗电，上架 App Store 会被拒

App 回到前台后，服务器会自动恢复。

### 安全提示

“网页上传与管理”开启后，同一局域网内的任何人都可以访问 `/__admin/`。在公共 Wi-Fi 下请在设置中关闭它，或者关闭“允许局域网访问”。管理接口要求带自定义请求头，可以防止其他网站跨站篡改你的文件。

---

## 项目结构

```
LocalServer-iOS/
├── project.yml                 # XcodeGen 工程描述（CI 中用它生成 .xcodeproj）
├── Info.plist
├── .github/workflows/build-ipa.yml
└── LocalServer/
    ├── App/LocalServerApp.swift      # 入口和 TabView
    ├── Server/
    │   ├── HTTPServer.swift          # NWListener 监听与连接管理
    │   ├── HTTPConnection.swift      # HTTP/1.1 解析、keep-alive、大文件流式收发
    │   ├── HTTPMessage.swift         # 请求/响应模型
    │   ├── Router.swift              # 静态文件、目录列表、Range、ETag
    │   ├── AdminAPI.swift            # /__admin 上传管理接口
    │   ├── AdminPage.swift           # 电脑端上传页面
    │   └── MIMEType.swift
    ├── Model/                        # 设置、文件存储、网络地址、后台保活
    ├── Views/                        # 服务器页、文件页、设置页、内置浏览器、编辑器
    └── Assets.xcassets
```

如果以后有了 Mac：执行 `brew install xcodegen && xcodegen generate`，然后用 Xcode 打开 `LocalServer.xcodeproj` 即可运行和调试。

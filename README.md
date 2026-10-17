# 本地服务器（LocalServer for iOS）

在 iPhone / iPad 上一键启动 HTTP 服务器，托管你的 HTML、CSS、JS、图片、视频等静态文件。

## 功能

- **静态网站服务**：自动打开 `index.html`，支持目录列表、自定义 `404.html`、SPA 回退（Vue/React history 路由）、CORS
- **视频/音频可拖动播放**：支持 HTTP Range 请求和 ETag/304 缓存验证
- **四种上传方式**
  1. App 内「文件」页 → `+` → 导入文件 / 导入文件夹
  2. 电脑浏览器打开 `http://手机IP:8080/__admin/`，拖拽文件、整个文件夹或 zip 上传
  3. 在微信、QQ 等 App 中选择“用其他应用打开 › 本地服务器”
  4. 系统「文件」App → 我的 iPhone → 本地服务器 → www
- **zip 自动解压**：网页上传和 App 内导入都可以直接解压，兼容 Windows 打包的中文（GBK）文件名，并防止 zip 中的 `../` 路径写到网站目录之外
- **上传页访问密码**：可选设置，也可以一键生成 6 位随机密码；连续输错 5 次锁定 1 分钟
- **自动刷新（Live Reload）**：上传或修改文件后，正在浏览的页面自动重新加载
- **多网站切换**：长按任意文件夹，选择“设为网站根目录”
- **固定的 `.local` 地址**：通过 Bonjour 广播，尽量解析出 IP 变化后仍可使用的地址
- **App 内浏览器预览**：支持 `alert/confirm/prompt`，iOS 16.4+ 可以用 Mac Safari 网页检查器调试
- **局域网访问**：显示 Wi-Fi 和个人热点地址，提供二维码，其他设备扫码即可访问
- **手机上编辑**：可以直接新建、编辑 HTML/CSS/JS 文本文件，也可以重命名、删除、分享
- **后台保活**（可选）：让服务器在后台持续运行
- 基于 Swift + SwiftUI + Network.framework，唯一的第三方依赖是用于解压 zip 的 [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)，支持 iOS 16 及以上

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

   首次 push 会弹出浏览器窗口，登录 GitHub 授权即可。以后修改代码，只需 `git add . && git commit -m "说明" && git push`。

### 第 2 步：等待云端编译（约 10–15 分钟）

打开仓库的 **Actions** 标签页，就能看到 “Build IPA” 正在运行。流程是先编译 ipa 并上传，再在模拟器上运行单元测试。

- 点进本次运行，页面底部 **Artifacts** 区域有 `LocalServer-版本号-build构建号`，下载后解压得到 ipa。构建号等于 Actions 的运行次数，每次编译自动加 1，App 的“设置”页底部会显示当前版本，方便区分手机上装的是哪一版。
- ❌ 变红：如果 ipa 已经生成，说明是单元测试没通过，ipa 仍然可以下载；如果没有生成 ipa，说明编译失败。两种情况都可以下载 `logs`，或把出错步骤中 `error:` 开头的信息复制出来，就能定位问题。

想要固定的下载链接，可以打一个标签：`git tag v1.1 && git push --tags`，版本号会取标签中的数字，ipa 自动发布到仓库的 **Releases** 页面。

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
3. 第一次打开 App 时会询问 **本地网络** 权限，请选择允许，否则其他设备无法访问，`.local` 地址也无法使用

> 用免费 Apple ID 签名的 App **7 天后会失效**，到时用 Sideloadly 重新安装一次即可，数据和设置不会丢失。付费开发者账号（每年 99 美元）签名的有效期为 1 年。

---

## 使用说明

1. 打开 App，服务器默认自动启动，端口为 `8080`
2. 「服务器」页会显示访问地址：
   - `http://127.0.0.1:8080/`：本机访问
   - `http://192.168.x.x:8080/`：同一 Wi-Fi 下的其他设备访问
   - `http://xxx.local:8080/`：Bonjour 固定地址，能解析到时才显示
   - `http://192.168.x.x:8080/__admin/`：在电脑上打开，用来上传文件
3. 网站文件存放在 `www` 文件夹中，首次启动时会生成一个示例 `index.html`

### 多个网站

可以在 `www` 中为每个网站建一个文件夹，例如 `www/blog`、`www/demo`。在「文件」页长按其中一个，选择 **设为网站根目录**，这个文件夹就成为网站的根目录 `/`，网页里以 `/` 开头的路径也会指向它。在“设置 › 网站根目录”里可以恢复为 `www`。

### 从微信、QQ 接收文件

在聊天中打开文件，点右上角 **⋯ → 用其他应用打开**，选择「本地服务器」。如果列表中没有，可以先点“更多”把它添加进来。App 会弹出导入面板，可以选择保存到哪个文件夹，zip 也可以选择直接解压。

### 自动刷新

“设置 › 网站 › 文件变化后自动刷新页面”默认开启。开启后，HTML 页面中会插入一段很小的脚本，每秒检查一次网站文件有没有变化，有变化就自动刷新页面。在 App 内编辑保存、从电脑上传、或者通过「文件」App 修改都会触发。

### 关于 `.local` 地址

iOS 17 起，系统不再允许 App 直接读取设备的主机名。本 App 会在局域网中广播一个 Bonjour 服务，再反查它对应的 `.local` 主机名。部分网络（例如开启了客户端隔离的公共 Wi-Fi）或部分系统版本下可能解析不到，这时就只显示 IP 地址。电脑端访问 `.local` 地址需要系统支持 mDNS：macOS 和 iOS 原生支持，Windows 10/11 一般也可以使用。

### 关于后台运行

iOS 会在 App 切到后台约 30 秒后把它挂起，服务器随之暂停。这一点会影响下面两种用法：

- **在本机 Safari 中打开**：切到 Safari 时本 App 就进入了后台，所以请优先使用 App 内置浏览器预览
- **给其他设备提供服务**：让 App 留在前台，可以在设置里开启“保持屏幕常亮”；或者开启“后台保活”（循环播放静音音频）。后者自用没有问题，但会增加耗电，上架 App Store 会被拒

App 回到前台后，服务器会自动恢复。

### 安全提示

- 建议在“设置 › 上传”中设置访问密码，否则同一局域网中的任何人都能通过 `/__admin/` 上传或删除文件
- 访问密码通过普通 HTTP 传输，能防止同事随手访问，但不能防止有人在网络中抓包；在不信任的公共 Wi-Fi 下，建议关闭“网页上传与管理”或“允许局域网访问”
- 修改类管理接口要求带自定义请求头，可以防止其他网站跨站篡改你的文件

---

## 项目结构

```
LocalServer-iOS/
├── project.yml                 # XcodeGen 工程描述（CI 中用它生成 .xcodeproj）
├── Info.plist
├── .github/workflows/build-ipa.yml
├── LocalServer/
│   ├── App/LocalServerApp.swift      # 入口、TabView、接收其他 App 传来的文件
│   ├── Server/
│   │   ├── HTTPServer.swift          # NWListener 监听、连接管理、Bonjour 广播
│   │   ├── HTTPConnection.swift      # HTTP/1.1 解析、keep-alive、大文件流式收发
│   │   ├── HTTPMessage.swift         # 请求/响应模型
│   │   ├── Router.swift              # 静态文件、目录列表、Range、ETag、网站根目录
│   │   ├── LiveReload.swift          # 自动刷新脚本与文件指纹
│   │   ├── AdminAPI.swift            # /__admin 上传管理接口与登录
│   │   ├── AdminPage.swift           # 电脑端上传页面和登录页
│   │   └── MIMEType.swift
│   ├── Model/                        # 设置、文件存储、zip 解压、网络地址、Bonjour、后台保活
│   ├── Views/                        # 服务器页、文件页、设置页、导入面板、内置浏览器、编辑器
│   └── Assets.xcassets
└── Tests/                            # 单元测试与集成测试（在 CI 的模拟器上运行）
    ├── HTTPParsingTests.swift        # 请求解析、Range、路径穿越防护
    ├── ZipExtractorTests.swift       # GBK 文件名、zip slip、覆盖合并
    ├── MiscTests.swift               # 设置迁移、密码比较、Live Reload
    └── ServerIntegrationTests.swift  # 启动真实服务器，端到端测试各项功能
```

如果以后有了 Mac：执行 `brew install xcodegen && xcodegen generate`，然后用 Xcode 打开 `LocalServer.xcodeproj` 即可运行和调试，按 ⌘U 运行测试。

import SwiftUI
import WebKit

struct BrowserTarget: Identifiable {
    let id = UUID()
    let url: URL
    /// 服务器未运行时直接以 file:// 打开，需要指定可读取的目录
    var readAccessURL: URL? = nil
}

/// App 内置浏览器：预览网站时 App 保持在前台，服务器不会被系统挂起
struct BrowserView: View {
    let target: BrowserTarget
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WebViewModel()

    var body: some View {
        NavigationStack {
            WebViewContainer(webView: model.webView)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if model.isLoading {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                    }
                }
                .navigationTitle(model.title.isEmpty ? "预览" : model.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if let url = model.currentURL {
                                Button {
                                    UIPasteboard.general.string = url.absoluteString
                                } label: {
                                    Label("复制链接", systemImage: "doc.on.doc")
                                }
                                if url.scheme?.hasPrefix("http") == true {
                                    Button {
                                        UIApplication.shared.open(url)
                                    } label: {
                                        Label("在 Safari 中打开", systemImage: "safari")
                                    }
                                }
                            }
                            Button {
                                model.webView.reloadFromOrigin()
                            } label: {
                                Label("强制刷新", systemImage: "arrow.clockwise.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { model.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!model.canGoBack)
                        Spacer()
                        Button { model.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!model.canGoForward)
                        Spacer()
                        Text(model.currentURL?.absoluteString ?? "")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            if model.isLoading { model.webView.stopLoading() } else { model.webView.reload() }
                        } label: {
                            Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                        }
                    }
                }
        }
        .onAppear { model.load(target) }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class WebViewModel: NSObject, ObservableObject, WKUIDelegate {
    let webView: WKWebView

    @Published var title = ""
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0

    private var observations: [NSKeyValueObservation] = []
    private var didLoad = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) {
            // 允许用 Mac 上的 Safari 网页检查器调试
            webView.isInspectable = true
        }

        let sync: (WKWebView) -> Void = { [weak self] _ in
            Task { @MainActor in self?.syncState() }
        }
        observations = [
            webView.observe(\.title) { webView, _ in sync(webView) },
            webView.observe(\.url) { webView, _ in sync(webView) },
            webView.observe(\.canGoBack) { webView, _ in sync(webView) },
            webView.observe(\.canGoForward) { webView, _ in sync(webView) },
            webView.observe(\.isLoading) { webView, _ in sync(webView) },
            webView.observe(\.estimatedProgress) { webView, _ in sync(webView) },
        ]
    }

    func load(_ target: BrowserTarget) {
        guard !didLoad else { return }
        didLoad = true
        if let readAccessURL = target.readAccessURL {
            webView.loadFileURL(target.url, allowingReadAccessTo: readAccessURL)
        } else {
            webView.load(URLRequest(url: target.url))
        }
    }

    private func syncState() {
        title = webView.title ?? ""
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
    }

    // MARK: - WKUIDelegate

    /// target="_blank" 和 window.open 在当前页面中打开
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        if !present(alert) { completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        if !present(alert) { completionHandler(false) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        if !present(alert) { completionHandler(nil) }
    }

    private func present(_ alert: UIAlertController) -> Bool {
        guard var top = webView.window?.rootViewController else { return false }
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(alert, animated: true)
        return true
    }
}

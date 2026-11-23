import SwiftUI
import WebKit

/// 触点 2/5：WebView 容器 = 登录（ILogin 思想）+ 人工过码（验证恢复）共用入口。
/// 纪律：
///   ① WKWebView 一律主线程
///   ② 登录必须走持久 dataStore 的 WKWebView（SFSafariViewController 拿不到 Cookie，禁用）
///   ③ 登录结束后必须调 CookieStore.copyAllFromWebView 显式拷贝，否则网络层拿不到登录态
///   ④ 登录成功判定用 CookieStore.isLoggedInNow（与 Kotlin 侧同规则），不靠 URL 猜
///   ⑤ 地址可能失效（喜马拉雅改版过），所以支持多地址 + 自动切换
struct WebViewContainer: View {
    let urls: [URL]
    var onLoggedIn: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 极验滑块很小，给一句操作提示
                Text("登录时如果弹出拼图块，按住滑块拖到最右即可。滑块小的话可以双指放大页面。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.08))

                WebViewRepresentable(urls: urls, onLoggedIn: onLoggedIn)
                    .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("登录喜马拉雅")
            .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { onCancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("我已完成") { onLoggedIn() }
                    }
                }
        }
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let urls: [URL]
    var onLoggedIn: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // 极验滑块（GeeTest）需要这些能力，缺一个滑不动：
        //   ① inline media：验证码里可能有内联媒体
        //   ② JS 自动开窗：验证码偶尔用 window.open
        //   ③ 不限制 DOM 存储
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // 关闭「智能防跟踪」（ITP）。ITP 会拦第三方 cookie，
        // 极验的 challenge 走 award.xmcdn.com，可能因此拿不到 session。
        config.preferences.isFraudulentWebsiteWarningEnabled = false

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true

        // 滑块验证依赖手势与缩放，这两项必须放开
        view.scrollView.isScrollEnabled = true
        view.scrollView.bounces = true
        // 长按不要弹菜单，避免和滑块长按冲突
        view.allowsLinkPreview = false
        // 允许双指缩放：极验滑块只有 100×20pt，放大了才好拖
        view.scrollView.minimumZoomScale = 1.0
        view.scrollView.maximumZoomScale = 3.0

        // 真实移动 Safari UA：极验会按 UA 判断环境，写死假 UA 容易被判风险
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        context.coordinator.attach(webView: view)

        Task {
            for host in CookieStore.hosts {
                await CookieStore.restore(into: view, host: host)
            }
        }

        if let first = urls.first {
            view.load(URLRequest(url: first))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls, onLoggedIn: onLoggedIn)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let urls: [URL]
        let onLoggedIn: () -> Void
        private var fired = false
        private var triedURLs: Set<String> = []
        private weak var webView: WKWebView?

        init(urls: [URL], onLoggedIn: @escaping () -> Void) {
            self.urls = urls
            self.onLoggedIn = onLoggedIn
        }

        func attach(webView: WKWebView) { self.webView = webView }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                await CookieStore.copyAllFromWebView(webView)

                // 1) 已登录 → 直接回调
                if !fired, CookieStore.isLoggedInNow {
                    fired = true
                    onLoggedIn()
                    return
                }

                // 2) 页面无效（tengine 欢迎页 / 404）→ 换下一个地址
                let title = webView.title ?? ""
                let body = (try? await webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0,600) : ''") as? String) ?? ""
                if LoginEndpoints.looksInvalid(title, body) {
                    let current = webView.url?.absoluteString ?? ""
                    triedURLs.insert(current)
                    for candidate in urls where !triedURLs.contains(candidate.absoluteString) {
                        triedURLs.insert(candidate.absoluteString)
                        webView.load(URLRequest(url: candidate))
                        return
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fallback(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fallback(webView)
        }

        // P0-5（Swift 席）：302 跳转后 absoluteString 变化，
        // 按「整串相等」判候选会误判未试过的候选 → 循环重载。
        // 改成按 host 判定 + 8 次硬上限。
        private var reloadCount = 0
        private let maxReloads = 8

        private func fallback(_ webView: WKWebView) {
            guard reloadCount < maxReloads else { return } // 无限重载熔断
            reloadCount += 1
            let currentHost = webView.url?.host ?? ""
            let currentFull = webView.url?.absoluteString ?? ""
            triedURLs.insert(currentFull)
            for candidate in urls
            where candidate.host != currentHost && !triedURLs.contains(candidate.absoluteString) {
                triedURLs.insert(candidate.absoluteString)
                webView.load(URLRequest(url: candidate))
                return
            }
        }
    }
}

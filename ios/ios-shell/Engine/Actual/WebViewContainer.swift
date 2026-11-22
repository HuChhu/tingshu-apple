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
            WebViewRepresentable(urls: urls, onLoggedIn: onLoggedIn)
                .ignoresSafeArea(edges: .bottom)
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
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        // 移动版 UA：m.ximalaya.com/login 在移动 UA 下才会渲染出完整登录表单
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

        private func fallback(_ webView: WKWebView) {
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

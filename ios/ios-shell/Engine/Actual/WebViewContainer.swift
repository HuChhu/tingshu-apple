import SwiftUI
import WebKit

/// 触点 2/5：WebView 容器 = 登录（ILogin 思想）+ 人工过码（验证恢复）共用入口。
/// 纪律：
///   ① WKWebView 一律主线程
///   ② 登录必须走持久 dataStore 的 WKWebView（SFSafariViewController 拿不到 Cookie，禁用）
///   ③ 登录结束后必须调 CookieStore.copyAllFromWebView 显式拷贝，否则网络层拿不到登录态
///   ④ 登录成功判定用 CookieStore.isLoggedInNow（与 Kotlin 侧同规则），不靠 URL 猜
struct WebViewContainer: View {
    let url: URL
    /// 登录成功回调（已拷贝完 cookie）
    var onLoggedIn: () -> Void
    /// 用户取消
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            WebViewRepresentable(url: url, onLoggedIn: onLoggedIn)
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
    let url: URL
    var onLoggedIn: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 持久：登录态跨会话留存
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))

        // 已有 cookie 回灌进 WebView，避免用户重复登录
        Task {
            for h in CookieStore.hosts {
                await CookieStore.restore(into: view, host: h)
            }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onLoggedIn: onLoggedIn) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoggedIn: () -> Void
        private var fired = false

        init(onLoggedIn: @escaping () -> Void) { self.onLoggedIn = onLoggedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 每次导航完成都尝试同步一次：登录页是多步跳转，最终落在 www 或 m 域
            Task { @MainActor in
                await CookieStore.copyAllFromWebView(webView)
                if !fired, CookieStore.isLoggedInNow {
                    fired = true
                    onLoggedIn()
                }
            }
        }
    }
}

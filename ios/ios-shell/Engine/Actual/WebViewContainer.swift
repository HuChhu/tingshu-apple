import SwiftUI
import WebKit

/// 触点 2/5：WebView 容器 = 登录（ILogin 思想）+ 人工过码（验证恢复）共用入口。
/// 纪律：WKWebView 一律主线程；登录必须走持久 dataStore 的 WKWebView
/// （SFSafariViewController 拿不到 Cookie，禁用）；登录/过码完成后必须调
/// CookieStore.copyFromWebView 显式拷贝，否则网络层拿不到登录态。
struct WebViewContainer: View {
    let url: URL
    /// 完成回调：登录成功/人工过码后由宿主页面触发（周4 接 ILogin 流程）
    var onFinished: (() -> Void)?

    var body: some View {
        WebViewRepresentable(url: url, onFinished: onFinished)
            .ignoresSafeArea()
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    var onFinished: (() -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 持久：登录态与过码凭证跨会话留存
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

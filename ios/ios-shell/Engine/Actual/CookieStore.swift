import Foundation
import WebKit

/// 触点 3/5：Cookie 显式拷贝（iOS席纪律：两处存储互不相通）。
/// WKWebView 的 Cookie 落在 WKHTTPCookieStore；网络层（Darwin 引擎零配置）
/// 读 HTTPCookieStorage.shared。方向 1：登录/过码后 WebView → 共享存储；
/// 方向 2：需要 WebView 复用既有登录态时共享存储 → WebView 回灌。
enum CookieStore {
    /// WebView → 共享存储，按 host 精确过滤（头部纪律同源：不匹配不拷）
    static func copyFromWebView(_ webView: WKWebView, host: String) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { c.resume(returning: $0) }
        }
        for cookie in cookies where cookie.domain.hasSuffix(host) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// 共享存储 → WebView 回灌，按 host 精确过滤
    static func restore(into webView: WKWebView, host: String) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.hasSuffix(host) {
            await store.setCookie(cookie)
        }
    }
}

/// CookieProvider 注入点（契约 v1.1 新接口，对照表 §二4）。
/// M3 阶段注册本 stub：cookie() 返回 nil = 匿名，引擎自动预检 Auth（零请求硬证）；
/// M4 接登录流程后换成真实现（从 HTTPCookieStorage.shared 拼 host Cookie 串）。
/// 桥接纪律：suspend 方法 = completionHandler 异步形态；签名以 framework 头对拍为准，
/// 有出入只动本类，不动调用方。
final class CookieProviderStub: NSObject {
    // func cookie(completionHandler: @escaping (String?, Error?) -> Void) {
    //     completionHandler(nil, nil)   // nil = 匿名预检
    // }
    // func refresh(completionHandler: @escaping (KotlinUnit?, Error?) -> Void) {
    //     completionHandler(nil, nil)   // 引擎 401/isNeedLogin 时调用一次，不重试
    // }
}

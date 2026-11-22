import Foundation
import WebKit

/// 触点 3/5：Cookie 显式拷贝（iOS席纪律：两处存储互不相通）。
/// WKWebView 的 Cookie 落在 WKHTTPCookieStore；网络层（Darwin 引擎）读的是
/// URLSession 共享的 HTTPCookieStorage.shared。方向 1：登录/过码后 WebView → 共享存储；
/// 方向 2：需要 WebView 复用既有登录态时共享存储 → WebView 回灌。
enum CookieStore {
    /// 需要覆盖的域名（与 Kotlin 侧 XimalayaSessionRules.COOKIE_URLS 一致）
    static let hosts = ["www.ximalaya.com", "m.ximalaya.com", "passport.ximalaya.com", "ximalaya.com"]

    /// host 精确匹配：cookie.domain 为 host 本身，或为以 '.' 开头的父域后缀。
    /// 不匹配一律不拷（头部纪律同源：宁缺勿滥）。
    static func domainMatches(_ cookieDomain: String?, _ host: String) -> Bool {
        guard let cd = cookieDomain?.lowercased(), !host.isEmpty else { return false }
        let h = host.lowercased()
        if cd == h { return true }
        if cd.hasPrefix(".") { return h.hasSuffix(cd) || h == String(cd.dropFirst()) }
        return false
    }

    /// WebView → 共享存储，按 host 精确过滤（头部纪律同源：不匹配不拷）
    static func copyFromWebView(_ webView: WKWebView, host: String) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { c.resume(returning: $0) }
        }
        for cookie in cookies where domainMatches(cookie.domain, host) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// 多 host 全量同步（登录结束调用：passport / www / m 三个域都要拉）
    static func copyAllFromWebView(_ webView: WKWebView) async {
        for h in hosts { await copyFromWebView(webView, host: h) }
    }

    /// 共享存储 → WebView 回灌，按 host 精确过滤
    static func restore(into webView: WKWebView, host: String) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where domainMatches(cookie.domain, host) {
            await store.setCookie(cookie)
        }
    }

    /// 当前共享存储里属于喜马拉雅的 cookie（只读快照）
    static func ximalayaCookies() -> [HTTPCookie] {
        (HTTPCookieStorage.shared.cookies ?? []).filter { c in
            hosts.contains { domainMatches(c.domain, $0) }
        }
    }

    /// 拼成 Cookie 头的扁平字典（name -> value）
    static func flatMap() -> [String: String] {
        var out: [String: String] = [:]
        for c in ximalayaCookies() { out[c.name] = c.value }
        return out
    }

    /// 清空所有已存的喜马拉雅 cookie（登出）
    static func clearAll() {
        for c in ximalayaCookies() { HTTPCookieStorage.shared.deleteCookie(c) }
    }

    /// 登录态判定（与 Kotlin 侧 XimalayaSessionRules.isLoggedIn 同规则：
    /// 有 1&_token 即登录；或 xmly + 1&_device 同时在。）
    static func isLoggedIn(_ cookies: [String: String]) -> Bool {
        if cookies["1&_token"] != nil { return true }
        return cookies["xmly"] != nil && cookies["1&_device"] != nil
    }

    static var isLoggedInNow: Bool { isLoggedIn(flatMap()) }
}

/// 引擎 CookieProvider 的 iOS 实现。
///
/// 契约（framework 头文件 Shared.h:204-219）：
///   - cookieWithCompletionHandler:((NSString?, NSError?)) -> Void
///   - refreshWithCompletionHandler:((NSError?)) -> Void
/// 两个都是 suspend 函数，K/N 只导出回调形态。
///
/// 行为：
///   - cookie() 返回 "k1=v1; k2=v2" 形式，键排序保证输出稳定；无 cookie 时返回 nil（匿名）
///   - refresh() 只清缓存，不代登录：引擎收到 401/isNeedLogin 时调一次，不重试
final class XimalayaCookieProvider: NSObject, CookieProvider {

    /// 缓存最近一次读到的串，避免每次请求都遍历 Cookie 存储
    private var cached: String?
    private let lock = NSLock()

    override init() { super.init() }

    func cookie(completionHandler: @escaping (String?, (any Error)?) -> Void) {
        lock.lock()
        if let c = cached { lock.unlock(); completionHandler(c, nil); return }
        lock.unlock()

        let flat = CookieStore.flatMap()
        guard CookieStore.isLoggedIn(flat) else {
            // 未登录：返回 nil，引擎走匿名预检（不白发请求）
            completionHandler(nil, nil)
            return
        }
        let header = flat.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")

        lock.lock(); cached = header; lock.unlock()
        completionHandler(header, nil)
    }

    func refresh(completionHandler: @escaping ((any Error)?) -> Void) {
        lock.lock(); cached = nil; lock.unlock()
        completionHandler(nil)
    }

    /// 登录页关闭后调用：丢弃缓存，下次 cookie() 重读存储
    func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }
}

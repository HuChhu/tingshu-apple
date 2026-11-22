import Foundation

/// 喜马拉雅登录页地址（按优先级排列，WebView 加载失败会自动换下一个）。
///
/// 为什么要有多个：
///   passport.ximalaya.com/page/mobile_login 已 404（登录页迁移过）；
///   passport.ximalaya.com 根路径只剩 tengine 默认欢迎页（"Welcome to tengine!"），
///   所以不能再用旧地址。下面是实测可用的：
///
///   https://m.ximalaya.com/login   200，React 登录页，含手机号/验证码/密码
///   https://www.ximalaya.com/login 200，PC 版登录页
enum LoginEndpoints {
    static let candidates: [URL] = [
        // 真实登录页（实测：m.ximalaya.com/login 会 302 到这里）
        // 直接加载可省一跳，且这是唯一渲染出完整表单的地址
        URL(string: "https://passport.ximalaya.com/page/m/login")!,
        URL(string: "https://m.ximalaya.com/login")!,
        URL(string: "https://www.ximalaya.com/login")!,
    ]

    /// 判定一个页面是否是「登录失败/无效页」，用于自动切换备用地址
    /// 典型无效页：tengine 欢迎页、404 页
    static func looksInvalid(_ title: String, _ body: String) -> Bool {
        let t = title.lowercased()
        if t.contains("tengine") { return true }
        if t.contains("404") { return true }
        if body.contains("Welcome to tengine") { return true }
        if body.contains("您查看的内容不存在") { return true }
        return false
    }

    /// 判定是否已经完成登录（读 cookie，与 Kotlin 侧同规则）
    static var isLoggedIn: Bool { CookieStore.isLoggedInNow }
}

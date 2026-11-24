import SwiftUI
import WebKit

// MARK: - 会员等级（v1.4.4）

/// 会员等级。**未知必须是一个显式状态**，不能拿「有会员」当默认值 ——
/// v1.4.3 的「可听会员内容」就是把"已登录"错当成了"是会员"，等于对用户说谎。
enum VipTier: Equatable {
    case unknown            // 已登录但拿不到会员状态
    case none               // 未开通
    case standard           // 普通会员
    case platinum           // 白金会员
    case master             // 大师会员
    case child              // 儿童会员

    var title: String {
        switch self {
        case .unknown: return "已登录喜马拉雅"
        case .none: return "未开通会员"
        // 分不出档位就不声称档位。"
        case .standard, .platinum, .master, .child: return "喜马拉雅会员"
        }
    }
}

/// 会员状态快照
struct VipStatus: Equatable {
    var tier: VipTier = .unknown
    /// 到期日（页面只给「2026-03-01 到期」这类文案时也能填）
    var expireDate: Date?
    /// 页面原文命中片段，出问题能一眼看出判的是哪句
    var evidence: String = ""

    /// 卡片副标题。规则：
    ///   · 有到期日 → 「有效期至 yyyy-MM-dd」
    ///   · 没有到期日但知道等级 → 只是等级本身，不编造日期
    ///   · 未知 → 「会员状态未知」（绝不说「可听会员内容」）
    var subtitle: String {
        switch tier {
        case .unknown: return "会员状态未知"
        case .none: return "当前账号没有会员"
        default:
            if let d = expireDate {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                return "有效期至 " + f.string(from: d)
            }
            return "会员已开通"
        }
    }
}

// MARK: - 探测（路线 A：WebView 读 DOM）

/// 用 WKWebView 打开会员页，等 JS 渲染完，选 innerText 里的等级/到期文案。
///
/// 为什么不用接口：v1.4.3 期间实测 8 个候选接口（vipInfo / mpay/status / revision/member…）
/// 全部 404 或返回无关数据，路径没有公开文档可依。页面 DOM 是唯一稳定来源：
/// 用户已登录时 Cookie 在持久化 dataStore 里，页面会自己渲染出真实等级。
@MainActor
final class VipStatusProbe: NSObject {

    static let shared = VipStatusProbe()

    /// 会员中心（页面自带登录态判断）
    private static let url = URL(string: "https://www.ximalaya.com/vip")!

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<VipStatus, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var settled = false

    /// 抓页面文本。总超时 12s（会员页带一堆脚本，比普通页慢）。
    func probe() async -> VipStatus {
        if continuation != nil { return VipStatus() }   // 已有探测在跑：不叠加第二个 WebView
        return await withCheckedContinuation { (cont: CheckedContinuation<VipStatus, Never>) in
            continuation = cont
            settled = false

            let view = makeWebView()
            webView = view
            view.load(URLRequest(url: Self.url))

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12 * 1_000_000_000)
                guard let self, !self.settled else { return }
                // 超时也要把页面已经渲染的字抓一遍：慢不等于空
                let text = await self.readText() ?? ""
                self.finish(Self.parse(text))
            }
        }
    }

    private func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()        // 复用登录 Cookie
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        view.navigationDelegate = self
        return view
    }

    /// 等 3 轮再读：会员页是 SPA，didFinish 之后还在拉会员接口。
    private func readText() async -> String? {
        for delay in [0.8, 1.6, 2.4] {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if let s = await evaluate("document.body ? document.body.innerText : ''"),
               !s.isEmpty, s.count > 40 {
                return s
            }
        }
        return await evaluate("document.body ? document.body.innerText : ''")
    }

    private func evaluate(_ js: String) async -> String? {
        guard let view = webView else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            view.evaluateJavaScript(js) { value, _ in
                c.resume(returning: value as? String)
            }
        }
    }

    private func finish(_ status: VipStatus) {
        guard !settled else { return }
        settled = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView = nil                     // 释放 WebView（不保留第二个实例）
        let c = continuation
        continuation = nil
        c?.resume(returning: status)
    }

    // MARK: 文本 → 等级

    /// 公开给单测/日志用：把一段页面文本判成等级。
    /// 判定顺序很关键：**先判"开通/续费"这类营销文案，再判等级词**，
    /// 否则未登录页的「开通 VIP」会被误判成"有会员"。
    static func parse(_ text: String) -> VipStatus {
        let t = text.replacingOccurrences(of: "\u{00a0}", with: " ")
        if t.isEmpty { return VipStatus(tier: .unknown, evidence: "页面无文本") }

        // ① 明确的等级词（带到期信息时优先级最高）
        // 【不猜档位】qa-kotlin2 实测：桌面站 8 个 JS 包（2.8MB）全扫 vipLevel/memberLevel 零命中，
        // 移动端会员页搜「白金 / 大师 / 儿童会员」全部 0 命中；接口里含 vip 的只有布尔 isVip。
        // 所以这里**只判「是不是会员」**，不按词分档。写「白金会员」就是编的。
        let tiers: [(String, VipTier)] = [
            ("会员", .standard), ("VIP", .standard), ("续费", .standard),
        ]
        // ② 反向词：出现这些说明没开通
        let notMembers: [String] = ["开通会员", "立即开通", "开通VIP", "开通 VIP", "续费", "立即续费", "开通超级会员", "未开通"]

        let hasExpire = t.range(of: "有效期至") != nil || t.range(of: "到期") != nil
        let expireDate = findDate(in: t)

        for (kw, tier) in tiers where t.contains(kw) {
            // 命中「续费/开通」且没有到期信息 → 视为未开通（营销页）
            let looksLikeMarketing = notMembers.contains { t.contains($0) } && !hasExpire
            if looksLikeMarketing && tier == .standard { break }
            return VipStatus(tier: tier, expireDate: expireDate,
                             evidence: snippet(t, around: kw))
        }

        // ③ 只剩「开通」类文案 → 未开通
        if let hit = notMembers.first(where: { t.contains($0) }) {
            return VipStatus(tier: .none, evidence: snippet(t, around: hit))
        }
        return VipStatus(tier: .unknown, evidence: String(t.prefix(60)))
    }

    private static func findDate(in t: String) -> Date? {
        // 匹配 2026-03-01 / 2026.03.01 / 2026年3月1日
        let patterns = [
            "(\\d{4})-(\\d{1,2})-(\\d{1,2})",
            "(\\d{4})\\.(\\d{1,2})\\.(\\d{1,2})",
            "(\\d{4})年(\\d{1,2})月(\\d{1,2})日",
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  m.numberOfRanges == 4,
                  let y = Range(m.range(at: 1), in: t),
                  let mo = Range(m.range(at: 2), in: t),
                  let d = Range(m.range(at: 3), in: t),
                  let year = Int(t[y]), let month = Int(t[mo]), let day = Int(t[d]) else { continue }
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            if let date = Calendar(identifier: .gregorian).date(from: comps) { return date }
        }
        return nil
    }

    private static func snippet(_ text: String, around kw: String) -> String {
        guard let r = text.range(of: kw) else { return String(text.prefix(60)) }
        let lo = text.index(r.lowerBound, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: 24, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lo..<hi]).replacingOccurrences(of: "\n", with: " ")
    }
}

extension VipStatusProbe: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let text = await readText() ?? ""
            finish(Self.parse(text))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(VipStatus(tier: .unknown, evidence: "页面加载失败：" + error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(VipStatus(tier: .unknown, evidence: "页面加载失败：" + error.localizedDescription))
    }
}

// MARK: - 缓存（避免每次进「我的」都开 WebView）

/// 会员状态缓存：5 分钟内存缓存 + UserDefaults 落盘（冷启动先用旧值，再后台更新）。
enum VipStatusStore {
    private static let key = "dsp.vipStatus.v1"
    private static let ttl: TimeInterval = 5 * 60

    static func cached() -> (status: VipStatus, at: Date)? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let box = try? JSONDecoder().decode(Box.self, from: data) else { return nil }
        return (box.status, box.at)
    }

    static func save(_ s: VipStatus) {
        guard let data = try? JSONEncoder().encode(Box(status: s, at: Date())) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func isFresh(_ at: Date) -> Bool { Date().timeIntervalSince(at) < ttl }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Codable 包装（VipStatus 里有 Date? 与 enum，直接编码成 String 等级更稳）
    private struct Box: Codable {
        let tier: String
        let expire: Double?
        let evidence: String
        let at: Date

        init(status: VipStatus, at: Date) {
            switch status.tier {
            case .unknown: tier = "unknown"
            case .none: tier = "none"
            case .standard: tier = "standard"
            case .platinum: tier = "platinum"
            case .master: tier = "master"
            case .child: tier = "child"
            }
            expire = status.expireDate?.timeIntervalSince1970
            evidence = status.evidence
            self.at = at
        }

        var status: VipStatus {
            let t: VipTier
            switch tier {
            case "none": t = .none
            case "standard": t = .standard
            case "platinum": t = .platinum
            case "master": t = .master
            case "child": t = .child
            default: t = .unknown
            }
            return VipStatus(tier: t,
                             expireDate: expire.map { Date(timeIntervalSince1970: $0) },
                             evidence: evidence)
        }
    }
}

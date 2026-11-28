import SwiftUI
import UIKit
import Foundation

/// 「我的」：账号 + 二级入口（源管理、播放设置、缓存、日志、关于）。
/// 设计原则（按用户反馈）：设置项收进二级页，首页只留一级入口，一眼能扫完。
struct MineView: View {
    @State private var loggedIn = SharedBridge.loggedIn
    @State private var cacheBytes: Int64 = AudioCache.totalBytes()
    @State private var logBytes: Int64 = CrashLog.totalBytes
    @State private var favCount = 0
    /// 会员状态：先读缓存立刻显示，再后台探测（探测走 WebView 读会员页 DOM）
    @State private var vip: VipStatus = VipStatusStore.cached()?.status ?? VipStatus()
    @State private var probingVip = false

    var body: some View {
        NavigationStack {
            List {
                // 账号卡：整块可点进「账号与通用」（方案 §3.6：不再额外加一行「账号设置」）
                Section {
                    // 账号卡即「账号与通用」入口
                    NavigationLink {
                        SettingsView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: accountIcon)
                                .font(.system(size: 30))
                                .foregroundStyle(accountColor)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                // v1.4.4：标题显示**真实会员等级**，不是「已登录」。
                                // 旧文案「可听会员内容」把"已登录"当成了"是会员"，
                                // 对没有会员的账号是错误陈述。
                                Text(accountTitle)
                                    .font(.headline)
                                Text(accountSubtitle)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // 内容与服务（方案 §3.6：首屏最多 5 个入口；收藏/历史已在书架，这里不重复）
                Section("内容与服务") {
                    NavigationLink {
                        SourcesView()
                    } label: {
                        Label("书源管理", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        CachePage()
                    } label: {
                        HStack {
                            Label("缓存管理", systemImage: "internaldrive")
                            Spacer()
                            Text(byteText(cacheBytes)).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }

                // 「账号与通用」不在这里重复：账号卡本身已经是指向它的 NavigationLink，
                // 再加一行就是两个入口通同一个页面（方案 §3.6：账号卡本身可点击，不再额外加行）
                Section("偏好") {
                    NavigationLink {
                        PlaybackSettingsPage()
                    } label: {
                        Label("播放设置", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        ThemePage()
                    } label: {
                        HStack {
                            Label("外观配色", systemImage: "paintpalette")
                            Spacer()
                            Text(Theme.current.name)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        LogViewerPage()
                    } label: {
                        HStack {
                            Label("运行日志", systemImage: "doc.text.magnifyingglass")
                            Spacer()
                            Text(byteText(logBytes)).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                } header: {
                    Text("支持")
                } footer: {
                    Text("闪退或播放出错时导出日志；分享前请检查隐私信息。")
                        .font(.caption2)
                }
            }
            .navigationTitle("我的")
            .onAppear {
                loggedIn = SharedBridge.loggedIn
                cacheBytes = AudioCache.totalBytes()
                logBytes = CrashLog.totalBytes
                favCount = LocalStore.loadFavorites().count
                refreshVipIfNeeded(force: false)
            }
            // 登录/登出后，旧的会员缓存必然失效
            .onReceive(NotificationCenter.default.publisher(for: .loginStateChanged)) { _ in
                loggedIn = SharedBridge.loggedIn
                VipStatusStore.clear()
                vip = VipStatus()
                refreshVipIfNeeded(force: true)
            }
            // 下拉刷新：强制重探一次
            .refreshable {
                loggedIn = SharedBridge.loggedIn
                refreshVipIfNeeded(force: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioCacheCleared)) { _ in
                cacheBytes = AudioCache.totalBytes()
            }
        }
    }

    // MARK: - 账号卡文案（会员状态）

    private var accountTitle: String {
        guard loggedIn else { return "未登录" }
        switch vip.tier {
        case .unknown: return "已登录喜马拉雅"
        case .none: return "未开通会员"
        default: return vip.tier.title
        }
    }

    private var accountSubtitle: String {
        guard loggedIn else { return "登录后可听会员专辑" }
        if probingVip && vip.tier == .unknown { return "正在查询会员状态…" }
        return vip.subtitle
    }

    private var accountIcon: String {
        guard loggedIn else { return "person.crop.circle.badge.questionmark" }
        switch vip.tier {
        case .unknown, .none: return "person.crop.circle"
        case .child: return "figure.and.child.holdinghands"
        case .master, .platinum: return "seal.fill"
        case .standard: return "checkmark.seal.fill"
        }
    }

    private var accountColor: Color {
        guard loggedIn else { return .secondary }
        switch vip.tier {
        case .unknown, .none: return .secondary
        case .standard, .platinum, .master, .child: return .green
        }
    }

    /// 缓存新鲜就不探测；否则后台跑一次 WebView 探针。
    /// 探测失败 → 保持「会员状态未知」，绝不回落到「可听会员内容」那种默认值。
    private func refreshVipIfNeeded(force: Bool) {
        guard loggedIn else { return }
        if !force, let c = VipStatusStore.cached(), VipStatusStore.isFresh(c.at) {
            vip = c.status
            return
        }
        if probingVip { return }
        probingVip = true
        Task {
            // 【2026-11-25】先走接口。接口能明确回答「是 / 不是会员」时就不再开 WebView ——
            // 会员页的 innerText 里人人都有「开通会员」，靠它判会员就是碰运气。
            let api = await SharedBridge.vipStatus()
            let s: VipStatus
            switch api.tier {
            case "standard":
                s = VipStatus(tier: .standard, expireDate: parseExpire(api.expire),
                              evidence: "api:" + api.source)
            case "none":
                s = VipStatus(tier: .none, evidence: "api:" + api.source)
            case "notLoggedIn":
                s = VipStatus(tier: .unknown, evidence: "api:未登录")
            default:
                // 接口没给出结论 → 才去看页面
                s = await VipStatusProbe.shared.probe()
            }
            await MainActor.run {
                probingVip = false
                // 探测出 unknown 时不覆盖已有缓存（可能是网络抖，旧值更可信）
                if s.tier != .unknown {
                    vip = s
                    VipStatusStore.save(s)
                } else if !force {
                    vip = VipStatus(tier: .unknown, evidence: s.evidence)
                }
                CrashLog.write("VIP", "tier=\(vip.tier.title) evidence=\(s.evidence.prefix(60))")
            }
        }
    }

    /// 接口给的到期日是 "2026-03-01" 这种；解析不出来就返回 nil（不编日期）。
    /// 2026-11-25：1900 年以前的值一律丢弃 —— 后端用 0 表示“没有到期时间”，
    /// 换算成 epoch 就是 1970-01-01，界面上会写成「有效期至 1970-01-01」，等于胡说。
    private func parseExpire(_ t: String) -> Date? {
        let s = String(t.prefix(10))
        guard s.count == 10 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: s) else { return nil }
        guard d.timeIntervalSince1970 > 1_000_000_000 else { return nil }   // 2001 年前不可能是真到期日
        return d
    }
    private func byteText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - 二级页

/// 收藏列表
struct FavoritesPage: View {
    @State private var items: [LocalStore.Favorite] = []

    var body: some View {
        Group {
            if items.isEmpty {
                // 空态给明确去向（方案 §3.3：空态按钮有明确去向）
                ContentUnavailableView {
                    Label("还没有收藏", systemImage: "heart")
                } description: {
                    Text("在专辑详情页右上角点心形收藏")
                } actions: {
                    NavigationLink("去分类找书") { CategoryView() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(items) { f in
                    NavigationLink {
                        AlbumView(card: SharedBridge.BookCard(
                            bookUrl: f.bookUrl, title: f.title, author: f.author,
                            coverUrl: f.coverUrl, albumId: f.albumId,
                            trackCount: 0, playCount: 0, isFinished: nil),
                                  sourceId: f.sourceId)
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: Layout.coverURL(f.coverUrl)) { img in
                                img.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                            }
                            .frame(width: Layout.thumbRow, height: Layout.thumbRow)
                            .clipShape(RoundedRectangle(cornerRadius: Layout.radiusThumb))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.title).font(.body).lineLimit(2)
                                Text(f.author).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("我的收藏")
        .onAppear { items = LocalStore.loadFavorites() }
    }
}

/// 播放历史
struct HistoryPage: View {
    @State private var items: [LocalStore.Recent] = []

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("还没有播放记录", systemImage: "clock",
                                       description: Text("点一集开始播放就会记录"))
            } else {
                List {
                    ForEach(items) { r in
                        HStack(spacing: 12) {
                            Button {
                                play(r)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.bookTitle).font(.body).lineLimit(1)
                                    Text(r.episodeTitle).font(.subheadline).lineLimit(1)
                                    Text(r.playedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            // 右侧独立播放按钮：热区 44pt，和整行点击同一个动作
                            Button {
                                play(r)
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(.title3)
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("续播 \(r.episodeTitle)")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                LocalStore.removeRecent(id: r.id)
                                items = LocalStore.loadRecent()
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("播放历史")
        .onAppear { items = LocalStore.loadRecent() }
    }

    /// 续播：还原一集交给播放器，再展开全屏页。
    /// 以前这里直接用 LocalStore.recentEpisode，但老记录 episodeUrl 为空时
    /// url 是空的 → 引擎拿到空地址直接失败，表现为「点了没反应」。
    /// 现在 recentEpisode 内部已做 episodeUrl → trackId → bookUrl 回退。
    private func play(_ r: LocalStore.Recent) {
        Player.shared.playEpisode(LocalStore.recentEpisode(r),
                                  book: LocalStore.recentBook(r),
                                  sourceId: r.sourceId)
        Player.shared.showFullScreen = true
    }
}

/// 缓存管理（原「下载管理」占位页）。
/// 之前标题写「下载管理」但只有一句自动缓存说明 —— 等于展示了一个不存在的能力。
/// 现在按方案 §3.6 诚实命名为「缓存管理」：列真实目录大小、可单删、可全清。
struct CachePage: View {
    @State private var entries: [LocalStore.CacheEntry] = []
    @State private var total: Int64 = 0
    @State private var autoCacheNext = AudioCache.loadSettings().autoCacheNext
    @State private var maxPerBook = AudioCache.loadSettings().maxEpisodesPerBook
    @State private var confirmClearAll = false

    var body: some View {
        List {
            Section {
                LabeledContent("已用空间", value: AudioCache.humanSize(total))
                if entries.isEmpty {
                    Text("还没有缓存音频。播放时开启「自动缓存」会把接下来几集存到本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("总览")
            }

            if !entries.isEmpty {
                Section("按专辑") {
                    ForEach(entries) { e in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.body).lineLimit(1)
                                Text("\(e.files) 个文件").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(AudioCache.humanSize(e.bytes))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                AudioCache.removeDir(named: e.id)
                                reload()
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
            }

            Section("自动缓存") {
                Toggle("播放时缓存后续章节", isOn: $autoCacheNext)
                    .onChange(of: autoCacheNext) { _, v in
                        var s = AudioCache.loadSettings(); s.autoCacheNext = v; AudioCache.saveSettings(s)
                    }
                Stepper("每本书最多 \(maxPerBook) 集", value: $maxPerBook, in: 1...50)
                    .onChange(of: maxPerBook) { _, v in
                        var s = AudioCache.loadSettings(); s.maxEpisodesPerBook = v; AudioCache.saveSettings(s)
                    }
                Text("新建缓存按这里设置清理，已有缓存下次播放时再按新值收敛。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                Button("清除所有缓存", role: .destructive) { confirmClearAll = true }
                    .disabled(total == 0)
            } footer: {
                Text("清除后不影响收藏与播放进度，下次播放会重新下载。")
                    .font(.caption2)
            }
        }
        .navigationTitle("缓存管理")
        .onAppear { reload() }
        .confirmationDialog("清除所有音频缓存？", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                AudioCache.clearAll()
                NotificationCenter.default.post(name: .audioCacheCleared, object: nil)
                reload()
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 把磁盘目录还原成「书名」：目录名是 hash，用收藏/最近/进度里记过的 bookUrl 反查
    private func reload() {
        let known = LocalStore.knownBookUrls()
        var byName: [String: (bookUrl: String, title: String)] = [:]
        for k in known {
            byName[AudioCache.stableName(k.bookUrl)] = (k.bookUrl, k.title)
        }
        var out: [LocalStore.CacheEntry] = []
        var sum: Int64 = 0
        for d in AudioCache.listDirs() {
            let hit = byName[d.dirName]
            // 反查不到书名的目录也要列出来（否则用户看着总占用和列表对不上）
            if hit == nil {
                CrashLog.write("CACHE", "orphan dir=\(d.dirName) bytes=\(d.bytes)")
            }
            out.append(LocalStore.CacheEntry(
                id: d.dirName,
                bookUrl: hit?.bookUrl ?? "",
                title: hit?.title ?? "其他专辑",
                bytes: d.bytes,
                files: d.fileCount))
            sum += d.bytes
        }
        entries = out.sorted { $0.bytes > $1.bytes }
        total = sum
        let s = AudioCache.loadSettings()
        autoCacheNext = s.autoCacheNext
        maxPerBook = s.maxEpisodesPerBook
    }
}

/// 播放设置（从设置页拆出来的一级页面）
struct PlaybackSettingsPage: View {
    @State private var prefs = LocalStore.loadPlayPrefs()

    var body: some View {
        Form {
            Section("快进快退") {
                Picker("秒数", selection: Binding(
                    get: { prefs.seekSeconds },
                    set: { prefs.seekSeconds = $0; LocalStore.savePlayPrefs(prefs) }
                )) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) 秒").tag($0) }
                }
            }

            Section("倍速") {
                HStack {
                    Text("默认倍速")
                    Spacer()
                    Text(String(format: "%.2fx", prefs.defaultSpeed))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { prefs.defaultSpeed },
                    set: { prefs.defaultSpeed = $0; LocalStore.savePlayPrefs(prefs) }
                ), in: 0.5...3.0, step: 0.05)
                Toggle("所有专辑用同一倍速", isOn: Binding(
                    get: { prefs.useGlobalSpeed },
                    set: { prefs.useGlobalSpeed = $0; LocalStore.savePlayPrefs(prefs) }
                ))
            }

            Section("跳过") {
                Stepper("片头 \(prefs.defaultSkipIntroSec) 秒",
                        value: Binding(get: { prefs.defaultSkipIntroSec },
                                       set: { prefs.defaultSkipIntroSec = $0; LocalStore.savePlayPrefs(prefs) }),
                        in: 0...300, step: 5)
                Stepper("片尾 \(prefs.defaultSkipOutroSec) 秒",
                        value: Binding(get: { prefs.defaultSkipOutroSec },
                                       set: { prefs.defaultSkipOutroSec = $0; LocalStore.savePlayPrefs(prefs) }),
                        in: 0...300, step: 5)
                Toggle("按专辑独立设置", isOn: Binding(
                    get: { !prefs.useGlobalSkip },
                    set: { prefs.useGlobalSkip = !$0; LocalStore.savePlayPrefs(prefs) }
                ))
            }

            Section("其它") {
                Toggle("恢复播放后退", isOn: Binding(
                    get: { prefs.resumeRewindSeconds > 0 },
                    set: { prefs.resumeRewindSeconds = $0 ? 5 : 0; LocalStore.savePlayPrefs(prefs) }
                ))
                Toggle("进入播放页自动播放", isOn: Binding(
                    get: { prefs.autoPlayOnOpen },
                    set: { prefs.autoPlayOnOpen = $0; LocalStore.savePlayPrefs(prefs) }
                ))
                Toggle("跳过无声部分", isOn: Binding(
                    get: { prefs.skipSilence },
                    set: { prefs.skipSilence = $0; LocalStore.savePlayPrefs(prefs) }
                ))
            }
        }
        .navigationTitle("播放设置")
    }
}

/// 日志查看 / 分享
struct LogViewerPage: View {
    @State private var text = ""
    @State private var showShare = false

    var body: some View {
        Group {
            if text.isEmpty {
                ContentUnavailableView("还没有日志", systemImage: "doc.text",
                                       description: Text("这个 App 还没写入过日志"))
            } else {
                ScrollView {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle("运行日志")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showShare = true
                    } label: { Label("分享", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) {
                        CrashLog.clear()
                        text = ""
                    } label: { Label("清空", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [text])
        }
        .onAppear { text = CrashLog.merged() }
    }
}

/// 系统分享面板包装
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 外观配色：四套方案即时切换（选中即生效，不需要保存按钮）
struct ThemePage: View {
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        List {
            Section {
                ForEach(AppTheme.allCases) { t in
                    Button {
                        store.key_ = t.rawValue
                    } label: {
                        HStack(spacing: 14) {
                            // 色块预览：直接用该主题的自适应色
                            Circle()
                                .fill(t.color)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).foregroundStyle(.primary)
                                Text(t.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.theme == t {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .accessibilityLabel(t.name)
                }
            } header: {
                Text("强调色")
            } footer: {
                Text("播放页是深色界面，配色会自动换成浅色版本，保证图标清晰。")
            }
        }
        .navigationTitle("外观配色")
        .navigationBarTitleDisplayMode(.inline)
    }
}

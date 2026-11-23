import SwiftUI

/// 书架页：搜索 → 结果列表 → 专辑 → 曲目 → 播放。
/// 引擎纪律：搜索已限速 1/s、网页端点预算 3 次/30s，降级时展示引擎给的 hint，壳不再加工。
struct ShelfView: View {
    @State private var keyword = ""
    @State private var cards: [SharedBridge.BookCard] = []
    @State private var hint: String?
    /// UI-03：搜索代际。连续提交时旧响应不能覆盖新结果。
    @State private var searchGeneration = 0
    @State private var loading = false
    @State private var errorText: String?
    @State private var mode: Mode = .search
    @State private var favorites: [LocalStore.Favorite] = []
    @State private var recent: [LocalStore.Recent] = []
    /// 「用其他源搜」要切到浏览页（与 RootTabView 共用同一个 AppStorage key）
    @AppStorage("selectedTab") private var selectedTab = 0

    enum Mode: String, CaseIterable { case search = "搜索", favorites = "收藏", recent = "最近" }

    var body: some View {
        GeometryReader { geo in
            shelfBody(width: geo.size.width)
        }
    }

    @ViewBuilder
    private func shelfBody(width: CGFloat) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                content(width: width)
            }
            .navigationTitle("书架")
            .searchable(text: $keyword, prompt: "书名、作者或专辑链接")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onAppear { reloadLists() }
            .onChange(of: mode) { _, _ in reloadLists() }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch mode {
        case .search:
            searchContent(width: width)
        case .favorites:
            if favorites.isEmpty {
                placeholder(icon: "heart", title: "还没有收藏", detail: "在专辑页右上角点心形收藏")
            } else {
                List(favorites) { f in
                    NavigationLink {
                        AlbumView(
                            card: SharedBridge.BookCard(
                            bookUrl: f.bookUrl, title: f.title, author: f.author,
                            coverUrl: f.coverUrl, albumId: f.albumId,
                            trackCount: 0, playCount: 0, isFinished: nil),
                            sourceId: f.sourceId)
                    } label: {
                        favRow(f, width: width)
                    }
                }
                .listStyle(.plain)
            }
        case .recent:
            if recent.isEmpty {
                placeholder(icon: "clock", title: "还没有播放记录", detail: "点一集开始播放就会记录")
            } else {
                List(recent) { r in
                    // P2-3：点一条直接续播 —— 用记录里的 sourceId 取地址，
                    // 不再只能看不能点（记录里已存 bookUrl/trackId/sourceId，够还原一集）
                    Button {
                        playRecent(r)
                    } label: {
                        recentRow(r)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func searchContent(width: CGFloat) -> some View {
        if loading {
            Spacer(); ProgressView("搜索中…"); Spacer()
        } else if let errorText {
            placeholder(icon: "exclamationmark.triangle", title: "出错了", detail: errorText)
        } else if cards.isEmpty {
            VStack(spacing: 16) {
                placeholder(icon: "books.vertical",
                            title: hint == nil ? "输入关键词开始搜索" : "这次没搜到",
                            detail: hint == nil
                                ? "引擎直连 + 网页两路同时搜，哪个通走哪个"
                                : hint!)

                if keyword.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 {
                    HStack(spacing: 12) {
                        Button {
                            Task { await runSearch() }
                        } label: {
                            Label("再搜一次", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            searchAllSources(keyword.trimmingCharacters(in: .whitespacesAndNewlines))
                        } label: {
                            Label("用其他源搜", systemImage: "square.stack.3d.up")
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.footnote)
                }
            }
        } else {
            List {
                ForEach(cards, id: \.bookUrl) { card in
                    NavigationLink {
                        AlbumView(card: card, sourceId: sourceOf(card))
                    } label: { row(card, width: width) }
                }
            }
            .listStyle(.plain)
        }
    }

    /// 喜马拉雅两路都不通时，去「浏览」用 32 个模板站 + 免登录源接着搜同一本书
    private func searchAllSources(_ kw: String) {
        NotificationCenter.default.post(name: .browseSearchKeyword, object: kw)
        selectedTab = 1
    }

    /// 浏览器抓到的卡（bookUrl 是 /album/{id}）既属于登录通道，也对免登录源有效；
    /// 统一交给登录通道，它自带匿名兜底，且 Cookie 注入后能取到会员集。
    /// 搜索结果的源：登录版优先（能取会员集），失败会由 SharedBridge.bookDetail 内部
    /// 自动退回 ximalaya-open。注意不能传 "ximalaya-open"，那样永远拿不到会员内容。
    private func sourceOf(_ c: SharedBridge.BookCard) -> String {
        SharedBridge.loggedIn ? "ximalaya" : "ximalaya-open"
    }

    private func row(_ c: SharedBridge.BookCard, width: CGFloat) -> some View {
        HStack(spacing: 12) {
            cover(c.coverUrl, w: Layout.coverSize(width), h: Layout.coverSize(width))
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(.headline).lineLimit(2)
                Text(c.author).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if c.trackCount > 0 { Text("\(c.trackCount) 集") }
                    if c.playCount > 0 { Text("\(fmt(c.playCount)) 播放") }
                    if c.isFinished == true { Text("已完结") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// 最近播放行：书名 + 集名 + 用的哪个源 + 点了就从那集续播
    private func recentRow(_ r: LocalStore.Recent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.episodeTitle).font(.subheadline).lineLimit(1)
                Text(r.bookTitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(sourceName(r.sourceId)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// 点最近记录 → 还原成 EpisodeRow 交给播放器，sourceId 用记录里那个
    private func playRecent(_ r: LocalStore.Recent) {
        let card = SharedBridge.BookCard(
            bookUrl: r.bookUrl, title: r.bookTitle, author: "",
            coverUrl: "", albumId: SharedBridge.albumId(from: r.bookUrl),
            trackCount: 0, playCount: 0, isFinished: nil)
        // P1-07：优先用记录的 episodeUrl（模板集的 trackId 是数字，不能当 URL）
        // 老记录没有 episodeUrl 时回退到 trackId（登录版兼容），再不行用 bookUrl
        // 老记录可能没有 episodeUrl：登录版能用 trackId 直接播，
        // 但模板站的 trackId 也是数字，把它当 URL 会 ParseFailed。
        // 判断依据：登录版的 url 形如纯数字是合法的；模板站必须要有页面 URL。
        let isLoginSource = (r.sourceId == "ximalaya")
        let input: String
        if !r.episodeUrl.isEmpty {
            input = r.episodeUrl
        } else if isLoginSource && r.trackId > 0 {
            input = String(r.trackId)
        } else {
            input = r.bookUrl      // 模板站缺 URL 时退到专辑页，至少不会拼出错误地址
        }
        let ep = SharedBridge.episodeRow(
            title: r.episodeTitle, trackId: r.trackId, index: 1,
            durationMs: 0, coverUrl: "", url: input)
        // UI-02：一律带 sourceId，不再对 ximalaya 特判。
        // 之前 ximalaya-open（免登录）也被送进不带 sourceId 的重载，
        // 播放器把 currentSourceId 写成 "ximalaya"，于是拿登录版去取地址 → 报「需要登录」。
        Player.shared.playEpisode(ep, book: card, sourceId: r.sourceId)
        reloadLists()
    }

    private func sourceName(_ id: String) -> String {
        SharedBridge.allSources().first { $0.id == id }?.name ?? id
    }

    private func favRow(_ f: LocalStore.Favorite, width: CGFloat) -> some View {
        HStack(spacing: 12) {
            cover(f.coverUrl, w: Layout.coverSize(width) * 0.8, h: Layout.coverSize(width) * 0.8)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.subheadline).lineLimit(2)
                Text(f.author).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func cover(_ url: String, w: CGFloat, h: CGFloat) -> some View {
        AsyncImage(url: URL(string: url)) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fmt(_ n: Int64) -> String {
        n >= 10_000 ? String(format: "%.1f万", Double(n) / 10_000) : "\(n)"
    }

    private func reloadLists() {
        favorites = LocalStore.loadFavorites()
        recent = LocalStore.loadRecent()
    }

    private func runSearch() async {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }

        // UI-03：每次搜索递增代际，await 回来后校验，防止旧结果覆盖新关键词
        searchGeneration += 1
        let gen = searchGeneration
        loading = true; errorText = nil; hint = nil; cards = []
        defer { if gen == searchGeneration { loading = false } }

        if kw.hasPrefix("http") || (kw.count >= 4 && Int64(kw) != nil) {
            let id = SharedBridge.albumId(from: kw)
            if id > 0 {
                cards = [SharedBridge.BookCard(
                    bookUrl: "/album/\(id)", title: "专辑 \(id)", author: "",
                    coverUrl: "", albumId: id,
                    trackCount: 0, playCount: 0, isFinished: nil)]
                hint = "正在核对专辑信息…"
                return
            }
        }

        // 2026-11-24 提速：searchBoth 内部已经是「缓存 → 并发三路 → 9s 硬上限」，
        // 免登录兜底也在里面算作第三路，这里不再串行追加一次（原来那一次会再吃满 32s）。
        let t0 = Date()
        let merged = await SharedBridge.searchFast(keyword: kw, page: 1) { partial in
            // 早返回：任一路先出结果就先上屏，后面那路到了再补
            guard gen == searchGeneration else { return }
            Task { @MainActor in
                guard gen == searchGeneration else { return }
                if !partial.isEmpty { cards = partial; loading = false }
            }
        }
        CrashLog.search(kw, path: "total", ms: Int(Date().timeIntervalSince(t0) * 1000), count: merged.count)
        guard gen == searchGeneration else { return }   // 旧结果直接丢弃
        if merged.isEmpty {
            let why = SharedBridge.lastWebSearchError
            hint = why ?? "没搜到结果。换个关键词，或去设置页登录喜马拉雅后再试"
            return
        }
        cards = merged
        hint = nil
    }

}

/// 专辑页：曲目列表，点集数播放。右上角收藏。
struct AlbumView: View {
    let card: SharedBridge.BookCard
    /// 该书所属源：选集播放和取曲目都按它走；默认喜马拉雅登录版（书架搜索流）
    var sourceId: String = "ximalaya"

    @State private var episodes: [SharedBridge.EpisodeRow] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var favorited = false
    /// 正在/上次播放的是列表里第几行（-1 = 没有）。
    /// 原来用 trackId 判：源没给 trackId 时每集都是 0，于是整列变成「已播放」全红 —— 图一的 bug。
    @State private var playingRow: Int = -1
    /// 分页：已加载的页 -> 该页集行
    @State private var pageCache: [Int: [SharedBridge.EpisodeRow]] = [:]
    @State private var pageSize = 50
    @State private var lastLoadedPage = 1
    @State private var loadedAll = false
    @State private var totalChapters = 0
    @State private var loadingMore = false
    @State private var lastPlayedTrackId: Int64 = -1
    @State private var lastPlayedRow: Int = -1
    /// 占位卡解析后的真实卡（P0-4）
    @State private var resolvedCard: SharedBridge.BookCard?
    /// 详情返回的专辑元信息（封面大图/简介/集数/播放量）
    @State private var detail: SharedBridge.BookCard?
    /// 分页用的全量集行（只在内存里存在一次，UI 只消费已加载的切片）。
    /// 注意：不能存 BookDetail——那是 KMP 类型，Views 层禁止 import shared。
    @State private var allEpisodes: [SharedBridge.EpisodeRow] = []
    @State private var introExpanded = false

    /// 跨源唯一键（收藏/进度/分页都用它）
    private var bookKey: BookKey {
        BookKey(sourceId: sourceId, albumId: card.albumId, bookUrl: card.bookUrl)
    }

    /// 展示用：优先用详情里的真实信息，其次累计卡，最后回退占位卡
    private var shown: SharedBridge.BookCard { detail ?? resolvedCard ?? card }

    var body: some View {
        Group {
            if loading {
                // 别只给个转圈：先把已知的封面/书名/主播铺出来，章节区显示骨架，
                // 这样「点进去立刻有东西」，详情回来再补简介和播放量
                List {
                    Section {
                        albumHeader
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(0..<6, id: \.self) { _ in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                                    .frame(width: 26, height: 12)
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                                    .frame(height: 12)
                            }
                            .redacted(reason: .placeholder)
                        }
                    } header: {
                        HStack {
                            Text("节目列表")
                            Spacer()
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .listStyle(.plain)
            } else if let errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(errorText).font(.footnote).multilineTextAlignment(.center)
                    if !SharedBridge.loggedIn {
                        Text("未登录时喜马拉雅专辑接口返回 status=76，先去「设置」登录")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if sourceId != "ximalaya-open" && card.bookUrl.contains("/album/") {
                        Text("已自动试过免登录通道，还是取不到。可以在海外/风控环境下换「免登录」源再点一次。")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button {
                        Task { await load() }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                }.padding()
            } else {
                List {
                    // ===== 专辑信息区 =====
                    Section {
                        albumHeader
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    // ===== 章节列表 =====
                    Section {
                        if episodes.isEmpty {
                            Text("该专辑暂无曲目").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(episodes.enumerated()), id: \.element.url) { (idx: Int, ep: SharedBridge.EpisodeRow) in
                                Button {
                                    playingRow = idx
                                    lastPlayedRow = idx
                                    lastPlayedTrackId = ep.trackId
                                    Player.shared.playEpisode(ep, book: shown, sourceId: sourceId, episodes: episodes)
                                } label: {
                                    episodeRow(ep, row: idx)
                                }
                                .buttonStyle(.plain)
                                // 滚到倒数第 5 条就预取下一页
                                .onAppear {
                                    if idx >= episodes.count - 5 { loadNextPageIfNeeded() }
                                }
                            }

                            if loadingMore {
                                HStack {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                    Text("加载更多…").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("节目列表")
                            Spacer()
                            if !episodes.isEmpty {
                                Text("共 \(episodes.count) 集")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(shown.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let favCard = resolvedCard ?? (card.title.hasPrefix("专辑 ") ? nil : card) else {
                        errorText = "专辑信息还没加载完，稍等再收藏"
                        return
                    }
                    favorited = LocalStore.toggleFavorite(
                        bookUrl: favCard.bookUrl, title: favCard.title, author: favCard.author,
                        coverUrl: favCard.coverUrl, albumId: favCard.albumId,
                        sourceId: sourceId)
                } label: {
                    Image(systemName: favorited ? "heart.fill" : "heart")
                        .foregroundStyle(favorited ? Color.pink : Color.secondary)
                }
            }
        }
        .task { await load() }
        .onAppear {
            favorited = LocalStore.isFavorite(sourceId: sourceId, albumId: card.albumId, bookUrl: card.bookUrl)
        }
    }

    // MARK: - 专辑信息区

    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 封面 + 标题 + 主播
            HStack(alignment: .top, spacing: 14) {
                AsyncImage(url: URL(string: shown.coverUrl)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.title)
                        .font(.headline)
                        .lineLimit(3)
                    if !shown.author.isEmpty {
                        Label(shown.author, systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 14) {
                        if episodes.count > 0 {
                            stat("\(episodes.count)", "集数")
                        } else if shown.trackCount > 0 {
                            stat("\(shown.trackCount)", "集数")
                        }
                        if shown.playCount > 0 {
                            stat(playText(shown.playCount), "播放")
                        }
                        if shown.isFinished == true {
                            Text("已完结").font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // 简介
            if !shown.intro.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("简介")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(shown.intro)
                        .font(.footnote)
                        .lineLimit(introExpanded ? nil : 3)
                        .foregroundStyle(.primary.opacity(0.85))
                    Button(introExpanded ? "收起" : "更多") {
                        withAnimation { introExpanded.toggle() }
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 16)
            }

            Divider().padding(.horizontal, 16)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline).fontWeight(.semibold)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func episodeRow(_ ep: SharedBridge.EpisodeRow, row: Int) -> some View {
        // 只有一行能被标记：优先「正在播的这一行」，其次「上次播放的那一行」
        let isCurrent = playingRow == row
        let isLast = !isCurrent && lastPlayedRow == row
        return HStack(spacing: 10) {
            Text("\(ep.index)")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.title)
                    .lineLimit(2)
                    .foregroundStyle(isCurrent || isLast ? Color.accentColor : Color.primary)
                if isCurrent {
                    Text("播放中")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                } else if isLast {
                    Text("上次播放到")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
            if ep.durationMs > 0 {
                Text(dur(ep.durationMs)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func playText(_ n: Int64) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return "\(n)"
    }

    private func load() async {
        await MainActor.run {
            loading = true
            errorText = nil
        }
        defer { loading = false }
        let saved = LocalStore.progress(for: bookKey)
        guard let d = await SharedBridge.bookDetail(sourceId: sourceId, bookUrl: card.bookUrl) else {
            let why = SharedBridge.lastDetailError ?? ""
            errorText = why.isEmpty ? "专辑加载失败（该源可能已下架或需要登录）" : why
            return
        }
        // 回填真实元信息（封面/简介/集数/播放量都在 d.book 里）
        if d.book.title != card.title {
            resolvedCard = SharedBridge.card(from: d.book)
        }
        detail = SharedBridge.card(from: d.book)
        // 分页：只保留首页，其余页滚动到边界再拉（4820 集不再一次性进内存）
        let all = SharedBridge.rows(from: d)
        allEpisodes = all
        // 分页大小：不能超过总集数，也不能为 0（空专辑 prefix(0) 会让列表空指针）
        let baseSize = ChapterPageMeta(albumKey: bookKey.id).pageSize
        pageSize = all.isEmpty ? 20 : max(1, min(baseSize, all.count))
        totalChapters = Int(d.book.trackCount)
        pageCache = [1: Array(all.prefix(pageSize))]
        lastLoadedPage = 1
        loadedAll = all.count <= pageSize
        ChapterPager.recordPage(1, episodes: pageCache[1] ?? [], albumKey: bookKey.id,
                                total: all.count, pageSize: pageSize)
        episodes = pageCache[1] ?? []
        if episodes.isEmpty { errorText = "该专辑暂无曲目" }
        // 进度只存了 trackId，按它在列表里定位行号；trackId<=0 一律不标
        if let saved = saved, saved.trackId > 0 {
            lastPlayedTrackId = saved.trackId
            lastPlayedRow = episodes.firstIndex(where: { $0.trackId == saved.trackId }) ?? -1
        }
    }

    /// 滚动触底时加载下一页。已经在拉 / 已全加载 / 还没有首屏数据 → 直接返回
    private func loadNextPageIfNeeded() {
        guard !loadingMore, !loadedAll, !episodes.isEmpty else { return }
        let all = allEpisodes
        guard !all.isEmpty else { return }
        let next = lastLoadedPage + 1
        let start = (next - 1) * pageSize
        // 防御：pageSize 异常（0/负数）或已到末尾，直接收工，绝不让下标越界
        guard pageSize > 0, start >= 0, start < all.count else { loadedAll = true; return }

        loadingMore = true
        let slice = Array(all[start..<min(start + pageSize, all.count)])
        pageCache[next] = slice
        lastLoadedPage = next
        episodes.append(contentsOf: slice)
        ChapterPager.recordPage(next, episodes: slice, albumKey: bookKey.id,
                                total: all.count, pageSize: pageSize)
        if start + pageSize >= all.count { loadedAll = true }
        loadingMore = false
    }

    private func dur(_ ms: Int64) -> String {
        let s = ms / 1000
        if s >= 3600 { return String(format: "%d:%02d:%02d", s/3600, (s%3600)/60, s%60) }
        return String(format: "%d:%02d", s/60, s%60)
    }
}

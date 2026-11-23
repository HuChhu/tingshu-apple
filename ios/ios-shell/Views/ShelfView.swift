import SwiftUI

/// 书架页：搜索 → 结果列表 → 专辑 → 曲目 → 播放。
/// 引擎纪律：搜索已限速 1/s、网页端点预算 3 次/30s，降级时展示引擎给的 hint，壳不再加工。
struct ShelfView: View {
    @State private var keyword = ""
    @State private var cards: [SharedBridge.BookCard] = []
    @State private var hint: String?
    @State private var loading = false
    @State private var errorText: String?
    @State private var mode: Mode = .search
    @State private var favorites: [LocalStore.Favorite] = []
    @State private var recent: [LocalStore.Recent] = []

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
                            title: hint ?? "输入关键词开始搜索",
                            detail: hint == nil ? "来自喜马拉雅官方接口，不硬冲风控" : "也可直接粘贴专辑分享链接；点底部「浏览」可按源找书")
            }
        } else {
            List {
                ForEach(cards, id: \.bookUrl) { card in
                    NavigationLink {
                        AlbumView(card: card)
                    } label: { row(card, width: width) }
                }
            }
            .listStyle(.plain)
        }
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
        let input = r.episodeUrl.isEmpty
            ? (r.trackId > 0 ? String(r.trackId) : r.bookUrl)
            : r.episodeUrl
        let ep = SharedBridge.episodeRow(
            title: r.episodeTitle, trackId: r.trackId, index: 1,
            durationMs: 0, coverUrl: "", url: input)
        if r.sourceId == "ximalaya" || r.sourceId == "ximalaya-open" {
            Player.shared.playEpisode(ep, book: card)
        } else {
            Player.shared.playEpisode(ep, book: card, sourceId: r.sourceId)
        }
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
        loading = true; errorText = nil; hint = nil; cards = []
        defer { loading = false }

        if kw.hasPrefix("http") || (kw.count >= 4 && Int64(kw) != nil) {
            let id = SharedBridge.albumId(from: kw)
            if id > 0 {
                // 占位卡：详情页会补全真实书名/作者/封面；
                // 只有拉到详情（title 非「专辑 N」形态）才允许收藏（P0-4）
                cards = [SharedBridge.BookCard(
                    bookUrl: "/album/\(id)", title: "专辑 \(id)", author: "",
                    coverUrl: "", albumId: id, trackCount: 0, playCount: 0, isFinished: nil)]
                hint = "正在核对专辑信息…"
                return
            }
        }

        // 第一路：浏览器搜索（真实 WebView，页面自己算 webtk、自己过风控）
        let web = await SharedBridge.browserSearch(keyword: kw, page: 1)
        if !web.isEmpty {
            cards = web
            return
        }
        // P1-9：网页搜索失败（busy / 超时 / 页面挂了）要说出原因，不能当成「没结果」
        let webError = SharedBridge.lastWebSearchError

        // 第二路：引擎直连（常被风控拦，作为兜底）
        guard let res = await SharedBridge.search(keywords: kw, page: 1) else {
            errorText = webError ?? "搜索失败：浏览器与引擎两条路都没有结果"
            return
        }
        cards = SharedBridge.books(from: res).map(SharedBridge.card(from:))
        let engineHint = SharedBridge.degradedHint(from: res)
        if cards.isEmpty {
            hint = engineHint ?? webError ?? "没搜到结果。换个关键词，或去设置页登录喜马拉雅后再试"
        }
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
    @State private var lastPlayedTrackId: Int64 = -1
    /// 占位卡解析后的真实卡（P0-4）
    @State private var resolvedCard: SharedBridge.BookCard?

    var body: some View {
        Group {
            if loading {
                ProgressView("加载曲目…")
            } else if let errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(errorText).font(.footnote).multilineTextAlignment(.center)
                    if !SharedBridge.loggedIn {
                        Text("提示：未登录时专辑接口返回 status=76，去设置页登录后再试")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    // P2-5：失败态给「重试」按钮，重新走 load()
                    Button {
                        Task { await load() }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                }.padding()
            } else {
                // P1-4 同源问题：模板站多页追加时下标会变，用 url 当稳定 key（每集播放页唯一）
                List(episodes, id: \.url) { ep in
                    Button {
                        lastPlayedTrackId = ep.trackId
                        Player.shared.playEpisode(ep, book: card, sourceId: sourceId, episodes: episodes)
                    } label: {
                        HStack {
                            Text("\(ep.index)").font(.caption).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                            Text(ep.title).lineLimit(1)
                                .foregroundStyle(lastPlayedTrackId == ep.trackId ? Color.accentColor : Color.primary)
                            Spacer()
                            if ep.durationMs > 0 {
                                Text(dur(ep.durationMs)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(card.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // P0-4：占位卡（title 形如「专辑 N」且未解析出真实卡）禁收藏，
                    // 防止写入无封面死条目
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
        .onAppear { favorited = LocalStore.isFavorite(card.bookUrl) }
    }

    private func dur(_ ms: Int64) -> String {
        let s = ms / 1000
        if s >= 3600 { return String(format: "%d:%02d:%02d", s/3600, (s%3600)/60, s%60) }
        return String(format: "%d:%02d", s/60, s%60)
    }

    private func load() async {
        // P2-5：可重入 —— 重试前先把上一轮的失败态清掉，否则 loading 时还挂着错误文字
        await MainActor.run {
            loading = true
            errorText = nil
        }
        defer { loading = false }
        if let saved = LocalStore.progress(for: card.bookUrl) {
            lastPlayedTrackId = saved.trackId
        }
        guard let detail = await SharedBridge.bookDetail(sourceId: sourceId, bookUrl: card.bookUrl) else {
            errorText = "专辑加载失败（该源可能已下架或需要登录）"
            return
        }
        // P0-4：占位卡（title 形如「专辑 N」）拉到详情后回填真实信息，
        // 防止收藏死条目（无封面无作者、sourceId 落错源）
        if card.title.hasPrefix("专辑 "), detail.book.title != card.title {
            resolvedCard = SharedBridge.card(from: detail.book)
        }
        episodes = SharedBridge.rows(from: detail)
        if episodes.isEmpty { errorText = "该专辑暂无曲目" }
    }
}

import SwiftUI

/// 浏览：选源 → 分类 → 书单
/// 修过的 P1/P2：P1-3（isTemplate 只看 kind）/ P1-8（__none__ 哨兵）/
/// P2-1（分类选中态）/ P2-2（切源立刻 loading）/ P1-4（集列表 id 用 url）
struct CategoryView: View {

    @AppStorage("enabledSources") private var enabledRaw: String = ""
    @AppStorage("lastSourceId") private var lastSourceId: String = "ximalaya-open"

    @State private var sources: [SharedBridge.SourceItem] = []
    @State private var selectedId: String = ""
    @State private var categories: [(String, String)] = []
    @State private var books: [SharedBridge.BookCard] = []
    @State private var loading = false
    @State private var hint: String = ""
    /// 代际计数：每次加载 +1，回调对不上就丢弃（P0-1 弱网切源竞态）
    @State private var requestGeneration = 0
    /// 当前选中的分类下标（P2-1：横向按钮要高亮）
    @State private var selectedCatIndex: Int = 0
    /// 关键词搜索（BOOK_DETAIL）：浏览页也能直接搜，不用切回书架
    @State private var searchText = ""
    @State private var searchMode = false

    /// 与 SourcesView 的 defaultEnabled 保持同一份语义（P1-1）：
    /// 「空」= 默认启用集，不是全部。否则点「全关」后这里仍冒出 38 个源。
    private static let defaultEnabled: Set<String> = [
        "ximalaya-open", "kuwo", "bilibili", "qingting", "netease",
        "leting8", "jiongzei", "ytysxs", "gushiya", "ihonghai",
        "tianxiatingshu", "picfxapp", "yitingshu", "aj006", "music189",
    ]

    /// 「明确全关」哨兵（P1-8）：与「未设置（空串）」区分开，
    /// 否则点「全关」后 enabledRaw 为空，被读成默认启用集，列表仍是 15 个开着。
    private static let noneSentinel = "__none__"

    private var enabledSources: [SharedBridge.SourceItem] {
        if enabledRaw == Self.noneSentinel { return [] }
        let set = enabledRaw.isEmpty
            ? Self.defaultEnabled
            : Set(enabledRaw.split(separator: ",").map(String.init))
        return sources.filter { set.contains($0.id) }
    }

    private var currentSource: SharedBridge.SourceItem? {
        sources.first { $0.id == selectedId }
    }

    /// P1-3：只看 kind，不看 categories 是否为空。
    /// 以前写成 kind == "template" && !categories.isEmpty，分类为空时
    /// 直接掉进 else 分支只显示提示，loadCategory 永远不触发。
    private var isTemplate: Bool {
        currentSource?.kind == "template"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("源") {
                    if enabledSources.isEmpty {
                        Text("源全关了。去「源管理」重新勾选至少一个。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("当前源", selection: $selectedId) {
                            ForEach(enabledSources, id: \.id) { s in
                                Text(s.name).tag(s.id)
                            }
                        }
                        .onChange(of: selectedId) { _, newValue in
                            lastSourceId = newValue
                            reload()
                        }
                    }
                }

                // P1-3：模板站一律显示分类区（分类为空时给空态，不吞掉整个区）
                if isTemplate {
                    Section("分类") {
                        if categories.isEmpty {
                            Text("这个站没配分类，点上面「搜索」标签用关键词找书。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    // id 用分类 URL 而不是下标：同站重载后顺序可能变，下标 key 会串行
                                    ForEach(Array(categories.enumerated()), id: \.element.1) { idx, cat in
                                        let on = (idx == selectedCatIndex)
                                        Button(cat.0) {
                                            selectedCatIndex = idx
                                            loadCategory(idx)
                                        }
                                        // 选中态：主色浅底 + 主色字（方案 §3.2-4，不用多个彩色按钮）。
                                        // buttonStyle 的三目类型是基类 ButtonStyle，会让点击区缩小，所以用 tint。
                                        .buttonStyle(.bordered)
                                        .tint(on ? Color.accentColor : Color.secondary)
                                        .font(.footnote)
                                        .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 2)
                            }
                        }
                    }
                }

                if loading {
                    Section {
                        HStack(spacing: 10) {
                            Spacer()
                            ProgressView()
                            Text("正在加载「\(currentSource?.name ?? selectedId)」…")
                                .font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                } else if !hint.isEmpty {
                    Section {
                        Text(hint).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if searchMode && !searchText.isEmpty && !books.isEmpty {
                    Section {
                        Button {
                            searchMode = false
                            searchText = ""
                            reload()
                        } label: {
                            Label("结束搜索，回到「\(currentSource?.name ?? "当前源")」的推荐", systemImage: "xmark.circle")
                                .font(.footnote)
                        }
                    }
                }

                if !books.isEmpty {
                    Section("共 \(books.count) 本") {
                        ForEach(books, id: \.bookUrl) { b in
                            BookRow(card: b, sourceId: selectedId)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "用「\(currentSource?.name ?? "当前源")」搜书名")
            .onSubmit(of: .search) { runSourceSearch() }
            .onChange(of: selectedId) { _, _ in
                if searchMode && !searchText.isEmpty { runSourceSearch() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .browseSearchKeyword)) { note in
                guard let kw = note.object as? String, !kw.isEmpty else { return }
                searchText = kw
                runSourceSearch()
            }
            .navigationTitle("分类")
            .onAppear {
                if sources.isEmpty { sources = SharedBridge.allSources() }
                if selectedId.isEmpty { selectedId = lastSourceId }
                // P1-9：上次选的源可能已被「全关」（__none__ 哨兵或列表里没有），
                // 这时回落到默认启用集的第一个，否则整页只剩空选择框
                if !enabledSources.contains(where: { $0.id == selectedId }) {
                    selectedId = enabledSources.first?.id ?? ""
                }
                reload()
            }
            .refreshable { reload() }
        }
    }

    /// 在当前源里按关键词搜（原来只有搜索入口在书架，且只搜喜马拉雅）
    private func runSourceSearch() {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty, !selectedId.isEmpty else { return }
        requestGeneration += 1
        let gen = requestGeneration
        let src = selectedId
        searchMode = true
        loading = true
        books = []
        hint = ""
        Task {
            let r = await SharedBridge.search(sourceId: src, keywords: kw, page: 1)
            await MainActor.run {
                guard gen == requestGeneration else { return }
                books = SharedBridge.cards(from: r)
                loading = false
                if books.isEmpty {
                    let why = (r?.hint).flatMap { $0.isEmpty ? nil : $0 }
                    hint = why ?? "「\(src)」里没搜到「\(kw)」。换个源或换个关键词。"
                }
            }
        }
    }

    private func reload() {
        // 切源/首帧：先作废所有在途请求（P0-1），再判空源
        requestGeneration += 1
        // P2-2：切源立刻进 loading，等分类书单回来再退出
        loading = true
        books = []
        hint = ""
        categories = []
        selectedCatIndex = 0
        guard !selectedId.isEmpty else { // P1-2：首帧未选中不打空源
            loading = false
            return
        }
        categories = SharedBridge.categories(sourceId: selectedId).map { ($0.0, $0.1) }
        if isTemplate {
            if categories.isEmpty {
                // P1-3：模板站但没配分类 —— 仍然给出可操作提示，loading 收掉
                loading = false
                hint = "这个模板站没配分类。点上面的『搜索』标签用关键词搜书。"
                return
            }
            loadCategory(0)
        } else if currentSource != nil {
            // 原生源没有分类接口：用通用热词预搜一批，给用户可点的起点
            loadNativeRecommend()
        } else {
            loading = false
            hint = "先在上面挑一个源；一个都没有就去「源管理」勾上。"
        }
    }


    /// 原生源（喜马拉雅/酷我/B站/蜻蜓/网易云）没有分类接口，
    /// 用通用热词预搜一批，避免「浏览页一片空白」。
    private func loadNativeRecommend() {
        requestGeneration += 1
        let gen = requestGeneration
        let src = selectedId
        Task {
            let r = await SharedBridge.search(sourceId: src, keywords: "有声书", page: 1)
            await MainActor.run {
                guard gen == requestGeneration else { return }
                books = SharedBridge.cards(from: r)
                loading = false
                if books.isEmpty {
                    hint = "这个源没有分类浏览，点上面的搜索框搜书名。"
                }
            }
        }
    }

    private func loadCategory(_ idx: Int) {
        requestGeneration += 1
        let gen = requestGeneration
        let sourceId = selectedId
        loading = true
        hint = ""
        Task {
            let list = await SharedBridge.categoryBooks(sourceId: sourceId, catIndex: idx)
            await MainActor.run {
                guard gen == requestGeneration else { return } // 旧代际回调，丢弃
                books = list.map { SharedBridge.card(from: $0) }
                loading = false
                if books.isEmpty {
                    hint = "这个分类没抓到书，换一个分类试试。"
                }
            }
        }
    }
}

/// 书单行
struct BookRow: View {
    let card: SharedBridge.BookCard
    let sourceId: String

    var body: some View {
        NavigationLink {
            AlbumView(card: card, sourceId: sourceId)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: Layout.coverURL(card.coverUrl), transaction: Transaction(animation: .easeOut(duration: 0.16))) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: Layout.radiusThumb)
                        .fill(Layout.cardFill)
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Layout.radiusThumb))

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title).font(.body).lineLimit(2)
                    if !card.author.isEmpty {
                        Text(card.author).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if card.trackCount > 0 {
                            Text("\(card.trackCount) 集").font(.caption2).foregroundStyle(.secondary)
                        }
                        if card.playCount > 0 {
                            Text("\(card.playCount) 播放").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// 章节列表
struct EpisodeListView: View {
    let card: SharedBridge.BookCard
    let sourceId: String

    @State private var episodes: [SharedBridge.EpisodeRow] = []
    @State private var loading = true
    @State private var errorText: String = ""

    var body: some View {
        Group {
            if loading {
                ProgressView("读取章节…")
            } else if !errorText.isEmpty {
                ContentUnavailableView("读不到章节", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else {
                // P1-4：模板站的 index 是 1,2,3… 连续整数且可能重复，
                // 用 url 当 id（每集播放页地址唯一），追加加载不会撞 key。
                List(episodes, id: \.url) { ep in
                    Button {
                        play(ep)
                    } label: {
                        HStack {
                            Text("\(ep.index).").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(ep.title).lineLimit(1)
                            Spacer()
                            if ep.durationMs > 0 {
                                Text(fmt(ep.durationMs)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(card.title)
        .task { await load() }
    }

    private func load() async {
        guard let detail = await SharedBridge.bookDetail(sourceId: sourceId, bookUrl: card.bookUrl) else {
            await MainActor.run {
                errorText = "这个源暂时取不到章节"
                loading = false
            }
            return
        }
        await MainActor.run {
            episodes = SharedBridge.rows(from: detail)
            loading = false
        }
    }

    private func play(_ ep: SharedBridge.EpisodeRow) {
        Player.shared.playEpisode(ep, book: card, sourceId: sourceId, episodes: episodes)
    }

    private func fmt(_ ms: Int64) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

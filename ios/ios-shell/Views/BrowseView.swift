import SwiftUI

/// 浏览：选源 → 分类 → 书单
struct BrowseView: View {

    @AppStorage("enabledSources") private var enabledRaw: String = ""
    @AppStorage("lastSourceId") private var lastSourceId: String = "ximalaya-open"

    @State private var sources: [SharedBridge.SourceItem] = []
    @State private var selectedId: String = ""
    @State private var categories: [(String, String)] = []
    @State private var books: [SharedBridge.BookCard] = []
    @State private var loading = false
    @State private var hint: String = ""

    private var enabledSources: [SharedBridge.SourceItem] {
        guard !enabledRaw.isEmpty else { return sources }
        let set = Set(enabledRaw.split(separator: ",").map(String.init))
        return sources.filter { set.contains($0.id) }
    }

    private var currentSource: SharedBridge.SourceItem? {
        sources.first { $0.id == selectedId }
    }

    private var isTemplate: Bool {
        currentSource?.kind == "template"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("源") {
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

                if isTemplate && !categories.isEmpty {
                    Section("分类") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(categories.enumerated()), id: \.offset) { idx, cat in
                                    Button(cat.0) {
                                        loadCategory(idx)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if loading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("加载中…")
                            Spacer()
                        }
                    }
                } else if !hint.isEmpty {
                    Section {
                        Text(hint).font(.footnote).foregroundStyle(.secondary)
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
            .navigationTitle("浏览")
            .onAppear {
                if sources.isEmpty { sources = SharedBridge.allSources() }
                if selectedId.isEmpty { selectedId = lastSourceId }
                reload()
            }
            .refreshable { reload() }
        }
    }

    private func reload() {
        categories = SharedBridge.categories(sourceId: selectedId).map { ($0.0, $0.1) }
        books = []
        hint = ""
        if isTemplate && !categories.isEmpty {
            loadCategory(0)
        } else {
            hint = "点上面的『搜索』标签搜书，或在设置里挑一个模板站浏览。"
        }
    }

    private func loadCategory(_ idx: Int) {
        loading = true
        hint = ""
        Task {
            let list = await SharedBridge.categoryBooks(sourceId: selectedId, catIndex: idx)
            await MainActor.run {
                books = list.map { SharedBridge.card(from: $0) }
                loading = false
                if books.isEmpty {
                    hint = "这个分类没抓到书，换一个试试。"
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
            EpisodeListView(card: card, sourceId: sourceId)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: card.coverUrl)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))

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
                List(episodes, id: \.index) { ep in
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
        Player.shared.playEpisode(ep, book: card, sourceId: sourceId)
    }

    private func fmt(_ ms: Int64) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

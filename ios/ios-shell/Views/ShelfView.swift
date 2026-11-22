import SwiftUI

/// 书架页：搜索 → 结果列表 → 点进专辑 → 曲目 → 播放。
/// 引擎纪律：搜索已限速 1/s、网页端点预算 3 次/30s，降级时展示引擎给的 hint，壳不再加工。
struct ShelfView: View {
    @State private var keyword = ""
    @State private var cards: [SharedBridge.BookCard] = []
    @State private var hint: String?
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("搜索中…")
                } else if let errorText {
                    placeholder(icon: "exclamationmark.triangle", title: "出错了", detail: errorText)
                } else if cards.isEmpty {
                    placeholder(
                        icon: "books.vertical",
                        title: hint ?? "输入关键词开始搜索",
                        detail: hint == nil ? "来自喜马拉雅官方接口，不硬冲风控" : "也可直接粘贴专辑分享链接"
                    )
                } else {
                    List {
                        ForEach(cards, id: \.bookUrl) { card in
                            NavigationLink {
                                AlbumView(card: card)
                            } label: {
                                row(card)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("书架")
            .searchable(text: $keyword, prompt: "书名、作者或专辑链接")
            .onSubmit(of: .search) { Task { await runSearch() } }
        }
    }

    private func row(_ c: SharedBridge.BookCard) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: c.coverUrl)) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.15)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

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

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func fmt(_ n: Int64) -> String {
        n >= 10_000 ? String(format: "%.1f万", Double(n) / 10_000) : "\(n)"
    }

    private func runSearch() async {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        loading = true; errorText = nil; hint = nil; cards = []
        defer { loading = false }

        // 纯数字或链接 → 直接当专辑跳转
        if kw.hasPrefix("http") || (kw.count >= 4 && Int64(kw) != nil) {
            let id = SharedBridge.albumId(from: kw)
            if id > 0 {
                cards = [SharedBridge.BookCard(
                    bookUrl: "/album/\(id)", title: "专辑 \(id)", author: "",
                    coverUrl: "", albumId: id, trackCount: 0, playCount: 0, isFinished: nil)]
                return
            }
        }

        guard let res = await SharedBridge.search(keywords: kw, page: 1) else {
            errorText = "搜索请求失败"
            return
        }
        cards = SharedBridge.books(from: res).map(SharedBridge.card(from:))
        hint = SharedBridge.degradedHint(from: res)
    }
}

/// 专辑页：曲目列表，点集数播放。
struct AlbumView: View {
    let card: SharedBridge.BookCard
    @State private var episodes: [SharedBridge.EpisodeRow] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("加载曲目…")
            } else if let errorText {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36))
                    Text(errorText).font(.footnote).multilineTextAlignment(.center)
                }.padding()
            } else {
                List(episodes.indices, id: \.self) { i in
                    Button {
                        Player.shared.playEpisode(episodes[i])
                    } label: {
                        HStack {
                            Text("\(episodes[i].index)").font(.caption).foregroundStyle(.secondary).frame(width: 32)
                            Text(episodes[i].title).lineLimit(1)
                            Spacer()
                            if episodes[i].durationMs > 0 {
                                Text(dur(episodes[i].durationMs)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(card.title)
        .task { await load() }
    }

    private func dur(_ ms: Int64) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func load() async {
        defer { loading = false }
        guard let detail = await SharedBridge.bookDetail(bookUrl: card.bookUrl) else {
            errorText = "专辑加载失败（可能已下架或需要登录）"
            return
        }
        episodes = SharedBridge.rows(from: detail)
        if episodes.isEmpty { errorText = "该专辑暂无曲目" }
    }
}

import SwiftUI

/// 首页：只放推荐流。
/// 参考摸鱼听书「最近收听 + 总榜 Top6 + 分类横滑」与喜马拉雅「继续听 + 猜你喜欢 + 榜单」：
///   - 顶部：继续收听（有播放记录才出现，占 1/4 屏，最大点击热区）
///   - 猜你喜欢：竖排大卡（封面 + 标题 + 主播 + 播放量 + 评分）
///   - 横滑书单：每个源/分类一行，横向滚动
/// 不做搜索框（搜索在书架和分类页都能进），避免首页被功能污染。
struct HomeView: View {
    @State private var recent: [LocalStore.Recent] = []
    @State private var sections: [FeedSection] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var generation = 0

    struct FeedSection: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let books: [SharedBridge.BookCard]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    // 继续收听
                    if let r = recent.first {
                        continueCard(r)
                    }

                    if loading {
                        skeleton
                    } else if let errorText {
                        unit(title: "没能加载推荐", detail: errorText)
                    } else {
                        ForEach(sections) { sec in
                            sectionView(sec)
                        }
                    }

                    Color.clear.frame(height: 90)   // 给迷你播放条留位
                }
                .padding(.top, 8)
            }
            .navigationTitle("发现")
            .refreshable { await load(force: true) }
            .task { await load(force: false) }
            .onAppear {
                CrashLog.write("UI", "home appear")
                recent = LocalStore.loadRecent()
            }
            .onDisappear { CrashLog.write("UI", "home disappear") }
        }
    }

    // MARK: - 继续收听

    private func continueCard(_ r: LocalStore.Recent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("继续收听").font(.headline)
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: r.coverUrl)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(r.bookTitle).font(.subheadline).lineLimit(1)
                    Text(r.episodeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title2).foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
            .onTapGesture {
                if let ep = LocalStore.recentEpisode(r) {
                    Player.shared.playEpisode(ep, book: LocalStore.recentBook(r), sourceId: r.sourceId)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - 推荐分区

    private func sectionView(_ sec: FeedSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(sec.title).font(.headline)
                Text(sec.subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(sec.books, id: \.bookUrl) { card in
                        NavigationLink {
                            AlbumView(card: card, sourceId: sharedBridgeSource)
                        } label: {
                            bookCard(card)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func bookCard(_ c: SharedBridge.BookCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: c.coverUrl)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
            .frame(width: 116, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(c.title).font(.caption).lineLimit(2)
                .frame(width: 116, alignment: .leading)
            Text(c.author.isEmpty ? " " : c.author)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 116, alignment: .leading)
            if c.playCount > 0 {
                Text(fmtCount(c.playCount) + " 播放")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 首页推荐都来自喜马拉雅：登录了走登录通道（能取会员集），否则走免登录源。
    /// 原来带了个没用到的 (for c:) 参数，swiftc 的 unused-parameter 检查会报。
    private var sharedBridgeSource: String {
        SharedBridge.loggedIn ? "ximalaya" : "ximalaya-open"
    }

    // MARK: - 骨架屏

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 100, height: 16)
                        .padding(.horizontal)
                    HStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.10))
                                .frame(width: 116, height: 116)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func unit(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.subheadline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func fmtCount(_ n: Int64) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return "\(n)"
    }

    // MARK: - 数据

    private func load(force: Bool) async {
        guard force || sections.isEmpty else { return }
        generation += 1
        let gen = generation
        await MainActor.run { loading = true; errorText = nil }

        // 首页推荐只用免登录源，避免首屏就撞登录校验
        let src = "ximalaya-open"
        var out: [FeedSection] = []

        // 三个常用热词各取一批，组成「猜你喜欢 / 热门 / 新书」
        let feeds: [(String, String, String)] = [
            ("抖音热播", "抖音热播合集", "全网热播"),
            ("有声书", "精选有声书", "编辑推荐"),
            ("悬疑", "悬疑推理", "听了上头"),
        ]

        for (kw, title, sub) in feeds {
            if let r = await SharedBridge.search(sourceId: src, keywords: kw, page: 1) {
                let books = SharedBridge.cards(from: r).map { card in
                    SharedBridge.BookCard(bookUrl: card.bookUrl, title: card.title,
                                          author: card.author, coverUrl: card.coverUrl,
                                          albumId: card.albumId, trackCount: card.trackCount,
                                          playCount: card.playCount, isFinished: card.isFinished)
                }
                if !books.isEmpty {
                    out.append(FeedSection(id: kw, title: title, subtitle: sub, books: Array(books.prefix(20))))
                }
            }
            await MainActor.run {
                guard gen == self.generation else { return }
                self.sections = out
            }
        }

        await MainActor.run {
            guard gen == self.generation else { return }
            loading = false
            if out.isEmpty {
                errorText = SharedBridge.lastWebSearchError ?? "推荐加载失败，下拉重试"
            }
        }
    }
}

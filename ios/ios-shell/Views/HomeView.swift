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
    /// 只有「所有的分区都失败」才用整页错误；单个分区失败只在自己那块显示
    @State private var errorText: String?
    @State private var generation = 0
    /// 迷你条是否占位：底部留白要按它算，别永远写死 90pt
    @ObservedObject private var player = Player.shared
    /// 点「继续收听」卡 → 推专辑详情。
    /// 用 isPresented 而不是 item: BookCard —— BookCard 不是 Hashable，
    /// navigationDestination(item:) 要求 Identifiable & Hashable，编译不过。
    @State private var showAlbum = false
    @State private var pushAlbum: SharedBridge.BookCard?
    @State private var pushSourceId: String = ""

    struct FeedSection: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let books: [SharedBridge.BookCard]
    }

    /// 一个分区在请求过程中的三种结局（方案 §3.1：分区级空态/错误，不拖垮整页）
    private enum FeedState {
        case loaded([SharedBridge.BookCard])
        case empty
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    // 继续收听（没有播放记录时整块不出现，不会崩：recent.first 为 nil 直接跳过）
                    if let r = recent.first {
                        continueCard(r)
                    }

                    if loading && sections.isEmpty {
                        skeleton
                    } else if let errorText, sections.isEmpty {
                        unit(title: "没能加载推荐", detail: errorText, showRetry: true)
                    } else if sections.isEmpty {
                        unit(title: "暂时没有推荐", detail: "下拉刷新试试，或去「分类」按书源找书")
                    } else {
                        ForEach(sections) { sec in
                            sectionView(sec)
                        }
                    }

                    // 底部留白按迷你条是否出现动态算（原来固定 90pt，
                    // 迷你条隐藏时首页底部永远多一块空白）
                    Color.clear.frame(height: Layout.bottomInset(
                        miniBarVisible: !player.nowPlaying.isEmpty && player.state != .stopped,
                        safeArea: 0))
                }
                .padding(.top, 8)
            }
            .navigationTitle("发现")
            .navigationDestination(isPresented: $showAlbum) {
                if let card = pushAlbum {
                    AlbumView(card: card, sourceId: pushSourceId)
                }
            }
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
        VStack(alignment: .leading, spacing: Layout.titleGap) {
            Text("继续收听").font(.headline).padding(.horizontal, Layout.hPadding)
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: r.coverUrl)) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: Layout.radiusImage).fill(Layout.cardFill)
                        .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                }
                .frame(width: Layout.thumbContinue, height: Layout.thumbContinue)
                .clipShape(RoundedRectangle(cornerRadius: Layout.radiusImage))

                VStack(alignment: .leading, spacing: 4) {
                    Text(r.bookTitle).font(.subheadline).lineLimit(1)
                    Text(r.episodeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    // 进度：有记录就显示百分比，没有就不占位（不堆四个次要信息）
                    if let p = LocalStore.progress(for: r.bookUrl), p.durationMs > 0 {
                        ProgressView(value: p.fraction).tint(.accentColor)
                            .padding(.top, 2)
                        Text("已听 \(Int(p.fraction * 100))%")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                // 播放按钮独立热区，点它只续播、不展开（方案 §3.1-2）
                Button {
                    playRecent(r, openFullScreen: false)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("继续播放 \(r.episodeTitle)")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Layout.radiusCard).fill(Layout.cardFill))
            .contentShape(Rectangle())
            // 点卡片其他区域 → 进专辑详情（原来这里直接开播，用户没法改成「看专辑」）
            .onTapGesture { showAlbumForRecent(r) }
        }
        .padding(.horizontal, Layout.hPadding)
    }

    /// 首页最近记录 → 用统一入口播放（LocalStore.recentEpisode 已处理 episodeUrl 回退）
    private func playRecent(_ r: LocalStore.Recent, openFullScreen: Bool) {
        Player.shared.playEpisode(LocalStore.recentEpisode(r),
                                  book: LocalStore.recentBook(r),
                                  sourceId: r.sourceId)
        if openFullScreen { Player.shared.showFullScreen = true }
    }

    /// 点继续听卡本身：进专辑详情（有 albumId 才推得动，否则直接播）
    private func showAlbumForRecent(_ r: LocalStore.Recent) {
        let card = LocalStore.recentBook(r)
        if card.albumId > 0 || !r.bookUrl.isEmpty {
            pushAlbum = card
            pushSourceId = r.sourceId
            showAlbum = true
        } else {
            playRecent(r, openFullScreen: true)
        }
    }

    // MARK: - 推荐分区

    private func sectionView(_ sec: FeedSection) -> some View {
        VStack(alignment: .leading, spacing: Layout.titleGap) {
            HStack(alignment: .firstTextBaseline) {
                Text(sec.title).font(.headline)
                Text(sec.subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Layout.hPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Layout.cardSpacing) {
                    ForEach(sec.books, id: \.bookUrl) { card in
                        NavigationLink {
                            AlbumView(card: card, sourceId: sharedBridgeSource)
                        } label: {
                            bookCard(card)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Layout.hPadding)
            }
        }
    }

    @ViewBuilder
    private func bookCard(_ c: SharedBridge.BookCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: URL(string: c.coverUrl)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: Layout.radiusImage)
                    .fill(Layout.cardFill)
                    .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
            }
            .frame(width: Layout.thumbCard, height: Layout.thumbCard)
            .clipShape(RoundedRectangle(cornerRadius: Layout.radiusImage))

            Text(c.title).font(.caption).foregroundStyle(.primary).lineLimit(2)
                .frame(width: Layout.thumbCard, alignment: .leading)
            Text(c.author.isEmpty ? " " : c.author)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: Layout.thumbCard, alignment: .leading)
            if c.playCount > 0 {
                Text(fmtCount(c.playCount) + " 播放")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(width: Layout.thumbCard, alignment: .leading)
            }
        }
    }

    /// 首页推荐都来自喜马拉雅：登录了走登录通道（能取会员集），否则走免登录源。
    /// 原来带了个没用到的 (for c:) 参数，swiftc 的 unused-parameter 检查会报。
    private var sharedBridgeSource: String {
        SharedBridge.loggedIn ? "ximalaya" : "ximalaya-open"
    }

    // MARK: - 骨架屏

    /// 骨架屏：形状/间距/底色全部走 Layout，三个分区一个样式
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Layout.titleGap) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Layout.skeletonFill)
                        .frame(width: 100, height: 16)
                        .padding(.horizontal, Layout.hPadding)
                    HStack(spacing: Layout.cardSpacing) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Layout.radiusImage)
                                .fill(Layout.skeletonFill)
                                .frame(width: Layout.thumbCard, height: Layout.thumbCard)
                        }
                    }
                    .padding(.horizontal, Layout.hPadding)
                }
            }
        }
        .accessibilityLabel("正在加载推荐")
    }

    /// 整页空/错态。showRetry=true 时带重试按钮（原来失败只能靠下拉，没有明确入口）
    private func unit(title: String, detail: String, showRetry: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.subheadline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Layout.hPadding)
            if showRetry {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .disabled(loading)
            }
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

    /// 首页分区配置：关键词 / 标题 / 副标题 / 每个分区最多显示几本
    private struct FeedSpec {
        let key: String
        let title: String
        let subtitle: String
        let limit: Int
    }

    private static let specs: [FeedSpec] = [
        FeedSpec(key: "有声书", title: "精选有声书", subtitle: "编辑推荐", limit: 10),
        FeedSpec(key: "悬疑", title: "悬疑推理", subtitle: "听了上头", limit: 10),
        FeedSpec(key: "历史", title: "历史人文", subtitle: "慢慢听", limit: 10),
    ]

    /// 三个分区并发拉，每个分区独立落地。
    ///
    /// 原来是一个 for 循环串行 await：三个热词各 6~9 秒，最坏 27 秒首屏才出第一张卡。
    /// 现在用 withTaskGroup 并发，首屏等待 = 最慢那一路（约 9 秒上限）；
    /// 某一路失败只在自己分区显示「重试」，不清空整页（方案 §3.1 加载策略）。
    private func load(force: Bool) async {
        guard force || sections.isEmpty else { return }
        // 代际：刷新/重复进入时旧结果直接丢弃（原来 force 刷新只加 generation，不取消旧任务）
        generation += 1
        let gen = generation
        await MainActor.run {
            loading = true
            errorText = nil
        }

        let src = "ximalaya-open"
        let specs = Self.specs

        let results: [(String, FeedState)] = await withTaskGroup(
            of: (String, FeedState).self, returning: [(String, FeedState)].self
        ) { group in
            for spec in specs {
                group.addTask {
                    guard let r = await SharedBridge.search(sourceId: src, keywords: spec.key, page: 1) else {
                        return (spec.key, .failed(SharedBridge.lastWebSearchError ?? "请求失败"))
                    }
                    let books = Array(SharedBridge.cards(from: r).prefix(spec.limit))
                    if books.isEmpty {
                        return (spec.key, .empty)
                    }
                    return (spec.key, .loaded(books))
                }
            }
            var acc: [(String, FeedState)] = []
            for await item in group {
                acc.append(item)
            }
            return acc
        }

        guard gen == generation else { return }

        // 按 specs 的固定顺序组装，避免并发完成顺序导致分区跳动
        var built: [FeedSection] = []
        var firstError: String?
        for spec in specs {
            guard let hit = results.first(where: { $0.0 == spec.key }) else { continue }
            switch hit.1 {
            case .loaded(let books):
                built.append(FeedSection(id: spec.key, title: spec.title,
                                         subtitle: spec.subtitle, books: books))
            case .empty:
                continue    // 空分区直接不渲染，不留标题空壳
            case .failed(let why):
                if firstError == nil { firstError = why }
            }
        }

        await MainActor.run {
            guard gen == self.generation else { return }
            sections = built
            loading = false
            // 全空才用整页错误；有任何一个分区成功就不打扰用户
            errorText = built.isEmpty ? (firstError ?? "推荐加载失败，下拉重试") : nil
        }
    }
}

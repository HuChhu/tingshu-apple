import SwiftUI

/// 沉浸式海报播放页。所有视觉数据均来自 Player 的字符串/标量快照。
struct PlayerView: View {
    @ObservedObject private var player = Player.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var dragValue: Double?
    @State private var activeSheet: PlayerSheet?
    @State private var sleepByChapter = false
    @State private var sleepHours = 0
    @State private var sleepMinutes = 30
    @State private var sleepChapters = 3
    @State private var speedDraft = 1.0
    @State private var volumeDraft = 0.0
    @State private var isFavorite = false

    private enum PlayerSheet: Identifiable {
        case chapters, sleep, speed, volume, sources, login
        var id: Int {
            switch self {
            case .chapters: return 0
            case .sleep: return 1
            case .speed: return 2
            case .volume: return 3
            case .sources: return 4
            case .login: return 5
            }
        }
    }

    /// 换源状态：正在搜 / 搜到了没 / 为什么没搜到
    @State private var sourceSwitching = false
    @State private var sourceSwitchMessage: String?

    var body: some View {
        // 【v1.4.8 修「播放页整屏发白」】
        // 原来把背景当主体、内容是它的 overlay：overlay 的布局提议受背景尺寸影响，
        // 而背景又 ignoresSafeArea 撑到全屏 —— 某些尺寸下内容区被算成 0，整页只剩底色。
        // 改成同级 ZStack：背景沉底（zIndex 0、不吃触摸），内容在上层按 safeArea 排。
        ZStack(alignment: .top) {
            ImmersivePosterBackground(url: coverURL)
                .ignoresSafeArea(.all, edges: .all)
                .zIndex(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            GeometryReader { geo in
                    // 375pt 宽：contentWidth = 335，transport 5 键合计 44*4+72 = 248 + 32 = 280 有余；
                    // posterSize = 303，叠上标题/进度/按钮 ≈ 620pt，一屏放得下（iPhone SE 667pt）。
                    // 560/528 上限是给 iPad 的，避免大屏海报拉满。
                    let contentWidth = min(max(0, geo.size.width - 40), 560)
                    let posterSize = min(max(0, min(geo.size.width - 72, geo.size.height * 0.42)), 528)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            dismissButton
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)

                            poster(size: posterSize)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)

                            titleBlock
                                .padding(.horizontal, 24)
                                .frame(width: contentWidth)
                                .padding(.top, 24)

                            progressBlock
                                .frame(width: contentWidth)
                                .padding(.top, 24)

                            transportControls
                                .frame(width: contentWidth)
                                .padding(.top, 16)

                            utilityControls
                                .frame(width: contentWidth)
                                .padding(.top, 24)

                            if let error = player.errorText {
                                errorBlock(error)
                                    .frame(width: contentWidth)
                                    .padding(.top, 16)
                            }
                        }
                        .frame(width: contentWidth, alignment: .center)
                        .padding(.bottom, 28)
                        .frame(width: geo.size.width)
                        .frame(minHeight: geo.size.height, alignment: .top)
                    }
                    // 只约束宽度：高度锁死成 geo.size.height 会让内容超长时被截断
                    // （配合 .clipped() 直接看不到底部控件）；这里让 ScrollView 自己撑。
                    .frame(width: geo.size.width)
                    .scrollBounceBehavior(.basedOnSize)
            }
            .zIndex(1)
        }
        .background(Color.black.ignoresSafeArea(.all, edges: .all))
            // 强制深色：本页所有前景色都是 .white / .white.opacity(...)，
            // 浅色模式下 presentationDetents 的 sheet 与状态栏对比会反过来，所以锁死深色。
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                refreshFavorite()
                CrashLog.write("UI", "player appear track=\(player.nowPlaying)")
            }
            .onChange(of: player.currentBookUrl) { _, _ in refreshFavorite() }
            .sheet(item: $activeSheet) { sheet in
                sheetContent(sheet)
                    .presentationDetents(sheet == .chapters ? [.medium, .large] : [.medium])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
                    // 显式给不透明底：播放页背景是 ignoresSafeArea 的虚化图，
                    // sheet 若取默认半透明材质，会透出后面的海报色，看起来「sheet 变透明」。
                    .presentationBackground(Color(uiColor: .systemBackground))
            }
    }

    private var coverURL: URL? {
        guard let url = URL(string: player.currentCoverUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private var dismissButton: some View {
        Button {
            player.showFullScreen = false
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("收起播放页")
    }

    private func poster(size: CGFloat) -> some View {
        PlayerPosterImage(url: coverURL)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.48), radius: 30, y: 16)
            .accessibilityLabel("当前专辑封面")
    }

    /// 播放页固定深色：所有文字/控件都按白字设计，
    /// 不跟随系统浅色模式，否则浅色模式下标题是黑字、压在深色虚化图上几乎看不见。
    private var titleBlock: some View {
        VStack(spacing: 8) {
            Text(player.currentBookTitle.isEmpty ? "未选择书籍" : player.currentBookTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(player.currentAuthor.isEmpty ? "演播未知" : player.currentAuthor)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Text(player.nowPlaying.isEmpty ? "未选择曲目" : player.nowPlaying)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            // 起播阶段必须让用户看到「卡在哪一步」：取地址 / 连接源站 / 解码。
            // 没有这行的话，加载中就只是一个转圈，用户无法判断是慢还是坏了。
            if player.state == .loading {
                Text(player.stageHint.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: Capsule())
                    .accessibilityLabel("播放状态：" + player.stageHint.label)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var progressBlock: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { dragValue ?? player.position },
                    set: { dragValue = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let value = dragValue {
                        player.seek(toFraction: value)
                        dragValue = nil
                    }
                }
            )
            .tint(.white)
            .controlSize(.small)
            .frame(height: 3)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .disabled(player.state != .playing && player.state != .paused)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(Int(player.position * 100))%")
            HStack {
                Text(player.elapsedText)
                Spacer()
                Text(player.durationText)
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.white.opacity(0.66))
        }
        .padding(.horizontal, 24)
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            transportButton(icon: "backward.end.fill", label: "上一章",
                            enabled: player.canGoPreviousChapter) {
                player.goToChapter(offset: -1)
            }
            transportButton(icon: "gobackward.\(seekSecs)", label: "后退 \(seekSecs) 秒",
                            enabled: player.canSeek, grayCircle: true) {
                player.skip(false)
            }
            Button {
                if player.state == .playing {
                    player.pause()
                } else {
                    player.resume()
                }
            } label: {
                Image(systemName: mainIcon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(Color.white, in: Circle())
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .disabled(player.state == .stopped || player.state == .loading)
            .accessibilityLabel(player.state == .playing ? "暂停" : "播放")
            transportButton(icon: "goforward.\(seekSecs)", label: "前进 \(seekSecs) 秒",
                            enabled: player.canSeek, grayCircle: true) {
                player.skip(true)
            }
            transportButton(icon: "forward.end.fill", label: "下一章",
                            enabled: player.canGoNextChapter) {
                player.goToChapter(offset: 1)
            }
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
    }

    private func transportButton(icon: String, label: String, enabled: Bool,
                                 grayCircle: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: grayCircle ? 20 : 23, weight: .medium))
                .frame(width: grayCircle ? 36 : 40, height: 44)
                .background(grayCircle ? Color.white.opacity(0.13) : .clear,
                            in: Circle())
        }
        .frame(width: 44, height: 44)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .accessibilityLabel(label)
    }

    private var utilityControls: some View {
        HStack(spacing: 0) {
            utilityButton(icon: "list.bullet", title: "章节", label: "章节列表") {
                activeSheet = .chapters
            }
            utilityButton(icon: "moon.zzz", title: "定时", label: "定时停止播放") {
                let remaining = max(0, player.sleepRemainingMinutes)
                sleepHours = min(12, remaining / 60)
                sleepMinutes = remaining % 60
                activeSheet = .sleep
            }
            utilityButton(icon: "speedometer", title: "倍速", label: "播放倍速调整") {
                speedDraft = player.currentSpeed
                activeSheet = .speed
            }
            utilityButton(icon: "speaker.wave.2", title: "音量", label: "音量增强减弱") {
                volumeDraft = player.currentVolumeGainDb
                activeSheet = .volume
            }
            // 没有当前书时 toggleFavorite() 会直接 return —— 按钮却仍可点，
            // 表现为「点了没反应」。这里直接把按钮禁用并降透明度。
            utilityButton(icon: isFavorite ? "heart.fill" : "heart",
                          title: "收藏",
                          label: isFavorite ? "取消收藏" : "收藏",
                          enabled: canFavorite) {
                toggleFavorite()
            }
        }
        .padding(.horizontal, 12)
    }

    private func utilityButton(icon: String, title: String, label: String,
                               enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            // 禁用态必须看得出来：disabled 不会自动改色
            .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.3))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// 能收藏的前提：有当前书（toggleFavorite 内部也判一次，这里是给 UI 用的镜像）
    private var canFavorite: Bool {
        !player.currentBookUrl.isEmpty
    }

    private func errorBlock(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            if player.canRetry {
                Button("重试这一集") { player.retry() }
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .accessibilityLabel("重试这一集")
            }
            // 以前换源要：播放页 → 返回 → 书架 → 分类页 → 选源重搜，四步。
            // 现在原地一步：这个源不行就换一个，不用离开播放页。
            Button("换个源听") {
                sourceSwitchMessage = nil
                activeSheet = .sources
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(minHeight: 44)
            .disabled(sourceSwitching)
            .accessibilityLabel("换个源听")

            // 付费集：给一个能走下去的动作，别让用户对着原因干瞪眼。
            // 已登录但没会员 → 去开通；未登录 → 去登录。文案统一，动作一致。
            if player.errorText?.contains("付费内容") == true {
                Button("去登录 / 开通会员") {
                    sourceSwitchMessage = nil
                    activeSheet = .login
                }
                .foregroundStyle(.white)
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 32)
    }

    private var seekSecs: Int { LocalStore.loadPlayPrefs().seekSeconds }

    private var mainIcon: String {
        switch player.state {
        case .playing: return "pause.fill"
        case .loading: return "hourglass"
        case .error: return "arrow.clockwise"
        case .paused, .stopped: return "play.fill"
        }
    }

    private func refreshFavorite() {
        isFavorite = player.currentIsFavorite
    }

    private func toggleFavorite() {
        guard !player.currentBookUrl.isEmpty else { return }
        isFavorite = player.toggleCurrentFavorite()
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .chapters:
            ChapterSheet(chapters: player.chapterSnapshots,
                         currentTrackId: player.currentTrackId,
                         isReverse: player.isReverseOrder,
                         onReverse: { player.setReverseOrder(!player.isReverseOrder) },
                         onSelect: { trackId in
                             player.playChapter(trackId: trackId)
                             activeSheet = nil
                         })
        case .sleep:
            sleepSheet
        case .speed:
            speedSheet
        case .volume:
            volumeSheet
        case .sources:
            sourceSwitcher
        case .login:
            WebViewContainer(
                urls: LoginEndpoints.candidates,
                onLoggedIn: {
                    SharedBridge.invalidateSession()
                    NotificationCenter.default.post(name: .loginStateChanged, object: nil)
                    activeSheet = nil
                },
                onCancel: { activeSheet = nil }
            )
            .presentationBackground(Color(uiColor: .systemBackground))
        }
    }

    // MARK: - 换个源听

    /// 可选源清单：排除当前源；用户若在「源管理」里限定了启用集，只列启用的。
    private var switchableSources: [SharedBridge.SourceItem] {
        // 全部列出来，只排除当前正在用的那个源。
        // 这里**不**按「源管理」里的启用集过滤：那个设置控制的是浏览页里显示哪些站，
        // 不是「播放失败时允许换到哪些站」—— 换源本来就是救命动作，不该被限量。
        SharedBridge.allSources().filter { $0.id != player.currentSourceId }
    }

    private var sourceSwitcher: some View {
        SheetContainer {
            SheetTitle(icon: "square.stack.3d.up.fill", title: "换个源听")
            if sourceSwitching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在这个源里找同一本书…").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            if let msg = sourceSwitchMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 6)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(switchableSources, id: \.id) { src in
                        Button {
                            switchToSource(src.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(src.name).font(.callout)
                                    if !src.desc.isEmpty {
                                        Text(src.desc).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(sourceSwitching)
                        Divider().opacity(0.3)
                    }
                }
            }
            .frame(maxHeight: 340)
            Button("关闭") { activeSheet = nil }.disabled(sourceSwitching)
        }
    }

    /// 换源：用书名在新源里搜 → 取详情 → 找同名/同 trackId 的集 → 原地起播。
    /// 找不到就如实说，不偷偷播另一本。
    private func switchToSource(_ sourceId: String) {
        guard !sourceSwitching else { return }
        let title = player.currentBookTitle
        let trackId = player.currentTrackId
        let episodeTitle = player.nowPlaying
        guard !title.isEmpty else {
            sourceSwitchMessage = "当前播放没有书名信息，去书架里重新打开这本书再换源"
            return
        }
        sourceSwitching = true
        sourceSwitchMessage = nil
        Task { @MainActor in
            defer { sourceSwitching = false }
            guard let result = await SharedBridge.search(sourceId: sourceId, keywords: title, page: 1) else {
                sourceSwitchMessage = "这个源搜索失败，换个源试试"
                return
            }
            let cards = SharedBridge.cards(from: result)
            guard !cards.isEmpty else {
                sourceSwitchMessage = "这个源没有《\(title)》"
                return
            }
            // 优先完全同名；没有再取第一条（用户比过一眼就能判断是不是同一本）
            let match = cards.first { $0.title == title } ?? cards[0]
            guard let detail = await SharedBridge.bookDetail(sourceId: sourceId, bookUrl: match.bookUrl) else {
                sourceSwitchMessage = SharedBridge.lastDetailError ?? "这个源读取章节失败"
                return
            }
            let episodes = SharedBridge.rows(from: detail)
            let book = SharedBridge.card(from: detail.book)
            let episode = episodes.first { t in
                (trackId ?? 0) > 0 && t.trackId == (trackId ?? -1)
            }
                ?? episodes.first { $0.title == episodeTitle }
                ?? episodes.first
            guard let episode else {
                sourceSwitchMessage = "这个源里没有可播章节"
                return
            }
            player.playEpisode(episode, book: book, sourceId: sourceId, episodes: episodes)
            activeSheet = nil
        }
    }

    private var sleepSheet: some View {
        SheetContainer {
            SheetTitle(icon: "moon.zzz.fill", title: "定时停止播放")
            Picker("定时方式", selection: $sleepByChapter) {
                Text("按时间").tag(false)
                Text("按章节").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("定时方式")
            if sleepByChapter {
                Stepper("听完 \(sleepChapters) 章后停止",
                        value: $sleepChapters, in: 1...50)
                    .frame(minHeight: 52)
            } else {
                HStack(spacing: 0) {
                    Picker("小时", selection: $sleepHours) {
                        ForEach(0...12, id: \.self) { Text("\($0) 时").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .accessibilityLabel("小时")
                    Picker("分钟", selection: $sleepMinutes) {
                        ForEach(0...59, id: \.self) { Text("\($0) 分").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .accessibilityLabel("分钟")
                }
                .frame(height: 150)
            }
            Toggle("自动开启", isOn: Binding(
                get: { LocalStore.loadPlayPrefs().sleepAutoEnable },
                set: { value in
                    var prefs = LocalStore.loadPlayPrefs()
                    prefs.sleepAutoEnable = value
                    LocalStore.savePlayPrefs(prefs)
                }
            ))
            .frame(minHeight: 44)
            Button("关闭定时") {
                player.cancelSleepTimer()
                activeSheet = nil
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel("关闭定时")
            Button("确认开启") {
                if sleepByChapter {
                    player.startSleepTimer(minutes: 0, chapters: sleepChapters)
                } else {
                    player.startSleepTimer(minutes: sleepHours * 60 + sleepMinutes,
                                           chapters: 0)
                }
                activeSheet = nil
            }
            .buttonStyle(SheetPrimaryButtonStyle())
            .disabled(!sleepByChapter && sleepHours == 0 && sleepMinutes == 0)
            .accessibilityLabel("确认开启定时")
        }
    }

    private var speedSheet: some View {
        SheetContainer {
            HStack {
                Text("播放倍速调整")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("恢复默认") { speedDraft = 1.0 }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .accessibilityLabel("恢复默认倍速")
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 16) { speedValue; speedStepButtons }
                } else {
                    HStack(spacing: 24) { speedStepButtons; speedValue }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            Slider(value: $speedDraft, in: 0.5...3.0, step: 0.05)
                .tint(.blue)
                .accessibilityLabel("倍速")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach([0.5, 0.8, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0], id: \.self) { value in
                    Button(String(format: "%.2gx", value)) { speedDraft = value }
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(speedDraft == value ? Color.blue.opacity(0.16) : Color.secondary.opacity(0.1),
                                    in: Capsule())
                        .accessibilityLabel("\(value) 倍速")
                }
            }
            HStack(spacing: 12) {
                Button("取消") { activeSheet = nil }
                    .buttonStyle(SheetSecondaryButtonStyle())
                Button("完成设置") {
                    player.setSpeed(speedDraft)
                    activeSheet = nil
                }
                .buttonStyle(SheetPrimaryButtonStyle())
            }
        }
    }

    private var speedValue: some View {
        Text(String(format: "%.2fx", speedDraft))
            .font(.system(size: 36, weight: .semibold).monospacedDigit())
            .frame(minWidth: 132)
    }

    private var speedStepButtons: some View {
        HStack(spacing: 24) {
            stepButton(icon: "minus", label: "降低倍速") {
                speedDraft = max(0.5, speedDraft - 0.05)
            }
            stepButton(icon: "plus", label: "提高倍速") {
                speedDraft = min(3.0, speedDraft + 0.05)
            }
        }
    }

    private var volumeSheet: some View {
        SheetContainer {
            SheetTitle(icon: "speaker.wave.2.fill", title: "音量增强/减弱")
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 16) { volumeValue; volumeStepButtons }
                } else {
                    HStack(spacing: 24) { volumeStepButtons; volumeValue }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            Text("正增益受系统输出上限约束，过高可能失真。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("确定") {
                player.setVolumeGain(volumeDraft)
                activeSheet = nil
            }
            .buttonStyle(SheetPrimaryButtonStyle())
            .accessibilityLabel("确定音量增益")
        }
    }

    private var volumeValue: some View {
        VStack(spacing: 8) {
            Text(volumeName)
                .font(.title2.weight(.semibold))
            Text(String(format: "%+.0f dB", volumeDraft))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 5) {
                ForEach(-6...6, id: \.self) { dot in
                    Circle()
                        .fill(dot * 2 == Int(volumeDraft) ? Color.blue : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(minWidth: 140)
    }

    private var volumeStepButtons: some View {
        HStack(spacing: 24) {
            stepButton(icon: "minus", label: "降低音量增益") {
                volumeDraft = max(-12, volumeDraft - 1)
            }
            stepButton(icon: "plus", label: "提高音量增益") {
                volumeDraft = min(12, volumeDraft + 1)
            }
        }
    }

    private var volumeName: String {
        if volumeDraft >= 8 { return "显著增强" }
        if volumeDraft > 0 { return "适度增强" }
        if volumeDraft == 0 { return "原始音量" }
        if volumeDraft > -8 { return "适度减弱" }
        return "显著减弱"
    }

    private func stepButton(icon: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .accessibilityLabel(label)
    }
}

private struct ImmersivePosterBackground: View {
    let url: URL?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.7), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // 背景图必须被父级尺寸约束：只用 maxWidth/.infinity 会让 AsyncImage 按
            // 图片原始比例算出超大 ideal 尺寸，把整个 ZStack 撑到宽于屏幕。
            GeometryReader { g in
                PlayerPosterImage(url: url)
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
                    .blur(radius: 50)
                    .scaleEffect(1.2)
                    .drawingGroup()
            }
            Color.black.opacity(0.62)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 0.72),
                .init(color: .black.opacity(0.72), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

private struct PlayerPosterImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure, .empty:
                placeholder
            @unknown default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(colors: [Color.accentColor, Color.indigo, Color.black],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct ChapterSheet: View {
    let chapters: [Player.ChapterSnapshot]
    let currentTrackId: Int64?
    let isReverse: Bool
    let onReverse: () -> Void
    let onSelect: (Int64) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("章节列表")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                Text("目录 \(chapters.count)章")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(uiColor: .darkGray), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                Button(isReverse ? "倒序" : "正序", action: onReverse)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("切换章节排序")
            }
            .padding(.horizontal, 20)
            if chapters.isEmpty {
                Spacer()
                Text("当前记录没有章节目录，请从专辑详情页进入播放。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Spacer()
            } else {
                List(isReverse ? chapters.sorted(by: { $0.number > $1.number }) : chapters.sorted(by: { $0.number < $1.number })) { chapter in
                    Button {
                        onSelect(chapter.trackId)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(chapter.title)
                                    .font(.system(size: 17))
                                    .lineLimit(2)
                                Text("第 \(chapter.number) 章")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                        }
                        .foregroundStyle(chapter.trackId == currentTrackId ? Color.blue : Color.primary)
                        .frame(minHeight: 52)
                    }
                    .accessibilityLabel("播放第 \(chapter.number) 章 \(chapter.title)")
                }
                .listStyle(.plain)
            }
        }
        .padding(.top, 16)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}

private struct SheetContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) { content }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
    }
}

private struct SheetTitle: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.blue, in: Circle())
            Text(title)
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SheetPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                LinearGradient(colors: [Color.blue, Color.blue.opacity(0.72)],
                               startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct SheetSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

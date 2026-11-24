import SwiftUI

/// 专辑海报播放页：静态虚化背景与可暂停、可续转的封面时钟。
struct PlayerView: View {
    @ObservedObject private var player = Player.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationClock = CoverRotationClock()
    @State private var dragValue: Double?
    @State private var showSpeed = false
    @State private var showSleep = false
    @State private var sleepMinutes = 30
    @State private var sleepChapters = 3
    @State private var sleepModeIsChapter = false

    private var shouldRotate: Bool {
        player.state == .playing && !reduceMotion
    }

    private var backgroundIsDimmed: Bool {
        player.state == .loading || player.state == .error
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PosterBackground(
                    coverURL: coverURL,
                    isDimmed: backgroundIsDimmed,
                    isDark: colorScheme == .dark
                )

                ScrollView(.vertical, showsIndicators: false) {
                    if geo.size.width > geo.size.height && geo.size.height < 500 {
                        HStack(alignment: .center, spacing: 24) {
                            poster(size: coverSize(width: geo.size.width / 2,
                                                   height: geo.size.height))
                            controlsColumn(width: geo.size.width / 2)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height - 64,
                               alignment: .center)
                    } else {
                        VStack(spacing: 18) {
                            poster(size: coverSize(width: geo.size.width,
                                                   height: geo.size.height))
                            controlsColumn(width: geo.size.width)
                        }
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height - 64,
                               alignment: .center)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .navigationTitle("播放")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    player.showFullScreen = false
                } label: {
                    Label("收起", systemImage: "chevron.down")
                }
                .accessibilityLabel("收起播放页")
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            rotationClock.setPlaying(shouldRotate)
            CrashLog.write("UI", "player appear track=\(player.nowPlaying)")
        }
        .onChange(of: shouldRotate) { _, playing in
            rotationClock.setPlaying(playing)
        }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.height > 120 ||
                        value.predictedEndTranslation.height > 220 {
                        player.showFullScreen = false
                    }
                }
        )
        .onDisappear {
            rotationClock.setPlaying(false)
            CrashLog.write("UI", "player disappear track=\(player.nowPlaying)")
        }
        .sheet(isPresented: $showSpeed) { speedSheet }
        .sheet(isPresented: $showSleep) { sleepSheet }
        .accessibilityElement(children: .contain)
    }

    private func controlsColumn(width: CGFloat) -> some View {
        VStack(spacing: 18) {
            information
            if let error = player.errorText {
                errorPanel(error)
            }
            progressControls
            transportControls(width: width)
            settingControls
        }
        .frame(maxWidth: 520)
    }

    private var coverURL: URL? {
        guard let url = URL(string: player.currentCoverUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func coverSize(width: CGFloat, height: CGFloat) -> CGFloat {
        min(280, max(160, min(width - 80, height * 0.37)))
    }

    private func poster(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 10)
                .frame(width: size + 20, height: size + 20)
            Circle()
                .stroke(.black.opacity(0.36), lineWidth: 1)
                .frame(width: size + 9, height: size + 9)
            Group {
                if shouldRotate {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                        posterArtwork(size: size, angle: rotationClock.angle(
                            at: timeline.date.timeIntervalSinceReferenceDate))
                    }
                } else {
                    posterArtwork(size: size, angle: rotationClock.angle)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func posterArtwork(size: CGFloat, angle: Double) -> some View {
        PosterCover(coverURL: coverURL, size: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.36), radius: 24, y: 14)
            .rotationEffect(.degrees(angle))
            .drawingGroup()
    }

    private var information: some View {
        VStack(spacing: 8) {
            Text(player.nowPlaying.isEmpty ? "未选择曲目" : player.nowPlaying)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if !player.currentBookTitle.isEmpty {
                Text(player.currentBookTitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            Text(player.state.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(controlCapsule, in: Capsule())
            if player.nowPlaying.isEmpty {
                Text("先去「书架」搜索，或到「浏览」按源找书")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.76))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(controlCapsule,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if player.canRetry {
                Button {
                    player.retry()
                } label: {
                    Label("重试这一集", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: Layout.hitTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .accessibilityLabel("重试这一集")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(controlCapsule,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var progressControls: some View {
        VStack(spacing: 6) {
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
            .disabled(player.state != .playing && player.state != .paused)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(Int(player.position * 100))%")
            HStack {
                Text(player.elapsedText)
                Spacer()
                Text(player.durationText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(controlCapsule,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func transportControls(width: CGFloat) -> some View {
        HStack(spacing: 24) {
            Button {
                player.skip(false)
            } label: {
                Image(systemName: "gobackward.\(seekSecs)")
                    .font(.title2)
                    .frame(width: Layout.hitTarget, height: Layout.hitTarget)
            }
            .disabled(!player.canSeek)
            .accessibilityLabel("后退 \(seekSecs) 秒")

            Button {
                if player.state == .playing {
                    player.pause()
                } else {
                    player.resume()
                }
            } label: {
                Image(systemName: mainIcon)
                    .font(.system(size: min(72, Layout.mainButton(width))))
                    .frame(width: 80, height: 80)
            }
            .disabled(player.state == .stopped || player.state == .loading)
            .accessibilityLabel(player.state == .playing ? "暂停" : "播放")

            Button {
                player.skip(true)
            } label: {
                Image(systemName: "goforward.\(seekSecs)")
                    .font(.title2)
                    .frame(width: Layout.hitTarget, height: Layout.hitTarget)
            }
            .disabled(!player.canSeek)
            .accessibilityLabel("前进 \(seekSecs) 秒")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(controlCapsule, in: Capsule())
    }

    private var settingControls: some View {
        HStack(spacing: 8) {
            settingButton(
                title: String(format: "%.2fx", player.currentSpeed),
                hint: "倍速",
                active: player.currentSpeed != 1.0
            ) { showSpeed = true }
            settingButton(
                title: sleepShortLabel,
                hint: "定时",
                active: player.sleepRemainingText != nil
            ) { showSleep = true }
            settingButton(
                title: player.isReverseOrder ? "倒序" : "正序",
                hint: "播放顺序",
                active: player.isReverseOrder
            ) { player.setReverseOrder(!player.isReverseOrder) }
        }
    }

    private func settingButton(title: String, hint: String, active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Color.accentColor : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: Layout.hitTarget)
            .background(controlCapsule, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(hint) \(title)")
    }

    private var controlCapsule: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(.black.opacity(0.36))
        }
        return AnyShapeStyle(.thinMaterial)
    }

    private var sleepShortLabel: String {
        guard let full = player.sleepRemainingText else { return "定时" }
        if let range = full.range(of: " ") {
            return String(full[range.upperBound...])
        }
        return full
    }

    private var seekSecs: Int {
        LocalStore.loadPlayPrefs().seekSeconds
    }

    private var mainIcon: String {
        switch player.state {
        case .playing: return "pause.circle.fill"
        case .loading: return "hourglass.circle"
        case .error: return "arrow.clockwise.circle.fill"
        case .paused, .stopped: return "play.circle.fill"
        }
    }

    private var speedSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("当前倍速")
                        Spacer()
                        Text(String(format: "%.2fx", player.currentSpeed))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { player.currentSpeed },
                        set: { player.setSpeed($0) }
                    ), in: 0.5...3.0, step: 0.05)
                    HStack {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { value in
                            Button(String(format: "%.2gx", value)) {
                                player.setSpeed(value)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
                Section("作用域") {
                    Toggle("本专辑独立设置", isOn: Binding(
                        get: { !LocalStore.loadPlayPrefs().useGlobalSpeed },
                        set: { off in
                            var prefs = LocalStore.loadPlayPrefs()
                            prefs.useGlobalSpeed = !off
                            LocalStore.savePlayPrefs(prefs)
                        }
                    ))
                    Text("关闭时所有专辑共用一个倍速，打开时每本书记住自己的。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("跳过片头 / 片尾") {
                    Stepper("片头 \(skipIntro) 秒", value: Binding(
                        get: { skipIntro },
                        set: { player.setSkip(intro: $0, outro: nil) }
                    ), in: 0...300, step: 5)
                    Stepper("片尾 \(skipOutro) 秒", value: Binding(
                        get: { skipOutro },
                        set: { player.setSkip(intro: nil, outro: $0) }
                    ), in: 0...300, step: 5)
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showSpeed = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var skipIntro: Int {
        guard let book = player.currentBookCard else { return 0 }
        let key = BookKey(sourceId: player.currentSourceId,
                          albumId: book.albumId, bookUrl: book.bookUrl)
        return LocalStore.effective(for: key,
                                    prefs: LocalStore.loadPlayPrefs()).skipIntroSec
    }

    private var skipOutro: Int {
        guard let book = player.currentBookCard else { return 0 }
        let key = BookKey(sourceId: player.currentSourceId,
                          albumId: book.albumId, bookUrl: book.bookUrl)
        return LocalStore.effective(for: key,
                                    prefs: LocalStore.loadPlayPrefs()).skipOutroSec
    }

    private var sleepSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("方式", selection: $sleepModeIsChapter) {
                        Text("按时间").tag(false)
                        Text("按章节").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if sleepModeIsChapter {
                        Stepper("听完 \(sleepChapters) 章后停",
                                value: $sleepChapters, in: 1...50)
                    } else {
                        Stepper("定时 \(sleepMinutes) 分钟",
                                value: $sleepMinutes, in: 5...180)
                    }
                }
                Section {
                    Toggle("重启后自动重新定时", isOn: Binding(
                        get: { LocalStore.loadPlayPrefs().sleepAutoEnable },
                        set: { value in
                            var prefs = LocalStore.loadPlayPrefs()
                            prefs.sleepAutoEnable = value
                            LocalStore.savePlayPrefs(prefs)
                        }
                    ))
                } footer: {
                    Text("开启后，下次启动 App 会按这次设置的时长重新开始计时。")
                }
                Section {
                    Button("开始定时") {
                        player.startSleepTimer(
                            minutes: sleepModeIsChapter ? 0 : sleepMinutes,
                            chapters: sleepModeIsChapter ? sleepChapters : 0
                        )
                        showSleep = false
                    }
                    Button("取消定时", role: .destructive) {
                        player.cancelSleepTimer()
                        showSleep = false
                    }
                }
            }
            .navigationTitle("睡眠定时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showSleep = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 只累计实际播放的时间；暂停、加载、失败和减少动态效果都保留角度。
private struct CoverRotationClock {
    private(set) var angle: Double = 0
    private var startedAt: TimeInterval?
    private let period: TimeInterval = 20

    mutating func setPlaying(_ playing: Bool, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        if playing {
            guard startedAt == nil else { return }
            startedAt = now
        } else {
            guard let start = startedAt else { return }
            angle = normalized(angle + (now - start) * 360 / period)
            startedAt = nil
        }
    }

    func angle(at now: TimeInterval) -> Double {
        guard let start = startedAt else { return angle }
        return normalized(angle + max(0, now - start) * 360 / period)
    }

    private func normalized(_ value: Double) -> Double {
        value.truncatingRemainder(dividingBy: 360)
    }
}

private struct PosterBackground: View {
    let coverURL: URL?
    let isDimmed: Bool
    let isDark: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.68),
                         Color.indigo.opacity(0.64),
                         Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            PosterImage(url: coverURL, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 60)
                .saturation(1.16)
                .scaleEffect(1.15)
                .drawingGroup()
            LinearGradient(
                stops: gradientStops,
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .brightness(isDimmed ? -0.45 : 0)
        .animation(.easeInOut(duration: 0.2), value: isDimmed)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var gradientStops: [Gradient.Stop] {
        if isDark {
            return [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .black.opacity(0.55), location: 0.46),
                .init(color: .black.opacity(0.85), location: 1)
            ]
        }
        return [
            .init(color: .white.opacity(0.55), location: 0),
            .init(color: .black.opacity(0.22), location: 0.42),
            .init(color: .black.opacity(0.62), location: 1)
        ]
    }
}

private struct PosterCover: View {
    let coverURL: URL?
    let size: CGFloat

    var body: some View {
        PosterImage(url: coverURL, contentMode: .fill)
            .frame(width: size, height: size)
            .background(placeholder)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor, Color.indigo, Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "book.closed.fill")
                .font(.system(size: 58))
                .foregroundStyle(.white.opacity(0.82))
        }
    }
}

private struct PosterImage: View {
    let url: URL?
    let contentMode: ContentMode

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .failure:
                placeholder
            case .empty:
                placeholder
            @unknown default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color.accentColor, Color.indigo, Color.black],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

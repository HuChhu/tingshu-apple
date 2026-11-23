import SwiftUI

/// 播放页：当前集、状态、进度条、错误。
/// 数据流：AlbumView 选集 → Player.playEpisode → SharedBridge.extract（引擎 级1→级3）→ AVPlayer。
/// 进度每 5 秒落 LocalStore，切后台或退出可在原位置续播。
struct PlayerView: View {
    @ObservedObject private var player = Player.shared
    @State private var dragValue: Double?
    @State private var showSpeed = false
    @State private var showSleep = false
    @State private var sleepMinutes = 30
    @State private var sleepChapters = 3
    @State private var sleepModeIsChapter = false

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width)
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            Image(systemName: icon)
                .font(.system(size: Layout.heroIcon(width)))
                .foregroundStyle(player.state == .error ? Color.red : Color.accentColor)
                .symbolEffect(.variableColor.iterative, isActive: player.state == .playing)

            VStack(spacing: 6) {
                Text(player.nowPlaying.isEmpty ? "未选择曲目" : player.nowPlaying)
                    .font(.headline).multilineTextAlignment(.center).lineLimit(2)
                Text(player.state.rawValue)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                if player.nowPlaying.isEmpty {
                    Text("先去「书架」搜索，或到「浏览」按源找书")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal)

            if let err = player.errorText {
                VStack(spacing: 10) {
                    Text(err).font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    if player.canRetry {
                        Button {
                            player.retry()          // 地址过期 / 网络恢复后原地重试，不用回列表
                        } label: {
                            Label("重试这一集", systemImage: "arrow.clockwise")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
            }

            // 进度条（拖动时用本地值，松手才 seek）
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { dragValue ?? player.position },
                        set: { dragValue = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing, let v = dragValue {
                            player.seek(toFraction: v)
                            dragValue = nil
                        }
                    }
                )
                .disabled(player.state != .playing && player.state != .paused)
                HStack {
                    Text(player.elapsedText).font(.caption2.monospacedDigit())
                    Spacer()
                    Text(player.durationText).font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            HStack(spacing: 28) {
                Button {
                    player.skip(false)
                } label: {
                    Image(systemName: "gobackward.\(seekSecs)").font(.title2)
                }
                .disabled(!player.canSeek)

                Button {
                    if player.state == .playing { player.pause() } else { player.resume() }
                } label: {
                    Image(systemName: mainIcon)
                        .font(.system(size: Layout.mainButton(width)))
                }
                .disabled(player.state == .stopped || player.state == .loading)

                Button {
                    player.skip(true)
                } label: {
                    Image(systemName: "goforward.\(seekSecs)").font(.title2)
                }
                .disabled(!player.canSeek)
            }
            .padding(.top, 8)

            // ===== 播放设置条（v1.3.0）=====
            HStack(spacing: 10) {
                Button {
                    showSpeed = true
                } label: {
                    Text(String(format: "%.2fx", player.currentSpeed))
                        .font(.caption).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }

                Button {
                    showSleep = true
                } label: {
                    Label(sleepLabel, systemImage: "moon.zzz")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }

                Button {
                    player.setReverseOrder(!player.isReverseOrder)
                } label: {
                    Image(systemName: player.isReverseOrder ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(player.isReverseOrder ? Color.accentColor : Color.secondary)
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Spacer()
        }
        .padding(.top, 24)
        .navigationTitle("播放")
        // 全屏播放页（RootTabView 的 fullScreenCover）需要一个关闭入口；
        // 从 Tab 进来的 PlayerView 里这个按钮只是把 showFullScreen 置 false，无副作用。
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    player.showFullScreen = false
                } label: {
                    Label("收起", systemImage: "chevron.down")
                }
            }
        }
        .sheet(isPresented: $showSpeed) { speedSheet }
        .sheet(isPresented: $showSleep) { sleepSheet }
    }

    private var sleepLabel: String {
        if let left = player.sleepRemainingText { return left }
        return "定时"
    }

    /// 倍速面板：滑块 + 快捷档 + 「应用全局」开关
    private var speedSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("当前倍速")
                        Spacer()
                        Text(String(format: "%.2fx", player.currentSpeed))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { player.currentSpeed },
                        set: { player.setSpeed($0) }
                    ), in: 0.5...3.0, step: 0.05)
                    HStack(spacing: 8) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { v in
                            Button(String(format: "%.2gx", v)) { player.setSpeed(v) }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                }

                Section("作用域") {
                    Toggle("本专辑独立设置", isOn: Binding(
                        get: { !LocalStore.loadPlayPrefs().useGlobalSpeed },
                        set: { off in
                            var p = LocalStore.loadPlayPrefs()
                            p.useGlobalSpeed = !off
                            LocalStore.savePlayPrefs(p)
                        }
                    ))
                    Text("关闭时所有专辑共用一个倍速；打开时每本书记住自己的。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("跳过片头 / 片尾") {
                    Stepper("片头 \(skipIntro) 秒",
                            value: Binding(get: { skipIntro }, set: { player.setSkip(intro: $0, outro: nil) }),
                            in: 0...300, step: 5)
                    Stepper("片尾 \(skipOutro) 秒",
                            value: Binding(get: { skipOutro }, set: { player.setSkip(intro: nil, outro: $0) }),
                            in: 0...300, step: 5)
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { showSpeed = false }
            }}
        }
        .presentationDetents([.medium, .large])
    }

    private var skipIntro: Int {
        guard let b = player.currentBookCard else { return 0 }
        let k = BookKey(sourceId: player.currentSourceId, albumId: b.albumId, bookUrl: b.bookUrl)
        return LocalStore.effective(for: k, prefs: LocalStore.loadPlayPrefs()).skipIntroSec
    }

    private var skipOutro: Int {
        guard let b = player.currentBookCard else { return 0 }
        let k = BookKey(sourceId: player.currentSourceId, albumId: b.albumId, bookUrl: b.bookUrl)
        return LocalStore.effective(for: k, prefs: LocalStore.loadPlayPrefs()).skipOutroSec
    }

    /// 定时面板：按时间 / 按章节 + 自动开启
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
                        Stepper("听完 \(sleepChapters) 章后停", value: $sleepChapters, in: 1...50)
                    } else {
                        Stepper("定时 \(sleepMinutes) 分钟", value: $sleepMinutes, in: 5...180, step: 5)
                    }
                }

                Section {
                    Toggle("重启后自动重新定时", isOn: Binding(
                        get: { LocalStore.loadPlayPrefs().sleepAutoEnable },
                        set: { v in
                            var p = LocalStore.loadPlayPrefs()
                            p.sleepAutoEnable = v
                            LocalStore.savePlayPrefs(p)
                        }
                    ))
                } footer: {
                    Text("开启后，下次启动 App 会按这次设置的时长重新开始计时。")
                }

                Section {
                    Button("开始定时") {
                        player.startSleepTimer(minutes: sleepModeIsChapter ? 0 : sleepMinutes,
                                               chapters: sleepModeIsChapter ? sleepChapters : 0)
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { showSleep = false }
            }}
        }
        .presentationDetents([.medium])
    }

    /// 从设置读取快进快退秒数（对应安卓设置页第 8 项）
    private var seekSecs: Int {
        LocalStore.loadPlayPrefs().seekSeconds
    }

    /// 主键图标：失败态显示刷新符（点了=重试），加载/缓冲中显示沙漏
    private var mainIcon: String {
        switch player.state {
        case .playing: return "pause.circle.fill"
        case .loading: return "hourglass.circle"
        case .error: return "arrow.clockwise.circle.fill"
        case .paused, .stopped: return "play.circle.fill"
        }
    }

    private var icon: String {
        switch player.state {
        case .playing: return "waveform"
        case .loading: return "hourglass"
        case .error: return "exclamationmark.triangle"
        case .paused: return "pause.circle"
        case .stopped: return "play.circle"
        }
    }
}

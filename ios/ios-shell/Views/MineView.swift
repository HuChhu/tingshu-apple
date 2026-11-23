import SwiftUI
import UIKit
import Foundation

/// 「我的」：账号 + 二级入口（源管理、播放设置、缓存、日志、关于）。
/// 设计原则（按用户反馈）：设置项收进二级页，首页只留一级入口，一眼能扫完。
struct MineView: View {
    @State private var loggedIn = SharedBridge.loggedIn
    @State private var cacheBytes: Int64 = AudioCache.totalBytes()
    @State private var logBytes: Int64 = CrashLog.totalBytes
    @State private var favCount = 0

    var body: some View {
        NavigationStack {
            List {
                // 账号卡
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: loggedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                            .font(.system(size: 34))
                            .foregroundStyle(loggedIn ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(loggedIn ? "已登录喜马拉雅" : "未登录")
                                .font(.headline)
                            Text(loggedIn ? "可听会员内容" : "登录后可听会员专辑")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section("内容") {
                    NavigationLink {
                        FavoritesPage()
                    } label: {
                        Label("我的收藏", systemImage: "heart")
                            .badge(favCount)
                    }
                    NavigationLink {
                        HistoryPage()
                    } label: {
                        Label("播放历史", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink {
                        DownloadsPage()
                    } label: {
                        Label("下载管理", systemImage: "arrow.down.circle")
                    }
                }

                Section("设置") {
                    NavigationLink {
                        SourcesView()
                    } label: {
                        Label("书源管理", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink {
                        PlaybackSettingsPage()
                    } label: {
                        Label("播放设置", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("账号与通用", systemImage: "gearshape")
                    }
                }

                Section("诊断") {
                    NavigationLink {
                        LogViewerPage()
                    } label: {
                        HStack {
                            Label("运行日志", systemImage: "doc.text.magnifyingglass")
                            Spacer()
                            Text(byteText(logBytes)).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    Text("闪退或播放出错时，把这里的日志发给我能精确定位。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Text("缓存占用")
                        Spacer()
                        Text(byteText(cacheBytes)).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                }
            }
            .navigationTitle("我的")
            .onAppear {
                loggedIn = SharedBridge.loggedIn
                cacheBytes = AudioCache.totalBytes()
                logBytes = CrashLog.totalBytes
                favCount = LocalStore.loadFavorites().count
            }
        }
    }

    private func byteText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - 二级页

/// 收藏列表
struct FavoritesPage: View {
    @State private var items: [LocalStore.Favorite] = []

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("还没有收藏", systemImage: "heart",
                                       description: Text("在专辑详情页右上角点心形收藏"))
            } else {
                List(items) { f in
                    NavigationLink {
                        AlbumView(card: SharedBridge.BookCard(
                            bookUrl: f.bookUrl, title: f.title, author: f.author,
                            coverUrl: f.coverUrl, albumId: f.albumId,
                            trackCount: 0, playCount: 0, isFinished: nil),
                                  sourceId: f.sourceId)
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: f.coverUrl)) { img in
                                img.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.title).font(.body).lineLimit(2)
                                Text(f.author).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("我的收藏")
        .onAppear { items = LocalStore.loadFavorites() }
    }
}

/// 播放历史
struct HistoryPage: View {
    @State private var items: [LocalStore.Recent] = []

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("还没有播放记录", systemImage: "clock",
                                       description: Text("点一集开始播放就会记录"))
            } else {
                List(items) { r in
                    Button {
                        let ep = LocalStore.recentEpisode(r)
                        Player.shared.playEpisode(ep, book: LocalStore.recentBook(r), sourceId: r.sourceId)
                        Player.shared.showFullScreen = true
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.bookTitle).font(.body).lineLimit(1)
                            Text(r.episodeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(r.playedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("播放历史")
        .onAppear { items = LocalStore.loadRecent() }
    }
}

/// 下载管理（占位，后续接 AudioCache 列表）
struct DownloadsPage: View {
    var body: some View {
        ContentUnavailableView("下载管理", systemImage: "arrow.down.circle",
                               description: Text("边听边缓存已开启时会自动保存最近 3 集。"))
            .navigationTitle("下载管理")
    }
}

/// 播放设置（从设置页拆出来的一级页面）
struct PlaybackSettingsPage: View {
    @State private var prefs = LocalStore.loadPlayPrefs()

    var body: some View {
        Form {
            Section("快进快退") {
                Picker("秒数", selection: Binding(
                    get: { prefs.seekSeconds },
                    set: { prefs.seekSeconds = $0; LocalStore.savePlayPrefs(prefs) }
                )) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) 秒").tag($0) }
                }
            }

            Section("倍速") {
                HStack {
                    Text("默认倍速")
                    Spacer()
                    Text(String(format: "%.2fx", prefs.defaultSpeed))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { prefs.defaultSpeed },
                    set: { prefs.defaultSpeed = $0; LocalStore.savePlayPrefs(prefs) }
                ), in: 0.5...3.0, step: 0.05)
                Toggle("所有专辑用同一倍速", isOn: Binding(
                    get: { prefs.useGlobalSpeed },
                    set: { prefs.useGlobalSpeed = $0; LocalStore.savePlayPrefs(prefs) }
                ))
            }

            Section("跳过") {
                Stepper("片头 \(prefs.defaultSkipIntroSec) 秒",
                        value: Binding(get: { prefs.defaultSkipIntroSec },
                                       set: { prefs.defaultSkipIntroSec = $0; LocalStore.savePlayPrefs(prefs) }),
                        in: 0...300, step: 5)
                Stepper("片尾 \(prefs.defaultSkipOutroSec) 秒",
                        value: Binding(get: { prefs.defaultSkipOutroSec },
                                       set: { prefs.defaultSkipOutroSec = $0; LocalStore.savePlayPrefs(prefs) }),
                        in: 0...300, step: 5)
                Toggle("按专辑独立设置", isOn: Binding(
                    get: { !prefs.useGlobalSkip },
                    set: { prefs.useGlobalSkip = !$0; LocalStore.savePlayPrefs(prefs) }
                ))
            }

            Section("其它") {
                Toggle("恢复播放后退", isOn: Binding(
                    get: { prefs.resumeRewindSeconds > 0 },
                    set: { prefs.resumeRewindSeconds = $0 ? 5 : 0; LocalStore.savePlayPrefs(prefs) }
                ))
                Toggle("进入播放页自动播放", isOn: Binding(
                    get: { prefs.autoPlayOnOpen },
                    set: { prefs.autoPlayOnOpen = $0; LocalStore.savePlayPrefs(prefs) }
                ))
                Toggle("跳过无声部分", isOn: Binding(
                    get: { prefs.skipSilence },
                    set: { prefs.skipSilence = $0; LocalStore.savePlayPrefs(prefs) }
                ))
            }
        }
        .navigationTitle("播放设置")
    }
}

/// 日志查看 / 分享
struct LogViewerPage: View {
    @State private var text = ""
    @State private var showShare = false

    var body: some View {
        Group {
            if text.isEmpty {
                ContentUnavailableView("还没有日志", systemImage: "doc.text",
                                       description: Text("这个 App 还没写入过日志"))
            } else {
                ScrollView {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle("运行日志")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showShare = true
                    } label: { Label("分享", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) {
                        CrashLog.clear()
                        text = ""
                    } label: { Label("清空", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [text])
        }
        .onAppear { text = CrashLog.merged() }
    }
}

/// 系统分享面板包装
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

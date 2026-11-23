import SwiftUI

/// 设置页：登录状态 / 登录 / 登出 / 缓存清理。
/// 引擎限速与预算状态也在这里展示，方便判断当前是否被风控降级。
struct SettingsView: View {
    @State private var loggedIn = SharedBridge.loggedIn
    @State private var showLogin = false
    @State private var cookieNames: [String] = []
    @State private var prefs = LocalStore.loadPlayPrefs()
    /// P1-10：缓存占用的触发号 —— 清缓存后 +1，让「已用空间」那一行重读磁盘，
    /// 同时发通知让书架/专辑页的缓存角标跟着刷新（原来是写完没人读的死状态）
    @State private var cacheRefresh = 0
    @State private var cacheBytes: Int64 = AudioCache.totalBytes()

    var body: some View {
        NavigationStack {
            Form {
                Section("喜马拉雅账号") {
                    HStack {
                        Image(systemName: loggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                            .foregroundStyle(loggedIn ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loggedIn ? "已登录" : "未登录")
                            Text(loggedIn ? "搜索与专辑接口可直连" : "未登录时专辑接口返回 status=76")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if !loggedIn {
                        Button("登录喜马拉雅") { showLogin = true }
                    } else {
                        Button("退出登录", role: .destructive) {
                            CookieStore.clearAll()
                            SharedBridge.invalidateSession()
                            refresh()
                        }
                    }
                }

                if loggedIn && !cookieNames.isEmpty {
                    Section("已获取凭据字段") {
                        Text(cookieNames.joined(separator: "、"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("只显示字段名，不显示值。
                // 引擎侧 Cookie 注入状态：登录了却还提示「需要登录」时，一眼看出是这里的问题
                if loggedIn {
                    LabeledContent("引擎接管", value: SharedBridge.engineCookieLength > 0
                        ? "已同步（\(SharedBridge.engineCookieLength) 字符）"
                        : "未同步 · 点此重试")
                        .onTapGesture { SharedBridge.injectCookie() }
                }")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section("播放设置") {
                    Picker("快进快退秒数", selection: Binding(
                        get: { prefs.seekSeconds },
                        set: { prefs.seekSeconds = $0; LocalStore.savePlayPrefs(prefs) }
                    )) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) 秒").tag($0) }
                    }

                    Picker("恢复播放后退", selection: Binding(
                        get: { prefs.resumeRewindSeconds },
                        set: { prefs.resumeRewindSeconds = $0; LocalStore.savePlayPrefs(prefs) }
                    )) {
                        Text("关闭").tag(0)
                        ForEach([3, 5, 10], id: \.self) { Text("后退 \($0) 秒").tag($0) }
                    }

                    Toggle("进入播放页自动播放", isOn: Binding(
                        get: { prefs.autoPlayOnOpen },
                        set: { prefs.autoPlayOnOpen = $0; LocalStore.savePlayPrefs(prefs) }
                    ))

                    Toggle("跳过无声部分", isOn: Binding(
                        get: { prefs.skipSilence },
                        set: { prefs.skipSilence = $0; LocalStore.savePlayPrefs(prefs) }
                    ))
                }

                Section("缓存") {
                    LabeledContent("已用空间", value: AudioCache.humanSize(cacheBytes))
                    Button("清除所有音频缓存", role: .destructive) {
                        AudioCache.clearAll()
                        // P1-10：cacheRefresh 从「只写不读」改成真实触发点：
                        // 值一变 → 下面的 reloadTask 跑一次 → 重读磁盘 + 通知别的页
                        cacheRefresh += 1
                    }
                    .disabled(cacheBytes == 0)
                    if cacheBytes == 0 {
                        Text("当前没有缓存音频").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("风控纪律") {
                    LabeledContent("请求限速", value: "1 次 / 秒")
                    LabeledContent("网页搜索预算", value: "3 次，冷却 30 秒")
                    Text("触发风控时引擎降级返回提示，不硬冲、不重试。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.versionText)
                    LabeledContent("引擎", value: "Kotlin Multiplatform")
                }

                Section("设备") {
                    LabeledContent("机型", value: DeviceInfo.modelName)
                    LabeledContent("系统", value: DeviceInfo.systemVersion)
                    LabeledContent("屏幕", value: DeviceInfo.screenText)
                    LabeledContent("App 最低要求", value: DeviceInfo.minOS)
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showLogin) {
                WebViewContainer(
                    urls: LoginEndpoints.candidates,
                    onLoggedIn: {
                        SharedBridge.invalidateSession()
                        refresh()
                        showLogin = false
                    },
                    onCancel: { showLogin = false }
                )
            }
            .onAppear { refresh() }
            // P1-10：cacheRefresh 一变就重读缓存占用，并广播给书架/专辑页
            .task(id: cacheRefresh) {
                guard cacheRefresh > 0 else { return }
                cacheBytes = AudioCache.totalBytes()
                NotificationCenter.default.post(name: .audioCacheCleared, object: nil)
            }
        }
    }

    private func refresh() {
        loggedIn = SharedBridge.loggedIn
        cookieNames = CookieStore.flatMap().keys.sorted()
        cacheBytes = AudioCache.totalBytes()   // 进页面/登出后重读缓存占用
    }
}

/// 设备信息：用于确认包跑在什么机器上、系统是不是够新
enum DeviceInfo {
    /// 从 utsname 拿真实机型标识（如 iPhone17,1），再翻成市场名
    static var modelName: String {
        var sys = utsname()
        uname(&sys)
        let id = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return "\(friendlyName(id)) (\(id))"
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// 屏幕逻辑尺寸与倍率（从 App 主 window 取，避免 UIScreen.main 废弃问题）
    static var screenText: String {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let screen = scenes.first?.screen
        let b = screen?.bounds.size ?? CGSize(width: 0, height: 0)
        let scale = screen?.scale ?? 0
        return "\(Int(b.width))×\(Int(b.height)) @\(Int(scale))x"
    }

    /// 装在机器上的系统版本必须 >= 这个值
    static var minOS: String {
        (Bundle.main.infoDictionary?["MinimumOSVersion"] as? String) ?? "-"
    }

    /// 机型标识 → 市场名。只覆盖已知机型，未知时原样显示标识。
    private static func friendlyName(_ id: String) -> String {
        let table: [String: String] = [
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
            "iPhone19,1": "iPhone 18 Pro",
            "iPhone19,2": "iPhone 18 Pro Max",
            "iPhone19,3": "iPhone 18",
            "iPhone19,4": "iPhone 18 Plus",
        ]
        return table[id] ?? id
    }
}

extension Notification.Name {
    /// 音频缓存被清空（P1-10）：书架/专辑页收到后重读缓存占用
    static let audioCacheCleared = Notification.Name("tingshu.audioCacheCleared")
}

private extension Bundle {
    var versionText: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

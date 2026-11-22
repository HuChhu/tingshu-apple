import SwiftUI

/// 设置页：登录状态 / 登录 / 登出 / 缓存清理。
/// 引擎限速与预算状态也在这里展示，方便判断当前是否被风控降级。
struct SettingsView: View {
    @State private var loggedIn = SharedBridge.loggedIn
    @State private var showLogin = false
    @State private var cookieNames: [String] = []

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
                        Text("只显示字段名，不显示值。")
                            .font(.caption2).foregroundStyle(.secondary)
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
        }
    }

    private func refresh() {
        loggedIn = SharedBridge.loggedIn
        cookieNames = CookieStore.flatMap().keys.sorted()
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

private extension Bundle {
    var versionText: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

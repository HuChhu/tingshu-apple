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
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showLogin) {
                WebViewContainer(
                    url: URL(string: "https://passport.ximalaya.com/page/mobile_login")!,
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

private extension Bundle {
    var versionText: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

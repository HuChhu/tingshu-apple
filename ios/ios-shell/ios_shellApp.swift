import SwiftUI

@main
struct TingshuRootApp: App {
    init() {
        // 最早时机装崩溃钩子：未捕获 NSException 会在进程退出前落盘
        CrashLog.installUncaughtHandler()
        CrashLog.write("BOOT", "app start v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
    }

    var body: some Scene {
        WindowGroup { RootTabView() }
    }
}

struct RootTabView: View {
    /// 跨页跳转用（搜索失败 → 「用其他源搜」切到首页分类）
    @AppStorage("selectedTab") private var tab = 0
    /// 必须订阅 Player，否则 showFullScreen 变化不会驱动 fullScreenCover
    @ObservedObject private var player = Player.shared

    // 导航结构（v1.4.0 重排）：
    //   首页  —— 只放推荐流（对标摸鱼听书/喜马拉雅「发现」页）
    //   分类  —— 按书源找书（原「浏览」）
    //   书架  —— 收藏 / 历史 / 最近
    //   我的  —— 设置 + 源管理（收进二级页）
    // 播放不进 Tab：点任意一集弹出全屏播放页（对标喜马拉雅图一），底部只留一条迷你条。
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $tab) {
                HomeView()
                    .tabItem { Label("首页", systemImage: "house.fill") }
                    .tag(0)

                CategoryView()
                    .tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
                    .tag(1)

                ShelfView()
                    .tabItem { Label("书架", systemImage: "heart.fill") }
                    .tag(2)

                MineView()
                    .tabItem { Label("我的", systemImage: "person.fill") }
                    .tag(3)
            }

            // 迷你播放条：只在有播放内容时出现，点开进全屏播放页
            MiniPlayerBar()
        }
        // 绑定 player.* 而不是 Player.shared.*：RootTabView 订阅的是自己的 player，
        // 只有订阅对象的 @Published 变化才会推动这里重算（全屏页的关闭按钮依赖它）
        .fullScreenCover(isPresented: Binding(
            get: { player.showFullScreen },
            set: { player.showFullScreen = $0 }
        )) {
            PlayerView()
        }
        .onAppear { CrashLog.write("UI", "root appear tab=\(tab) fullscreen=\(player.showFullScreen)") }
        .onDisappear { CrashLog.write("UI", "root disappear tab=\(tab) fullscreen=\(player.showFullScreen)") }
    }
}

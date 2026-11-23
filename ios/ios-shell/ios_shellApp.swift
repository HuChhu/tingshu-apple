import SwiftUI

@main
struct TingshuRootApp: App {
    var body: some Scene {
        WindowGroup { RootTabView() }
    }
}

struct RootTabView: View {
    /// 跨页跳转用（书架搜索失败 → 「用其他源搜」切到浏览页）
    @AppStorage("selectedTab") private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ShelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)

            BrowseView()
                .tabItem { Label("浏览", systemImage: "square.grid.2x2") }
                .tag(1)

            PlayerView()
                .tabItem { Label("播放", systemImage: "play.circle") }
                .tag(2)

            SourcesView()
                .tabItem { Label("源管理", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(3)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(4)
        }
    }
}

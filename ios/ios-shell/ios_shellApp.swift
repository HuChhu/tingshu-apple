import SwiftUI

@main
struct TingshuRootApp: App {
    var body: some Scene {
        WindowGroup { RootTabView() }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            ShelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }

            BrowseView()
                .tabItem { Label("浏览", systemImage: "square.grid.2x2") }

            PlayerView()
                .tabItem { Label("播放", systemImage: "play.circle") }

            SourcesView()
                .tabItem { Label("源管理", systemImage: "antenna.radiowaves.left.and.right") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

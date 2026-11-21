import SwiftUI

@main
struct TingshuApp: App {
    var body: some Scene {
        WindowGroup { RootTabView() }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            ShelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
            PlayerView()
                .tabItem { Label("播放", systemImage: "play.circle") }
        }
    }
}

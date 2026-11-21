import SwiftUI

/// 书架页占位（T05）。数据经 SharedBridge 接共享核心 search 动作（周1 spike 已验）；
/// 本周不接真数据。周3 闸口只验最小用例：搜索「三体」→ 第一本 → 第一集。
struct ShelfView: View {
    @State private var rows: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("书架空占位")
                            .font(.headline)
                        Text("等 SharedBridge.search 接通后填充")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List(rows, id: \.self) { Text($0) }
                }
            }
            .navigationTitle("书架")
        }
    }
}

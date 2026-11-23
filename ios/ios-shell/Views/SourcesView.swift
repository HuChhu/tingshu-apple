import SwiftUI

/// 源管理：列出全部 38 个源，可开关、可查看类型
struct SourcesView: View {

    @AppStorage("enabledSources") private var enabledRaw: String = ""

    @State private var all: [SharedBridge.SourceItem] = []
    @State private var filter: SourceFilter = .all

    enum SourceFilter: String, CaseIterable {
        case all = "全部"
        case native = "原生"
        case template = "模板站"
        case login = "需登录"
    }

    /// 默认启用的源（用户没动过设置时）
    private let defaultEnabled: Set<String> = [
        "ximalaya-open", "kuwo", "bilibili", "qingting", "netease",
        "leting8", "jiongzei", "ytysxs", "gushiya", "ihonghai",
        "tianxiatingshu", "picfxapp", "yitingshu", "aj006", "music189",
    ]

    /// 「明确全关」哨兵（P1-8）。
    /// 空串的语义是「用户没设置过 = 默认启用集」，所以不能拿空串当全关，
    /// 否则点完「全关」列表里照样 15 个开关是开的。用 __none__ 把两种状态分开。
    private static let noneSentinel = "__none__"

    private var enabled: Set<String> {
        if enabledRaw == Self.noneSentinel { return [] }
        if enabledRaw.isEmpty { return defaultEnabled }
        return Set(enabledRaw.split(separator: ",").map(String.init))
    }

    /// 写回：空集合必须落成哨兵，不能落成空串（否则又变回默认启用集）
    private func persist(_ set: Set<String>) {
        enabledRaw = set.isEmpty ? Self.noneSentinel : set.joined(separator: ",")
    }

    private var shown: [SharedBridge.SourceItem] {
        let list = all
        switch filter {
        case .all: return list
        case .native: return list.filter { $0.kind == "native" }
        case .template: return list.filter { $0.kind == "template" }
        case .login: return list.filter { $0.kind == "login" }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("筛选", selection: $filter) {
                        ForEach(SourceFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(shown, id: \.id) { src in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: src.kind))
                                .foregroundStyle(color(for: src.kind))
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(src.name).font(.body)
                                Text(src.desc).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { enabled.contains(src.id) },
                                set: { on in toggle(src.id, on) }
                            ))
                            .labelsHidden()
                        }
                    }
                } header: {
                    Text("已启用 \(enabled.count) / \(all.count)")
                } footer: {
                    Text("源来自第三方站点，稳定性与本 App 无关。关了不影响已收藏的书。")
                }
            }
            .navigationTitle("源管理")
            .onAppear { loadSources() }
            .toolbar {
                Menu("操作") {
                    Button("全开（原生 + 大站）") {
                        persist(defaultEnabled)
                    }
                    Button("全关") {
                        // P1-8：落哨兵，不是空串；列表才会真的全关
                        persist([])
                    }
                    Button("只留原生") {
                        persist(Set(["ximalaya-open", "kuwo", "bilibili", "qingting", "netease"]))
                    }
                    Button("恢复默认") {
                        enabledRaw = ""
                    }
                }
            }
        }
    }

    private func loadSources() {
        all = SharedBridge.allSources()
    }

    private func toggle(_ id: String, _ on: Bool) {
        var cur = enabled
        if on { cur.insert(id) } else { cur.remove(id) }
        persist(cur)
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "native": return "bolt.fill"
        case "template": return "square.grid.2x2"
        case "login": return "person.badge.key"
        default: return "questionmark"
        }
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "native": return .blue
        case "template": return .green
        case "login": return .orange
        default: return .gray
        }
    }
}

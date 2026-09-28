import SwiftUI

/// 全キャラ一覧。「なぜこの役割にこの相性なのか」を自分の目で確認できるようにするための画面。
struct BrawlerListView: View {
    @EnvironmentObject private var store: RulesStore
    @State private var query: String = ""

    var body: some View {
        Group {
            if case .ready(let rules) = store.state {
                content(rules: rules)
            } else {
                ProgressView("読み込み中 …")
            }
        }
        .navigationTitle("キャラ一覧")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "キャラ名で検索")
    }

    @ViewBuilder
    private func content(rules: LoadedRules) -> some View {
        let filtered = rules.document.brawlers.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.nameJa?.contains(query) ?? false)
        }
        let grouped = Dictionary(grouping: filtered) { $0.role }
        let roleOrder = Array(rules.document.archetypes.keys).sorted {
            (grouped[$0]?.count ?? 0) > (grouped[$1]?.count ?? 0)
        }

        List {
            ForEach(roleOrder, id: \.self) { role in
                if let list = grouped[role], !list.isEmpty {
                    Section(rules.japaneseRole(role)) {
                        ForEach(list.sorted { $0.name < $1.name }, id: \.id) { b in
                            NavigationLink {
                                BrawlerDetailView(brawler: b, rules: rules, mapContext: nil)
                            } label: {
                                row(for: b)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(for b: BrawlerRole) -> some View {
        HStack(spacing: 12) {
            BrawlerIcon(id: b.id, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.nameJa ?? b.name)
                if let ja = b.nameJa, ja != b.name {
                    Text(b.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !b.gadgets.isEmpty || !b.starPowers.isEmpty {
                Text("SP\(b.starPowers.count) / GD\(b.gadgets.count)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

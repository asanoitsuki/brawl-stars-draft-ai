import SwiftUI

/// 全マップの一覧。「このAIの判断根拠は本物か」を自分の目で確認できるようにするための画面。
/// マップごとの画像・スコア・出典を MapDetailView で見られる。
struct MapListView: View {
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
        .navigationTitle("マップ一覧（\(mapCountLabel)）")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "マップ名で検索")
    }

    private var mapCountLabel: String {
        if case .ready(let rules) = store.state { return "\(rules.document.maps.count)" }
        return "…"
    }

    @ViewBuilder
    private func content(rules: LoadedRules) -> some View {
        let filtered = rules.document.maps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.nameJa?.contains(query) ?? false)
        }
        let grouped = Dictionary(grouping: filtered) { $0.modeJa }
        let modeOrder = grouped.keys.sorted {
            (grouped[$0]?.count ?? 0) > (grouped[$1]?.count ?? 0)
        }

        List {
            ForEach(modeOrder, id: \.self) { modeJa in
                if let maps = grouped[modeJa], !maps.isEmpty {
                    Section(modeJa) {
                        ForEach(maps.sorted { $0.name < $1.name }, id: \.id) { map in
                            NavigationLink {
                                MapDetailView(map: map, rules: rules)
                            } label: {
                                row(for: map)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(for map: MapRules) -> some View {
        HStack(spacing: 12) {
            MapThumbnail(id: map.id)
                .frame(width: 46, height: 70)
            VStack(alignment: .leading, spacing: 2) {
                Text(map.nameJa ?? map.name)
                if let ja = map.nameJa, ja != map.name {
                    Text(map.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if map.inRotation {
                Text("ローテ中").font(.caption2).foregroundStyle(.green)
            }
        }
    }
}

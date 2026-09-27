import SwiftUI

/// 「持っているキャラ」を管理する画面。
///
/// オフにしたキャラは推薦（BAN推奨・初手・ラストピックなど）の候補から外れる。
/// 画面に映っているのを認識すること自体は引き続き行う（相手やチームメイトが
/// 使っていても正しく認識できないと困るため）— 外れるのは「自分に薦める」対象からだけ。
struct BrawlerRosterView: View {
    @EnvironmentObject private var store: RulesStore
    @State private var query: String = ""
    @State private var excluded: Set<Int> = AppSettings.excludedBrawlerIDs

    var body: some View {
        Group {
            if case .ready(let rules) = store.state {
                content(rules: rules)
            } else {
                ProgressView("読み込み中 …")
            }
        }
        .navigationTitle("持っているキャラ")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "キャラ名で検索")
    }

    private func content(rules: LoadedRules) -> some View {
        let filtered = rules.document.brawlers.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.nameJa?.contains(query) ?? false)
        }
        let grouped = Dictionary(grouping: filtered) { $0.role }
        let roleOrder = Array(rules.document.archetypes.keys).sorted {
            (grouped[$0]?.count ?? 0) > (grouped[$1]?.count ?? 0)
        }

        return List {
            Section {
                HStack {
                    Text("所持: \(rules.document.brawlers.count - excluded.count) / \(rules.document.brawlers.count)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全員ON") { setAll(rules: rules, owned: true) }
                        .font(.footnote)
                    Button("全員OFF") { setAll(rules: rules, owned: false) }
                        .font(.footnote)
                }
            }
            ForEach(roleOrder, id: \.self) { role in
                guard let list = grouped[role], !list.isEmpty else { return AnyView(EmptyView()) }
                return AnyView(
                    Section(rules.japaneseRole(role)) {
                        ForEach(list.sorted { $0.name < $1.name }, id: \.id) { b in
                            row(for: b)
                        }
                    }
                )
            }
        }
    }

    private func row(for b: BrawlerRole) -> some View {
        Toggle(isOn: Binding(
            get: { !excluded.contains(b.id) },
            set: { owned in
                AppSettings.setOwned(b.id, owned: owned)
                if owned { excluded.remove(b.id) } else { excluded.insert(b.id) }
            }
        )) {
            HStack {
                Text(b.nameJa ?? b.name)
                if let ja = b.nameJa, ja != b.name {
                    Text(b.name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setAll(rules: LoadedRules, owned: Bool) {
        for b in rules.document.brawlers {
            AppSettings.setOwned(b.id, owned: owned)
        }
        excluded = AppSettings.excludedBrawlerIDs
    }
}

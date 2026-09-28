import SwiftUI

/// 1 マップぶんの詳細。「このAIの推薦は当てずっぽうじゃない」と自分で確認できるように、
/// 実際に使っているスコア（candidates）とその根拠テキストをそのまま出す。
struct MapDetailView: View {
    let map: MapRules
    let rules: LoadedRules

    private var brawlerByID: [Int: BrawlerRole] {
        Dictionary(uniqueKeysWithValues: rules.document.brawlers.map { ($0.id, $0) })
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    MapThumbnail(id: map.id, cornerRadius: 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                    VStack(spacing: 2) {
                        Text(map.nameJa ?? map.name).font(.title3.bold())
                        if let ja = map.nameJa, ja != map.name {
                            Text(map.name).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Label(map.modeJa, systemImage: "gamecontroller")
                        if map.inRotation {
                            Label("ローテ中", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if map.hasLiveStats {
                            Label("実測勝率あり", systemImage: "chart.bar.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 16)
            }

            Section {
                Text("ブラインドピック（below Elite）でこのマップが認識されたとき、"
                     + "実際にこの数値でキャラを並び替えて提案しています。base はマップ適性、"
                     + "winRate はこのマップでの実測勝率（あれば）です。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("キャラをタップすると、スコアの内訳・相性データ・スターパワー/ガジェットが見られます。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("候補スコア（\(map.candidates.count) 体）") {
                ForEach(map.candidates.sorted { $0.base > $1.base }, id: \.id) { c in
                    if let full = brawlerByID[c.id] {
                        NavigationLink {
                            BrawlerDetailView(
                                brawler: full, rules: rules,
                                mapContext: (mapName: map.nameJa ?? map.name,
                                             reason: c.reason ?? "根拠テキストがありません")
                            )
                        } label: {
                            candidateRow(c)
                        }
                    } else {
                        candidateRow(c)
                    }
                }
            }

            if !map.bans.isEmpty || !map.picks.first.isEmpty {
                Section {
                    DisclosureGroup("エリート帯データ（BAN・初手 / 準備中プレビュー）") {
                        if !map.bans.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("BAN推奨").font(.caption.bold())
                                ForEach(map.bans.prefix(6), id: \.id) { s in
                                    suggestionRow(s)
                                }
                            }
                        }
                        if !map.picks.first.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("初手推奨").font(.caption.bold()).padding(.top, 4)
                                ForEach(map.picks.first.prefix(6), id: \.id) { s in
                                    suggestionRow(s)
                                }
                            }
                        }
                        Text("この画面自体はエリート帯の画面認識より先に用意した「スコアはすでに"
                             + "計算済み」というプレビューです。エリート帯の画面認識自体はまだ未実装です。")
                            .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
            }

            Section("出典・データについて") {
                if let urlString = map.imageUrl, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label("画像の出典（Brawlify）", systemImage: "link")
                    }
                    .font(.footnote)
                }
                LabeledContent("ルールデータ生成日時", value: rules.generatedAt)
                switch rules.document.dataQuality.confidence {
                case .measured:
                    Text("このデータセットは実測勝率ベースです。").font(.caption2).foregroundStyle(.green)
                case .manualTier:
                    Text(rules.document.dataQuality.note)
                        .font(.caption2).foregroundStyle(.secondary)
                case .roleOnly:
                    Text(rules.document.dataQuality.note)
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(map.nameJa ?? map.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func candidateRow(_ c: MapRules.Candidate) -> some View {
        HStack(spacing: 12) {
            BrawlerIcon(id: c.id, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(brawlerByID[c.id]?.nameJa ?? c.name)
                Text(rules.japaneseRole(c.role)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(c.base >= 0 ? "+" : "")\(String(format: "%.1f", c.base))")
                    .font(.footnote.monospacedDigit())
                if let wr = c.winRate {
                    Text("勝率 \(String(format: "%.1f", wr))%")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func suggestionRow(_ s: PickSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(brawlerByID[s.id]?.nameJa ?? s.name).font(.footnote)
                Spacer()
                Text(String(format: "%.2f", s.score)).font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let reason = s.reason, !reason.isEmpty {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

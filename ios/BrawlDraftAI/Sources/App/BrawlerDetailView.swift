import SwiftUI

/// 1 キャラぶんの詳細。役割・相性（シナジー/カウンター）の根拠、スターパワー・ガジェットを
/// まとめて見られるようにして、「このAIは適当に言ってるんじゃないか」を検証できるようにする。
struct BrawlerDetailView: View {
    let brawler: BrawlerRole
    let rules: LoadedRules
    /// マップ詳細のキャラ候補から開いた場合、その根拠文をここに出す。
    let mapContext: (mapName: String, reason: String)?

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    BrawlerIcon(id: brawler.id, size: 88)
                    VStack(spacing: 2) {
                        Text(brawler.nameJa ?? brawler.name).font(.title3.bold())
                        if let ja = brawler.nameJa, ja != brawler.name {
                            Text(brawler.name).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Text(brawler.roleJa).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 16)
            }

            if let mapContext {
                Section("\(mapContext.mapName) での評価根拠") {
                    Text(mapContext.reason).font(.footnote)
                }
            }

            if let tip = rules.roleTip(brawler.role) {
                Section("立ち回り（\(brawler.roleJa)共通）") {
                    Text(tip).font(.footnote)
                }
            }

            Section {
                Text("以下は役割（\(brawler.roleJa)）単位の相性データです。同じ役割のキャラは"
                     + "全員この数値を共有します（キャラ個別の相性データではありません）。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let synergyRow = rules.document.synergy[brawler.role] {
                Section("味方シナジーが良い役割") {
                    ForEach(topRoles(synergyRow, positive: true), id: \.role) { entry in
                        matchupRow(entry)
                    }
                }
            }

            if let advRow = rules.document.advantage[brawler.role] {
                Section("得意な相手役割（アドバンテージ）") {
                    ForEach(topRoles(advRow, positive: true), id: \.role) { entry in
                        matchupRow(entry)
                    }
                }
                Section("苦手な相手役割（カウンターされやすい）") {
                    ForEach(topRoles(advRow, positive: false), id: \.role) { entry in
                        matchupRow(entry)
                    }
                }
            }

            if !brawler.starPowers.isEmpty {
                Section("スターパワー") {
                    ForEach(brawler.starPowers) { sp in
                        loadoutRow(sp)
                    }
                }
            }

            if !brawler.gadgets.isEmpty {
                Section("ガジェット") {
                    ForEach(brawler.gadgets) { gd in
                        loadoutRow(gd)
                    }
                }
            }

            if brawler.starPowers.isEmpty && brawler.gadgets.isEmpty {
                Section {
                    Text("スターパワー・ガジェットのデータを取得できませんでした。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("名前・説明は Brawlify のデータそのまま（英語）です。画像は現在の"
                         + "ネットワーク環境で取得できなかったものがあります。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if brawler.starPowers.contains(where: { $0.measuredWinRate != nil })
                        || brawler.gadgets.contains(where: { $0.measuredWinRate != nil }) {
                        Text("緑の「実測」表示は brawltime.ninja の実測勝率（564万戦の統計、"
                             + "全キャラ網羅ではなく上位のみ）。")
                            .font(.caption2).foregroundStyle(.green)
                    }
                    if brawler.starPowers.contains(where: { $0.communityNote != nil })
                        || brawler.gadgets.contains(where: { $0.communityNote != nil }) {
                        Text("青い「攻略サイトの評価」は timesaver.gg の意見であり、実測データ"
                             + "ではありません。")
                            .font(.caption2).foregroundStyle(.blue)
                    }
                }
            }
        }
        .navigationTitle(brawler.nameJa ?? brawler.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct MatchupEntry { let role: String; let value: Double }

    private func topRoles(_ row: [String: Double], positive: Bool, limit: Int = 3) -> [MatchupEntry] {
        var entries: [MatchupEntry] = []
        for (role, value) in row {
            let keep = positive ? value > 0 : value < 0
            if keep { entries.append(MatchupEntry(role: role, value: value)) }
        }
        if positive {
            entries.sort { $0.value > $1.value }
        } else {
            entries.sort { $0.value < $1.value }
        }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        return entries
    }

    private func matchupRow(_ entry: MatchupEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rules.japaneseRole(entry.role))
                if let examples = metaExamples(for: entry.role) {
                    Text(examples).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(String(format: "%+.2f", entry.value))
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    /// この役割の中で手動ティアが高いキャラを2〜3体、代表例として出す。
    /// 「アサシンが苦手」だけでは対策しづらいので、具体的なキャラ名を添える。
    /// あくまで data/tier_overrides.json の手入力値であり、実測の人気順ではない。
    private func metaExamples(for role: String) -> String? {
        let candidates = rules.document.brawlers
            .filter { $0.role == role && $0.tier > 0 }
            .sorted { $0.tier > $1.tier }
            .prefix(3)
            .map { $0.nameJa ?? $0.name }
        guard !candidates.isEmpty else { return nil }
        return "例: " + candidates.joined(separator: "、")
    }

    private func loadoutRow(_ item: BrawlerRole.Loadout) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LoadoutIcon(filename: item.image)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.subheadline)
                    if let wr = item.measuredWinRate {
                        Text("実測 \(String(format: "%.1f", wr))%")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
                Text(item.description).font(.caption).foregroundStyle(.secondary)
                if let note = item.communityNote {
                    Text("攻略サイトの評価: \(note)")
                        .font(.caption2).foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

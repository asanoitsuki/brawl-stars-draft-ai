import SwiftUI

/// スターパワー / ガジェットをタップしたときの画面。
/// 「どのステージ・どの相手で使うと良いか」を、手元にある根拠ごとに分けて出す。
///
/// * 効果の説明（英語）から読み取れる性質 → 向いているモード（推定）
/// * このキャラのガチバトル実測: 勝率の高いステージ / 低いステージ
/// * このキャラの実測の対面: 得意な相手 / 苦手な相手
///
/// 公式 API の対戦履歴には「どのガジェット・スターパワーを付けていたか」が含まれないため、
/// 装備ごとのステージ別勝率は出せない（キャラ単位の実測＋効果からの推定になる）。
struct LoadoutDetailView: View {
    let brawler: BrawlerRole
    let item: BrawlerRole.Loadout
    let isGadget: Bool
    let rules: LoadedRules

    private struct MapStat: Identifiable {
        let map: MapRules
        let winRate: Double
        let games: Int
        var id: Int { map.id }
    }

    private struct Opponent: Identifiable {
        let brawler: BrawlerRole
        let stat: LoadedRules.PairStat
        var id: Int { brawler.id }
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    LoadoutIcon(filename: item.image, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.headline)
                        Text("\(brawler.nameJa ?? brawler.name) の\(isGadget ? "ガジェット" : "スターパワー")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let wr = item.measuredWinRate {
                            Text("装備時の実測勝率 \(String(format: "%.1f", wr))%")
                                .font(.caption.bold()).foregroundStyle(.green)
                        }
                    }
                }
                Text(item.description).font(.footnote)
                if let note = item.communityNote {
                    Text("攻略サイトの評価: \(note)").font(.caption).foregroundStyle(.blue)
                }
            }

            let traits = Self.traits(of: item.description)
            if !traits.isEmpty {
                Section {
                    ForEach(traits, id: \.title) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(t.title, systemImage: t.icon).font(.subheadline.weight(.semibold))
                            Text(t.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("この装備が活きる場面（効果の説明からの推定）")
                }
            }

            let modes = bestModes()
            if !modes.isEmpty {
                Section {
                    ForEach(modes, id: \.mode) { m in
                        HStack {
                            Text(m.modeJa)
                            Spacer()
                            WinRateBadge(winRate: m.winRate, games: m.games)
                        }
                    }
                } header: {
                    Text("このキャラが強いモード（ガチバトル実測）")
                }
            }

            let maps = mapStats()
            if !maps.isEmpty {
                Section {
                    ForEach(maps.prefix(6)) { m in mapRow(m) }
                } header: {
                    Text("おすすめステージ（このキャラの勝率が高い順）")
                }
                if maps.count > 6 {
                    Section {
                        ForEach(maps.suffix(3).reversed()) { m in mapRow(m) }
                    } header: {
                        Text("避けたいステージ（勝率が低い）")
                    }
                }
            }

            let (good, bad) = opponents()
            if !good.isEmpty {
                Section {
                    ForEach(good) { opponentRow($0) }
                } header: {
                    Text("得意な相手（実測の対面）")
                }
            }
            if !bad.isEmpty {
                Section {
                    ForEach(bad) { opponentRow($0) }
                } header: {
                    Text("苦手な相手（実測の対面）")
                }
            }

            Section {
                Text("公式の対戦データには「どのガジェット・スターパワーを付けていたか」が入っていないため、"
                     + "ステージ・相手の数値はこのキャラ全体の実測です。装備ごとの向き不向きは効果の説明から推定しています。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 行

    private func mapRow(_ m: MapStat) -> some View {
        NavigationLink {
            MapDetailView(map: m.map, rules: rules)
        } label: {
            HStack(spacing: 12) {
                MapThumbnail(id: m.map.id).frame(width: 34, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.map.nameJa ?? m.map.name)
                    Text(m.map.modeJa).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                WinRateBadge(winRate: m.winRate, games: m.games)
            }
        }
    }

    private func opponentRow(_ o: Opponent) -> some View {
        HStack(spacing: 12) {
            BrawlerIcon(id: o.brawler.id, size: 34)
            Text(o.brawler.nameJa ?? o.brawler.name)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("対面 \(String(format: "%.0f", o.stat.winRate))%")
                    .font(.footnote.monospacedDigit().weight(.bold))
                    .foregroundStyle(o.stat.delta >= 0 ? .green : .orange)
                Text("\(o.stat.games)戦").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - データ

    /// このキャラが候補に入っているマップの実測勝率（試合数 30 以上）
    private func mapStats() -> [MapStat] {
        rules.document.maps.compactMap { map in
            guard map.statsScope == "map",
                  let c = map.candidates.first(where: { $0.id == brawler.id }),
                  let wr = c.winRate, let games = c.games, games >= 30 else { return nil }
            return MapStat(map: map, winRate: wr, games: games)
        }
        .sorted { $0.winRate > $1.winRate }
    }

    private func bestModes() -> [(mode: String, modeJa: String, winRate: Double, games: Int)] {
        var acc: [String: (ja: String, wins: Double, games: Int)] = [:]
        for s in mapStats() {
            var e = acc[s.map.mode] ?? (s.map.modeJa, 0, 0)
            e.wins += s.winRate / 100 * Double(s.games)
            e.games += s.games
            acc[s.map.mode] = e
        }
        return acc.map { (mode: $0.key, modeJa: $0.value.ja, winRate: 100 * $0.value.wins / Double($0.value.games), games: $0.value.games) }
            .sorted { $0.winRate > $1.winRate }
    }

    private func opponents() -> ([Opponent], [Opponent]) {
        var all: [Opponent] = []
        for b in rules.document.brawlers where b.id != brawler.id {
            if let s = rules.matchup(brawler.id, vs: b.id), s.games >= 15 {
                all.append(Opponent(brawler: b, stat: s))
            }
        }
        let good = all.filter { $0.stat.delta > 0 }.sorted { $0.stat.delta > $1.stat.delta }.prefix(5)
        let bad = all.filter { $0.stat.delta < 0 }.sorted { $0.stat.delta < $1.stat.delta }.prefix(5)
        return (Array(good), Array(bad))
    }

    // MARK: - 効果の説明から性質を読む

    struct Trait {
        let title: String
        let detail: String
        let icon: String
    }

    static func traits(of description: String) -> [Trait] {
        let d = description.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { d.contains($0) } }
        var out: [Trait] = []
        if has(["heal", "regenerat", "recover", "health"]) {
            out.append(Trait(title: "回復・粘り", detail: "長く場に残れる。ホットゾーン・エメラルドハントのように前に居座るモードで活きる", icon: "cross.case.fill"))
        }
        if has(["shield", "damage reduction", "reduces damage", "invulnerab", "immune"]) {
            out.append(Trait(title: "被ダメージ軽減", detail: "撃ち合いで競り勝ちやすい。前線を張るホットゾーン・ブロストライカー向き", icon: "shield.fill"))
        }
        if has(["speed", "dash", "jump", "leap", "teleport", "faster", "moves"]) {
            out.append(Trait(title: "機動力", detail: "詰める・逃げるが速い。ブロストライカー・ブロールホッケー、逃げ切りの賞金稼ぎで強い", icon: "hare.fill"))
        }
        if has(["slow", "stun", "knock", "pull", "freez", "root", "silence", "confus", "push"]) {
            out.append(Trait(title: "妨害（スロー・スタン・ノックバック）", detail: "相手の動きを止めて味方の攻撃を当てやすくする。ノックアウト・賞金稼ぎ・ホットゾーン向き", icon: "tortoise.fill"))
        }
        if has(["wall", "destroy", "obstacle", "cover"]) {
            out.append(Trait(title: "壁・障害物に関わる", detail: "壁が多いマップで真価を発揮する。壁を壊せればブロストライカーで道を開ける", icon: "square.stack.3d.up.fill"))
        }
        if has(["range", "distance", "longer", "reload", "ammo", "projectile"]) {
            out.append(Trait(title: "射程・手数", detail: "撃てる回数や距離が伸びる。開けたマップの賞金稼ぎ・ノックアウトで有利", icon: "scope"))
        }
        if has(["spawn", "turret", "summon", "pet", "minion", "clone", "drop"]) {
            out.append(Trait(title: "設置・召喚", detail: "置いたものでエリアを守れる。ホットゾーン・強奪・エメラルドハント向き", icon: "cube.fill"))
        }
        if has(["safe", "heist", "structure"]) {
            out.append(Trait(title: "金庫・建物への攻撃", detail: "強奪で金庫を削る速さに直結する", icon: "lock.shield.fill"))
        }
        if has(["invisib", "bush", "hidden", "stealth"]) {
            out.append(Trait(title: "草むら・奇襲", detail: "草むらの多いマップで不意打ちしやすい", icon: "leaf.fill"))
        }
        if has(["super", "charge"]) && out.isEmpty {
            out.append(Trait(title: "スーパーの回転", detail: "スーパーを多く撃てる。どのモードでも腐りにくい", icon: "bolt.fill"))
        }
        return out
    }
}

import Foundation

/// 1 体ぶんの提案。
struct PickAdvice: Identifiable {
    let id: Int
    let name: String
    /// 読み上げ用カタカナ（無ければ nil = 英語名を英語音声で読む）
    let nameJa: String?
    let role: String
    let roleJa: String
    let score: Double
    let reason: String
    let winRate: Double?
}

/// 通知・読み上げに渡す最終結果。
struct Recommendation {
    let phase: DraftPhase
    let map: MapRules?
    /// 通知のタイトル（1 行）
    let title: String
    /// 通知の本文
    let body: String
    /// 読み上げるテキスト（カタカナ / 英語の混在を許すためセグメントで持つ）
    let speech: [SpeechSegment]
    let advices: [PickAdvice]
    /// データ品質や認識信頼度についての注意書き
    let caution: String?

    struct SpeechSegment {
        let text: String
        let isJapanese: Bool
    }
}

/// スナップショットとルールから「次に取るべきキャラ」を出す。
///
/// * 事前計算済みリスト（rules.json の picks.*）→ 相手構成が読めていないときの土台
/// * ライブ計算（候補 × 相性行列 × 実際の構成）→ 2 手目以降の本命
enum Recommender {
    /// フェーズごとの重み。ラストピックはカウンターをほぼ最優先にする。
    private static func weights(for phase: DraftPhase) -> (synergy: Double, advantage: Double) {
        switch phase {
        case .blind: return (0.30, 0.0)  // makeBlind() が別ロジックを持つため実質未使用
        case .ban, .first: return (0.15, 0.10)
        case .middle: return (0.45, 0.35)
        case .last, .complete: return (0.20, 1.60)
        }
    }

    static func make(from snapshot: DraftSnapshot, rules: LoadedRules) -> Recommendation {
        if snapshot.kind == .blindPick {
            return makeBlind(from: snapshot, rules: rules)
        }
        guard let map = snapshot.map else {
            return Recommendation(
                phase: snapshot.phase, map: nil,
                title: "マップを判別できませんでした",
                body: """
                ドラフト画面のスクリーンショットか確認してください。
                合っているのに外す場合は、アプリの「枠合わせ」でマップ画像の位置を調整してください。
                """,
                speech: [.init(text: "マップを判別できませんでした", isJapanese: true)],
                advices: [],
                caution: nil
            )
        }

        let taken = snapshot.takenIDs
        let advices: [PickAdvice]
        let headline: String

        switch snapshot.phase {
        case .blind:
            advices = []
            headline = "N/A"  // blindPick は上で makeBlind() に分岐済みのためここには来ない

        case .ban:
            advices = fromPrecomputed(map.bans, rules: rules, taken: taken, limit: 3)
            headline = "BAN推奨"

        case .first:
            advices = fromPrecomputed(map.picks.first, rules: rules, taken: taken, limit: 3)
            headline = "初手（対策されにくい最強）"

        case .middle, .last:
            let live = liveScored(map: map, snapshot: snapshot, rules: rules)
            advices = live.isEmpty
                ? fromPrecomputed(fallbackList(map: map, snapshot: snapshot),
                                  rules: rules, taken: taken, limit: 3)
                : live
            headline = snapshot.phase == .last
                ? "ラストピック（\(enemyThreatLabel(snapshot, rules: rules))対策）"
                : "\(snapshot.phase.shortLabel)（噛み合い＋刺さり）"

        case .complete:
            advices = []
            headline = "ドラフト完了"
        }

        let title = advices.isEmpty
            ? "\(map.name)｜\(headline)"
            : "\(headline)：\(displayName(advices[0], rules: rules))"

        return Recommendation(
            phase: snapshot.phase,
            map: map,
            title: title,
            body: bodyText(map: map, snapshot: snapshot, advices: advices, rules: rules),
            speech: speechSegments(phase: snapshot.phase, advices: advices),
            advices: advices,
            caution: caution(map: map, snapshot: snapshot, rules: rules)
        )
    }

    // MARK: - ブラインドピック（エリート未満）
    //
    // このフェーズでは相手が最後まで見えないので、カウンター（advantage）は使えない。
    // 使えるのは「モード適性」と「すでに決まっている味方との噛み合い（synergy）」、
    // それに「同じ役割ばかりに偏らない」という役割分散だけ。

    private static func makeBlind(from snapshot: DraftSnapshot, rules: LoadedRules) -> Recommendation {
        guard case .blind(let filled, let total) = snapshot.phase else {
            // 呼び出し経路上ここには来ないが、型を満たすための保険。
            return Recommendation(phase: snapshot.phase, map: nil, title: "解析エラー",
                                  body: "内部エラーです。", speech: [], advices: [], caution: nil)
        }

        let modeWeights = snapshot.mode.flatMap { rules.document.modes[$0]?.weights }
        let modeLabel = snapshot.modeJa ?? snapshot.mode

        guard filled < total else {
            let title = "自チーム選択完了"
            return Recommendation(
                phase: snapshot.phase, map: nil, title: title,
                body: "\(modeLabel.map { "モード: \($0)｜" } ?? "")自チーム 3 人が決まりました。"
                    + "味方: " + snapshot.allies.map { "\($0.name)(\($0.roleJa))" }.joined(separator: " "),
                speech: [.init(text: "自チーム選択完了。", isJapanese: true)],
                advices: [], caution: nil
            )
        }

        let taken = snapshot.takenIDs
        let allyRoles = snapshot.allies.map(\.role)

        var scored: [(brawler: BrawlerRole, score: Double, synergy: Double, modeFit: Double)] = []
        for b in rules.document.brawlers where !taken.contains(b.id) {
            let syn = allyRoles.reduce(0.0) { $0 + rules.synergy(b.role, with: $1) }
            let modeFit = modeWeights?[b.role] ?? 0
            // 味方シナジー 0.5 / モード適性 0.5 で合成。相手情報が無いのでカウンター項は無い。
            let score = 0.5 * modeFit + 0.5 * syn
            scored.append((b, score, syn, modeFit))
        }
        scored.sort { ($0.score, $0.brawler.name) > ($1.score, $1.brawler.name) }

        // 役割の偏りを避ける（既出ロールに 0.35 の減点）
        var picked: [(brawler: BrawlerRole, score: Double, synergy: Double, modeFit: Double)] = []
        var roleCount: [String: Int] = allyRoles.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        var remaining = scored
        while !remaining.isEmpty && picked.count < 3 {
            let bestIndex = remaining.indices.max {
                let a = remaining[$0].score - 0.35 * Double(roleCount[remaining[$0].brawler.role] ?? 0)
                let b = remaining[$1].score - 0.35 * Double(roleCount[remaining[$1].brawler.role] ?? 0)
                return a < b
            }!
            let item = remaining.remove(at: bestIndex)
            roleCount[item.brawler.role, default: 0] += 1
            picked.append(item)
        }

        let advices = picked.map { item -> PickAdvice in
            var parts: [String] = []
            if item.modeFit != 0, let modeLabel {
                parts.append("\(modeLabel)適性 \(item.modeFit >= 0 ? "+" : "")\(String(format: "%.1f", item.modeFit))")
            }
            if item.synergy >= 0.8, let ally = snapshot.allies.max(by: {
                rules.synergy(item.brawler.role, with: $0.role) < rules.synergy(item.brawler.role, with: $1.role)
            }) {
                parts.append("味方の\(ally.roleJa)と噛み合う")
            }
            if parts.isEmpty {
                parts.append("\(rules.japaneseRole(item.brawler.role))として無難な選択")
            }
            return PickAdvice(
                id: item.brawler.id, name: item.brawler.name, nameJa: item.brawler.nameJa,
                role: item.brawler.role, roleJa: rules.japaneseRole(item.brawler.role),
                score: item.score, reason: parts.joined(separator: " / "), winRate: nil
            )
        }

        let title = advices.isEmpty
            ? "候補が見つかりません"
            : "おすすめ：\(displayName(advices[0], rules: rules))"

        var bodyLines: [String] = []
        if let modeLabel { bodyLines.append("モード: \(modeLabel)") }
        for (i, a) in advices.enumerated() {
            let mark = ["◎", "○", "△"][min(i, 2)]
            bodyLines.append("\(mark) \(displayName(a, rules: rules))（\(a.roleJa)）\(a.reason.isEmpty ? "" : " — \(a.reason)")")
        }
        if !snapshot.allies.isEmpty {
            bodyLines.append("味方: " + snapshot.allies.map { "\($0.name)(\($0.roleJa))" }.joined(separator: " "))
        }

        var speech: [Recommendation.SpeechSegment] = [.init(text: "おすすめ、", isJapanese: true)]
        let limit = min(AppSettings.maxAnnouncedPicks, advices.count)
        for (i, a) in advices.prefix(limit).enumerated() {
            if i == 1 { speech.append(.init(text: "次点、", isJapanese: true)) }
            if let ja = a.nameJa {
                speech.append(.init(text: ja + "。", isJapanese: true))
            } else {
                speech.append(.init(text: a.name, isJapanese: false))
                speech.append(.init(text: "。", isJapanese: true))
            }
        }
        if advices.isEmpty {
            speech = [.init(text: "候補が見つかりません", isJapanese: true)]
        }

        var cautions: [String] = ["相手は非公開のため、味方構成とモード適性のみで判断しています"]
        if snapshot.mode == nil {
            cautions.append("モード名を読み取れませんでした（モード適性なしで評価）")
        }
        let shaky = snapshot.allies.filter { !$0.isConfident }
        if !shaky.isEmpty {
            cautions.append("認識が曖昧: \(shaky.map(\.name).joined(separator: ", "))")
        }

        return Recommendation(
            phase: snapshot.phase, map: nil, title: title,
            body: bodyLines.joined(separator: "\n"),
            speech: speech, advices: advices,
            caution: cautions.joined(separator: " / ")
        )
    }

    // MARK: - スコアリング

    private static func liveScored(map: MapRules, snapshot: DraftSnapshot,
                                   rules: LoadedRules) -> [PickAdvice] {
        let taken = snapshot.takenIDs
        let w = weights(for: snapshot.phase)
        let allyRoles = snapshot.allies.map(\.role)
        let enemyRoles = snapshot.enemies.map(\.role)

        var scored: [(candidate: MapRules.Candidate, score: Double,
                      synergy: Double, advantage: Double)] = []
        for c in map.candidates where !taken.contains(c.id) {
            let syn = allyRoles.reduce(0.0) { $0 + rules.synergy(c.role, with: $1) }
            let adv = enemyRoles.reduce(0.0) { $0 + rules.advantage(c.role, vs: $1) }
            scored.append((c, c.base + w.synergy * syn + w.advantage * adv, syn, adv))
        }
        scored.sort { ($0.score, $0.candidate.name) > ($1.score, $1.candidate.name) }

        // 同じ役割ばかり 3 つ並べても選択肢にならないので、既出ロールには減点する
        var picked: [(candidate: MapRules.Candidate, score: Double,
                      synergy: Double, advantage: Double)] = []
        var roleCount: [String: Int] = [:]
        var remaining = scored
        while !remaining.isEmpty && picked.count < 3 {
            let bestIndex = remaining.indices.max {
                let a = remaining[$0].score - 0.25 * Double(roleCount[remaining[$0].candidate.role] ?? 0)
                let b = remaining[$1].score - 0.25 * Double(roleCount[remaining[$1].candidate.role] ?? 0)
                return a < b
            }!
            let item = remaining.remove(at: bestIndex)
            roleCount[item.candidate.role, default: 0] += 1
            picked.append(item)
        }

        return picked.map { item in
            PickAdvice(
                id: item.candidate.id,
                name: item.candidate.name,
                nameJa: rules.document.brawlers.first { $0.id == item.candidate.id }?.nameJa,
                role: item.candidate.role,
                roleJa: rules.japaneseRole(item.candidate.role),
                score: item.score,
                reason: reasonText(role: item.candidate.role, snapshot: snapshot,
                                   rules: rules, synergy: item.synergy, advantage: item.advantage,
                                   winRate: item.candidate.winRate),
                winRate: item.candidate.winRate
            )
        }
    }

    private static func fromPrecomputed(_ list: [PickSuggestion], rules: LoadedRules,
                                        taken: Set<Int>, limit: Int) -> [PickAdvice] {
        list.filter { !taken.contains($0.id) }.prefix(limit).map { s in
            PickAdvice(
                id: s.id, name: s.name,
                nameJa: rules.document.brawlers.first { $0.id == s.id }?.nameJa,
                role: s.role,
                roleJa: s.roleJa ?? rules.japaneseRole(s.role),
                score: s.score,
                reason: s.reason ?? "",
                winRate: s.winRate
            )
        }
    }

    /// ライブ計算が空になったとき（候補が全部取られている等）の保険。
    private static func fallbackList(map: MapRules, snapshot: DraftSnapshot) -> [PickSuggestion] {
        if snapshot.phase == .last, let dominant = dominantEnemyRole(snapshot),
           let list = map.picks.last.byEnemyRole[dominant] {
            return list
        }
        if let dominant = dominantEnemyRole(snapshot),
           let list = map.picks.middle.byEnemyRole[dominant] {
            return list
        }
        return map.picks.middle.general
    }

    private static func dominantEnemyRole(_ snapshot: DraftSnapshot) -> String? {
        let counts = snapshot.enemies.reduce(into: [String: Int]()) { $0[$1.role, default: 0] += 1 }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    private static func enemyThreatLabel(_ snapshot: DraftSnapshot, rules: LoadedRules) -> String {
        guard let role = dominantEnemyRole(snapshot) else { return "相手構成" }
        return rules.japaneseRole(role)
    }

    // MARK: - 文面

    private static func reasonText(role: String, snapshot: DraftSnapshot, rules: LoadedRules,
                                   synergy: Double, advantage: Double, winRate: Double?) -> String {
        var parts: [String] = []

        // 相手の役割ごとに、はっきり有利な相手だけ挙げる
        let enemyCounts = snapshot.enemies.reduce(into: [String: Int]()) { $0[$1.role, default: 0] += 1 }
        let strongAgainst = enemyCounts
            .map { (role: $0.key, count: $0.value, adv: rules.advantage(role, vs: $0.key)) }
            .filter { $0.adv >= 1 }
            .sorted { ($0.adv, $0.role) > ($1.adv, $1.role) }
        if let top = strongAgainst.first {
            let suffix = top.count > 1 ? "×\(top.count)" : ""
            parts.append("相手の\(rules.japaneseRole(top.role))\(suffix)に有利（\(signed(top.adv))）")
        }

        // 味方との噛み合い
        if synergy >= 0.8, let ally = snapshot.allies.max(by: {
            rules.synergy(role, with: $0.role) < rules.synergy(role, with: $1.role)
        }) {
            parts.append("味方の\(ally.roleJa)と噛み合う（+\(String(format: "%.1f", rules.synergy(role, with: ally.role)))）")
        }

        if let winRate {
            parts.append("このマップ勝率 \(String(format: "%.1f", winRate))%")
        }

        if parts.isEmpty {
            parts.append("このマップでの素の評価が高い\(rules.japaneseRole(role))")
        }
        if advantage < 0 {
            parts.append("※相手構成には相性負けの面あり")
        }
        return parts.joined(separator: " / ")
    }

    private static func bodyText(map: MapRules, snapshot: DraftSnapshot,
                                 advices: [PickAdvice], rules: LoadedRules) -> String {
        var lines: [String] = []
        lines.append("\(map.name)｜\(map.modeJa)｜\(snapshot.phase.label)")

        for (i, a) in advices.enumerated() {
            let mark = ["◎", "○", "△"][min(i, 2)]
            lines.append("\(mark) \(displayName(a, rules: rules))（\(a.roleJa)）\(a.reason.isEmpty ? "" : " — \(a.reason)")")
        }

        if !snapshot.enemies.isEmpty {
            lines.append("相手: " + snapshot.enemies.map { "\($0.name)(\($0.roleJa))" }.joined(separator: " "))
        }
        if !snapshot.allies.isEmpty {
            lines.append("味方: " + snapshot.allies.map { "\($0.name)(\($0.roleJa))" }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private static func speechSegments(phase: DraftPhase,
                                       advices: [PickAdvice]) -> [Recommendation.SpeechSegment] {
        guard !advices.isEmpty else {
            return [.init(text: "候補が見つかりません", isJapanese: true)]
        }
        var segments: [Recommendation.SpeechSegment] = []
        let intro: String
        switch phase {
        case .blind: intro = ""  // makeBlind() が専用の speech を組み立てる
        case .ban: intro = "バン推奨、"
        case .first: intro = "初手、"
        case .middle(let n): intro = "\(n)手目、"
        case .last: intro = "ラスト、"
        case .complete: intro = "完了、"
        }
        segments.append(.init(text: intro, isJapanese: true))

        let limit = min(AppSettings.maxAnnouncedPicks, advices.count)
        for (i, a) in advices.prefix(limit).enumerated() {
            if i == 1 { segments.append(.init(text: "次点、", isJapanese: true)) }
            if let ja = a.nameJa {
                segments.append(.init(text: ja + "。", isJapanese: true))
            } else {
                segments.append(.init(text: a.name, isJapanese: false))
                segments.append(.init(text: "。", isJapanese: true))
            }
        }
        return segments
    }

    private static func displayName(_ advice: PickAdvice, rules: LoadedRules) -> String {
        guard let ja = advice.nameJa, ja != advice.name else { return advice.name }
        return "\(advice.name)（\(ja)）"
    }

    private static func caution(map: MapRules, snapshot: DraftSnapshot,
                                rules: LoadedRules) -> String? {
        var notes: [String] = []
        if !map.hasLiveStats {
            switch rules.document.dataQuality.confidence {
            case .manualTier:
                notes.append("実測勝率は未取得。手動ティア補正で順位付け")
            case .roleOnly:
                notes.append("実測勝率も手動ティアも無し。役割適性のみの評価（同点多数）")
            case .measured:
                break
            }
        }
        if snapshot.mapScore < 0.75 {
            notes.append("マップ判定の一致度が低め（\(String(format: "%.2f", snapshot.mapScore))）")
        }
        let shaky = (snapshot.allies + snapshot.enemies).filter { !$0.isConfident }
        if !shaky.isEmpty {
            notes.append("認識が曖昧: \(shaky.map(\.name).joined(separator: ", "))")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " / ")
    }

    private static func signed(_ value: Double) -> String {
        value >= 0 ? "+\(Int(value))" : "\(Int(value))"
    }
}

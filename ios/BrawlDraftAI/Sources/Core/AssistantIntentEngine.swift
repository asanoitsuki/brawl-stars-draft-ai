import Foundation

/// 対話モードで聞かれた質問に、いま分かっている情報（直近の解析結果・rules.json）だけで答える。
/// クラウドAIは使わず、キーワード照合の簡易対話にとどめる（オフライン・無料で完結させるため）。
@MainActor
enum AssistantIntentEngine {
    struct Answer {
        let text: String
        let shouldStop: Bool
    }

    static func answer(to question: String) -> Answer {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)

        if containsAny(q, ["やめて", "終了", "ストップ", "もういい", "またね", "ばいばい", "おわり"]) {
            return Answer(text: "対話モードを終了します。", shouldStop: true)
        }

        guard let rules = RulesStore.shared.loaded else {
            return Answer(text: "まだデータを読み込み中です。少し待ってから聞いてください。", shouldStop: false)
        }
        guard let result = DraftService.lastResult, !result.recommendation.advices.isEmpty else {
            return Answer(text: "まだ解析結果がありません。先にスクリーンショットを解析してから聞いてください。",
                          shouldStop: false)
        }
        let advices = result.recommendation.advices
        let snapshot = result.snapshot

        if let brawler = matchBrawler(in: q, rules: rules) {
            return Answer(text: brawlerAnswer(brawler, rules: rules), shouldStop: false)
        }
        if let role = matchRole(in: q, rules: rules) {
            return Answer(text: roleAnswer(role, top: advices[0], rules: rules), shouldStop: false)
        }
        if containsAny(q, ["ガジェット"]) {
            return Answer(text: loadoutAnswer(advices[0], rules: rules, kind: .gadget), shouldStop: false)
        }
        if containsAny(q, ["スターパワー", "エスピー"]) {
            return Answer(text: loadoutAnswer(advices[0], rules: rules, kind: .starPower), shouldStop: false)
        }
        if containsAny(q, ["立ち回り", "どう動け", "動き方", "コツ"]) {
            if let tip = rules.roleTip(advices[0].role) {
                return Answer(text: "\(displayName(advices[0]))の立ち回りは、\(tip)", shouldStop: false)
            }
        }
        if containsAny(q, ["マップ", "ステージ"]) {
            if let map = snapshot.map {
                return Answer(text: "マップは\(map.nameJa ?? map.name)、モードは\(map.modeJa)です。",
                              shouldStop: false)
            } else if let modeJa = snapshot.modeJa {
                return Answer(text: "モードは\(modeJa)です。マップまでは判別できていません。", shouldStop: false)
            }
        }
        if containsAny(q, ["三位", "3位", "さんい"]), advices.count > 2 {
            return Answer(text: reasonedAnswer(prefix: "三位は", advice: advices[2]), shouldStop: false)
        }
        if containsAny(q, ["二位", "2位", "次点", "他には", "ほかには", "ほかは", "代わり"]), advices.count > 1 {
            return Answer(text: reasonedAnswer(prefix: "二位は", advice: advices[1]), shouldStop: false)
        }
        if containsAny(q, ["なんで", "理由", "根拠", "どうして", "なぜ"]) {
            return Answer(text: reasonedAnswer(prefix: "理由は、", advice: advices[0], skipName: true),
                          shouldStop: false)
        }
        if containsAny(q, ["おすすめ", "誰がいい", "誰を", "何を", "ピック", "候補", "一位", "1位"]) {
            return Answer(text: reasonedAnswer(prefix: "おすすめは", advice: advices[0]), shouldStop: false)
        }

        return Answer(
            text: "すみません、うまく聞き取れませんでした。"
                + "「おすすめは?」「なんで?」「次点は?」「ガジェットは?」「(キャラ名)どう?」のように聞いてみてください。",
            shouldStop: false
        )
    }

    // MARK: - 個別の回答文

    private enum LoadoutKind { case gadget, starPower }

    private static func loadoutAnswer(_ advice: PickAdvice, rules: LoadedRules, kind: LoadoutKind) -> String {
        guard let brawler = rules.document.brawlers.first(where: { $0.id == advice.id }) else {
            return "データが見つかりませんでした。"
        }
        let items = kind == .gadget ? brawler.gadgets : brawler.starPowers
        let label = kind == .gadget ? "ガジェット" : "スターパワー"
        guard !items.isEmpty else {
            return "\(displayName(advice))の\(label)データはありません。"
        }
        let lines = items.map { item -> String in
            guard let wr = item.measuredWinRate else { return item.name }
            return "\(item.name)、実測勝率\(String(format: "%.1f", wr))パーセント"
        }
        return "\(displayName(advice))の\(label)は、" + lines.joined(separator: "、と、") + "です。"
    }

    private static func brawlerAnswer(_ brawler: BrawlerRole, rules: LoadedRules) -> String {
        var parts: [String] = ["\(brawler.nameJa ?? brawler.name)は\(brawler.roleJa)です"]
        if let tip = rules.roleTip(brawler.role) {
            parts.append("立ち回りは、\(tip)")
        }
        if let advRow = rules.document.advantage[brawler.role] {
            let best = advRow.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(2)
            if !best.isEmpty {
                parts.append("得意な相手は" + best.map { rules.japaneseRole($0.key) }.joined(separator: "、"))
            }
            let worst = advRow.filter { $0.value < 0 }.sorted { $0.value < $1.value }.prefix(2)
            if !worst.isEmpty {
                parts.append("苦手な相手は" + worst.map { rules.japaneseRole($0.key) }.joined(separator: "、"))
            }
        }
        return parts.joined(separator: "。") + "。"
    }

    private static func roleAnswer(_ enemyRole: String, top: PickAdvice, rules: LoadedRules) -> String {
        let ja = rules.japaneseRole(enemyRole)
        let adv = rules.advantage(top.role, vs: enemyRole)
        let verdict: String
        if adv >= 1 { verdict = "有利です" }
        else if adv <= -1 { verdict = "不利です" }
        else { verdict = "五分です" }
        let examples = rules.document.brawlers
            .filter { $0.role == enemyRole && $0.tier > 0 }
            .sorted { $0.tier > $1.tier }
            .prefix(2)
            .map { $0.nameJa ?? $0.name }
        var text = "\(displayName(top))は相手の\(ja)に対して\(verdict)。"
        if !examples.isEmpty {
            text += "\(ja)の例としては" + examples.joined(separator: "、") + "などがいます。"
        }
        return text
    }

    private static func reasonedAnswer(prefix: String, advice: PickAdvice, skipName: Bool = false) -> String {
        let name = skipName ? "" : "\(displayName(advice))です。"
        let reason = advice.reason.isEmpty
            ? "このマップでの評価が高いためです"
            : advice.reason.replacingOccurrences(of: " / ", with: "、")
        return "\(prefix)\(name)\(reason)。"
    }

    // MARK: - キーワード / 名前照合

    private static func matchBrawler(in q: String, rules: LoadedRules) -> BrawlerRole? {
        // 長い名前から先に照合する（"エド" が別のキャラ名に部分一致しないように）。
        let byJapanese = rules.document.brawlers.sorted {
            ($0.nameJa?.count ?? 0) > ($1.nameJa?.count ?? 0)
        }
        for b in byJapanese {
            if let ja = b.nameJa, ja.count >= 2, q.contains(ja) { return b }
        }
        let lowered = q.lowercased()
        for b in rules.document.brawlers.sorted(by: { $0.name.count > $1.name.count }) {
            if b.name.count >= 3, lowered.contains(b.name.lowercased()) { return b }
        }
        return nil
    }

    private static func matchRole(in q: String, rules: LoadedRules) -> String? {
        let sorted = rules.document.archetypes.sorted { $0.value.count > $1.value.count }
        for (key, ja) in sorted where q.contains(ja) { return key }
        return nil
    }

    private static func displayName(_ advice: PickAdvice) -> String {
        advice.nameJa ?? advice.name
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}

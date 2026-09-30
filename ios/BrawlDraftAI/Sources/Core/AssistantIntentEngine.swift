import Foundation

/// 対話モードで聞かれた質問（新しい状況の申告ではない、雑談的な質問）に、
/// いま組み立て中のドラフト状態だけを根拠に答える。クラウドAIは使わず、
/// キーワード照合の簡易対話にとどめる（オフライン・無料で完結させるため）。
enum AssistantIntentEngine {
    static func answer(to question: String, rules: LoadedRules,
                       snapshot: DraftSnapshot, recommendation: Recommendation) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let advices = recommendation.advices

        if let brawler = matchBrawler(in: q, rules: rules) {
            return brawlerAnswer(brawler, rules: rules)
        }
        if let role = matchRole(in: q, rules: rules), let top = advices.first {
            return roleAnswer(role, top: top, rules: rules)
        }
        guard !advices.isEmpty else {
            return "まだ判断材料が足りません。マップやピックの状況を教えてください。"
        }
        if containsAny(q, ["ガジェット"]) {
            return loadoutAnswer(advices[0], rules: rules, kind: .gadget)
        }
        if containsAny(q, ["スターパワー", "エスピー"]) {
            return loadoutAnswer(advices[0], rules: rules, kind: .starPower)
        }
        if containsAny(q, ["立ち回り", "どう動け", "動き方", "コツ"]) {
            if let tip = rules.roleTip(advices[0].role) {
                return "\(displayName(advices[0]))の立ち回りは、\(tip)"
            }
        }
        if containsAny(q, ["マップ", "ステージ"]) {
            if let map = snapshot.map {
                return "マップは\(map.nameJa ?? map.name)、モードは\(map.modeJa)です。"
            } else if let modeJa = snapshot.modeJa {
                return "モードは\(modeJa)です。マップはまだ聞いていません。"
            }
            return "マップはまだ聞いていません。"
        }
        if containsAny(q, ["三位", "3位", "さんい"]), advices.count > 2 {
            return reasonedAnswer(prefix: "三位は", advice: advices[2])
        }
        if containsAny(q, ["二位", "2位", "次点", "他には", "ほかには", "ほかは", "代わり"]), advices.count > 1 {
            return reasonedAnswer(prefix: "二位は", advice: advices[1])
        }
        if containsAny(q, ["なんで", "理由", "根拠", "どうして", "なぜ"]) {
            return reasonedAnswer(prefix: "理由は、", advice: advices[0], skipName: true)
        }
        if containsAny(q, ["おすすめ", "誰がいい", "誰を", "何を", "ピック", "候補", "一位", "1位"]) {
            return reasonedAnswer(prefix: "おすすめは", advice: advices[0])
        }

        return "すみません、うまく聞き取れませんでした。"
            + "「このマップになった」「相手はこれを選んだ」のように状況を教えるか、"
            + "「おすすめは?」「なんで?」のように聞いてみてください。"
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
        let byJapanese = rules.document.brawlers.sorted {
            ($0.nameJa?.count ?? 0) > ($1.nameJa?.count ?? 0)
        }
        for b in byJapanese {
            if let ja = b.nameJa, ja.count >= 2, q.contains(ja) { return b }
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

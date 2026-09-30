import Foundation

/// 対話モード専用の「声だけでドラフト状況を組み立てる」状態管理。
///
/// スマホでブロスタ本体を操作しながら、別端末（iPad など）でこのアプリを対話モードで
/// 開いておき、「このマップになった」「相手、二人はこれを選んだ」のように実況してもらう
/// 運用を想定している。スクリーンショット解析は使わない — 声で申告された内容だけを
/// 積み上げて `Recommender` に渡せる `DraftSnapshot` を組み立てる。
@MainActor
final class DraftDictationSession {
    private(set) var mode: String?
    private(set) var modeJa: String?
    private(set) var map: MapRules?
    private(set) var bans: [DetectedBrawler] = []
    private(set) var allies: [DetectedBrawler] = []
    private(set) var enemies: [DetectedBrawler] = []

    private var nextSlot = 0
    private var history: [(bucket: Bucket, brawler: DetectedBrawler)] = []
    /// 「相手は」「味方は」と言っただけでキャラ名がまだ出てきていない節があったとき、
    /// そのバケツを覚えておく。無音判定で発話が「相手は」と「レオン」の2回に千切れても、
    /// 次の発話で名前だけ言われたときに正しい側へ割り当てるため。
    private var pendingBucket: Bucket?

    private enum Bucket { case ban, ally, enemy }

    struct IngestResult {
        var mapChanged = false
        var modeChanged = false
        var addedBans: [BrawlerRole] = []
        var addedAllies: [BrawlerRole] = []
        var addedEnemies: [BrawlerRole] = []

        var changed: Bool {
            mapChanged || modeChanged || !addedBans.isEmpty || !addedAllies.isEmpty || !addedEnemies.isEmpty
        }
    }

    func reset() {
        mode = nil; modeJa = nil; map = nil
        bans = []; allies = []; enemies = []
        nextSlot = 0
        history = []
        pendingBucket = nil
    }

    private var takenIDs: Set<Int> {
        Set((bans + allies + enemies).map(\.id))
    }

    /// 発話 1 個ぶんを取り込む。マップ／モード／BAN／ピックのいずれかを認識できたら
    /// 状態を更新し、何を認識したかを `IngestResult` で返す。
    @discardableResult
    func ingest(_ text: String, rules: LoadedRules) -> IngestResult {
        var result = IngestResult()

        if let foundMap = matchMap(in: text, rules: rules) {
            map = foundMap
            mode = foundMap.mode
            modeJa = foundMap.modeJa
            result.mapChanged = true
        } else if let foundMode = matchMode(in: text, rules: rules) {
            mode = foundMode.key
            modeJa = foundMode.ja
            result.modeChanged = true
        }

        for (bucket, brawler) in extractPicks(from: text, rules: rules) {
            guard !takenIDs.contains(brawler.id) else { continue }
            let detected = DetectedBrawler(
                id: brawler.id, name: brawler.name,
                role: brawler.role, roleJa: brawler.roleJa,
                score: 1, margin: 1, slot: nextSlot
            )
            nextSlot += 1
            switch bucket {
            case .ban: bans.append(detected); result.addedBans.append(brawler)
            case .ally: allies.append(detected); result.addedAllies.append(brawler)
            case .enemy: enemies.append(detected); result.addedEnemies.append(brawler)
            }
            history.append((bucket, detected))
        }
        return result
    }

    /// 直前に記録した 1 件を取り消す（聞き間違い訂正用）。
    @discardableResult
    func undoLast() -> DetectedBrawler? {
        guard let last = history.popLast() else { return nil }
        switch last.bucket {
        case .ban: bans.removeAll { $0.id == last.brawler.id }
        case .ally: allies.removeAll { $0.id == last.brawler.id }
        case .enemy: enemies.removeAll { $0.id == last.brawler.id }
        }
        return last.brawler
    }

    /// いまの状態から `Recommender` に渡せるスナップショットを組み立てる。
    func buildSnapshot() -> DraftSnapshot {
        // マップ・BAN・相手ピックのどれかが申告されていれば「エリート以上」形式とみなす。
        // ブラインドピック帯ではマップも相手ピックも最後まで分からないため。
        let kind: ScreenKind = (map != nil || !bans.isEmpty || !enemies.isEmpty) ? .draftPick : .blindPick

        let phase: DraftPhase
        if kind == .blindPick {
            phase = .blind(filled: allies.count, total: 3)
        } else {
            // 本当の BAN 数はゲーム側の仕様に依存し声だけでは分からないため、
            // 2（各陣営 1 枠ずつ）を仮の既定値としている。ピックが 1 つでも
            // 申告されればこの値に関係なく手番のフェーズへ進む。
            phase = DraftPhase.from(pickedCount: allies.count + enemies.count,
                                    banCount: bans.count, expectedBans: 2)
        }

        return DraftSnapshot(
            kind: kind, mode: mode, modeJa: modeJa, map: map,
            mapScore: map != nil ? 1 : 0, mapMargin: map != nil ? 1 : 0,
            bans: bans, allies: allies, enemies: enemies,
            phase: phase, layoutName: "対話モード（音声申告）", elapsed: 0
        )
    }

    // MARK: - 照合

    private static let banKeywords = ["バン", "禁止"]
    private static let enemyCues = ["相手", "敵"]
    private static let allyCues = ["味方", "自チーム", "自分たち", "こっち", "こちら"]

    private struct CueHit { let bucket: Bucket; let range: Range<String.Index> }

    /// 1 発話に「味方はコレを選んだ、相手はコレをバンした」のように複数の事実が
    /// 混ざっているケースに対応するため、日本語の語順（主語→目的語→述語）を踏まえて
    /// 「相手」「味方」などの主語手がかりの出現位置で発話を区切り、区切り単位（節）ごとに
    /// バケツ（ban/ally/enemy）を決めてから、その節の中のキャラ名だけをそのバケツに割り当てる。
    /// 「バンした」のような述語は名前より後ろに来ることが多いため、節全体からキーワードを
    /// 探す（先頭からの逐次スキャンだと述語を名前より先に見てしまい判定を誤る）。
    private func extractPicks(from text: String, rules: LoadedRules) -> [(Bucket, BrawlerRole)] {
        var picks: [(Bucket, BrawlerRole)] = []
        var anyFound = false
        for (cueBucket, segment) in splitIntoSegments(text) {
            let segText = String(segment)
            let isBan = Self.banKeywords.contains { segText.contains($0) }
            let names = matchBrawlers(in: segText, rules: rules)

            guard !names.isEmpty else {
                // 「相手は」「味方は」だけでキャラ名がまだ無い節。無音判定で発話が千切れて
                // 次の発話に名前だけ来るケースに備えて、このバケツを持ち越す。
                if isBan { pendingBucket = .ban }
                else if let cueBucket { pendingBucket = cueBucket }
                continue
            }

            let bucket: Bucket = isBan ? .ban : (cueBucket ?? pendingBucket ?? .ally)
            for brawler in names { picks.append((bucket, brawler)) }
            anyFound = true
        }
        if anyFound { pendingBucket = nil }
        return picks
    }

    /// 「相手」「味方」などの主語手がかりの出現位置で発話全体を節に区切る。
    /// 手がかりが 1 つも無い発話は、そのまま 1 節（手がかり無し=nil）として扱う。
    private func splitIntoSegments(_ text: String) -> [(bucket: Bucket?, text: Substring)] {
        var hits: [CueHit] = []
        for kw in Self.enemyCues {
            var from = text.startIndex
            while let r = text.range(of: kw, range: from..<text.endIndex) {
                hits.append(CueHit(bucket: .enemy, range: r))
                from = r.upperBound
            }
        }
        for kw in Self.allyCues {
            var from = text.startIndex
            while let r = text.range(of: kw, range: from..<text.endIndex) {
                hits.append(CueHit(bucket: .ally, range: r))
                from = r.upperBound
            }
        }
        guard !hits.isEmpty else { return [(nil, text[...])] }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }

        var segments: [(Bucket?, Substring)] = []
        if hits[0].range.lowerBound > text.startIndex {
            segments.append((nil, text[text.startIndex..<hits[0].range.lowerBound]))
        }
        for (i, hit) in hits.enumerated() {
            let end = i + 1 < hits.count ? hits[i + 1].range.lowerBound : text.endIndex
            segments.append((hit.bucket, text[hit.range.lowerBound..<end]))
        }
        return segments
    }

    private func matchMap(in text: String, rules: LoadedRules) -> MapRules? {
        for (ja, id) in rules.mapIDByJapaneseName where text.contains(ja) {
            return rules.map(id: id)
        }
        return nil
    }

    private func matchMode(in text: String, rules: LoadedRules) -> (key: String, ja: String)? {
        let sorted = rules.document.modes.sorted { $0.value.ja.count > $1.value.ja.count }
        for (key, info) in sorted where text.contains(info.ja) {
            return (key, info.ja)
        }
        return nil
    }

    /// 1 発話に複数のキャラ名が含まれるケース（「相手、二人はこれとこれを選んだ」）に
    /// 対応するため、見つかった名前は全部拾う。長い名前から照合し、拾った分は元の
    /// テキストから消してから残りを探すことで、部分一致の重複ヒットを避ける。
    private func matchBrawlers(in text: String, rules: LoadedRules) -> [BrawlerRole] {
        var found: [BrawlerRole] = []
        var remaining = text
        let byLength = rules.document.brawlers.sorted { ($0.nameJa?.count ?? 0) > ($1.nameJa?.count ?? 0) }
        for b in byLength {
            guard let ja = b.nameJa, ja.count >= 2, remaining.contains(ja) else { continue }
            found.append(b)
            remaining = remaining.replacingOccurrences(of: ja, with: "")
        }
        return found
    }
}

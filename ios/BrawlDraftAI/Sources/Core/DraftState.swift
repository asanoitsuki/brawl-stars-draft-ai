import Foundation

/// 画面から読み取れた 1 体ぶんのキャラ。
struct DetectedBrawler: Identifiable, Hashable {
    let id: Int
    let name: String
    let role: String
    let roleJa: String
    /// テンプレートとの一致度（0〜1）
    let score: Float
    /// 2 位との差。小さいほど「似たキャラと迷っている」
    let margin: Float
    /// 何番目の枠か
    let slot: Int

    var isConfident: Bool { score >= TemplateMatcher.acceptScore && margin >= TemplateMatcher.acceptMargin }
}

/// いまドラフトの何手目か。
enum DraftPhase: Equatable {
    /// BAN フェーズ
    case ban
    /// 1手目（先頭ピック）
    case first
    /// 2〜5手目
    case middle(Int)
    /// 6手目（ラストピック）
    case last
    /// 6手すべて埋まっている
    case complete

    /// 全体で何番目のピックか（1〜6）。BAN / 完了時は nil。
    var pickNumber: Int? {
        switch self {
        case .first: return 1
        case .middle(let n): return n
        case .last: return 6
        case .ban, .complete: return nil
        }
    }

    var label: String {
        switch self {
        case .ban: return "BANフェーズ"
        case .first: return "初手（1番目）"
        case .middle(let n): return "\(n)番目"
        case .last: return "ラストピック（6番目）"
        case .complete: return "ドラフト完了"
        }
    }

    var shortLabel: String {
        switch self {
        case .ban: return "BAN"
        case .first: return "初手"
        case .middle(let n): return "\(n)手目"
        case .last: return "ラスト"
        case .complete: return "完了"
        }
    }

    static func from(pickedCount: Int, banCount: Int, expectedBans: Int) -> DraftPhase {
        if pickedCount == 0 && banCount < expectedBans && expectedBans > 0 { return .ban }
        switch pickedCount {
        case 0: return .first
        case 1...4: return .middle(pickedCount + 1)
        case 5: return .last
        default: return .complete
        }
    }
}

/// 1 回の解析結果。
struct DraftSnapshot {
    let map: MapRules?
    let mapScore: Float
    let mapMargin: Float
    let bans: [DetectedBrawler]
    let allies: [DetectedBrawler]
    let enemies: [DetectedBrawler]
    let phase: DraftPhase
    let layoutName: String
    /// 解析にかかった秒数
    let elapsed: TimeInterval

    var takenIDs: Set<Int> {
        Set((bans + allies + enemies).map(\.id))
    }

    var pickedCount: Int { allies.count + enemies.count }

    /// 画面をちゃんと読めていそうか。
    var isUsable: Bool { map != nil }

    var diagnosticSummary: String {
        let mapText = map.map { "\($0.name)（\($0.modeJa)）一致度 \(String(format: "%.2f", mapScore))" }
            ?? "マップ不明"
        return """
        \(mapText)
        自陣: \(allies.map(\.name).joined(separator: ", ").ifEmpty("なし"))
        相手: \(enemies.map(\.name).joined(separator: ", ").ifEmpty("なし"))
        BAN: \(bans.map(\.name).joined(separator: ", ").ifEmpty("なし"))
        フェーズ: \(phase.label) / 解析 \(String(format: "%.0f", elapsed * 1000)) ms / 配置 \(layoutName)
        """
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

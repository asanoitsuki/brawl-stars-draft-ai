import Foundation

// MARK: - rules.json

/// `scripts/update_meta.py` が毎日生成する rules.json をそのまま写したもの。
struct RulesDocument: Decodable {
    let schema: Int
    let generatedAt: String
    let dataQuality: DataQuality
    let draftOrder: [String]
    /// モード英語キー -> 日本語名・アーキタイプ別重み。
    /// マップ情報が無いブラインドピック画面では、OCR で読んだモード名からこれを引く。
    let modes: [String: ModeInfo]
    /// アーキタイプ英語キー -> 日本語表示名
    let archetypes: [String: String]
    /// advantage[自分の役割][相手の役割] = -2…+2
    let advantage: [String: [String: Double]]
    /// synergy[自分の役割][味方の役割] = -1…+1
    let synergy: [String: [String: Double]]
    let brawlers: [BrawlerRole]
    let maps: [MapRules]

    struct DataQuality: Decodable {
        let liveStats: Bool
        let mapsWithLiveStats: Int
        let rotationKnown: Bool
        let rotationSource: String?
        /// data/tier_overrides.json で手入力された強さ補正の件数
        let manualTiers: Int?
        /// "winRate" / "manualTier" / "alphabetical"
        let tiebreak: String?
        let note: String

        /// スコアの信頼度を 3 段階で表す。
        enum Confidence {
            /// 実測勝率あり
            case measured
            /// 実測なし・手動ティアで同点は解消済み
            case manualTier(count: Int)
            /// 実測もティアも無く、同じ役割は同点（並び順に意味なし）
            case roleOnly
        }

        var confidence: Confidence {
            if liveStats { return .measured }
            if let manualTiers, manualTiers > 0 { return .manualTier(count: manualTiers) }
            return .roleOnly
        }
    }
}

struct ModeInfo: Decodable {
    let ja: String
    let weights: [String: Double]
}

struct BrawlerRole: Decodable {
    let id: Int
    let name: String
    /// 読み上げ用のカタカナ表記（data/brawler_names_ja.json 由来）
    let nameJa: String?
    let role: String
    let roleJa: String
}

struct MapRules: Decodable {
    let id: Int
    let name: String
    let mode: String
    let modeJa: String
    let environment: String?
    let inRotation: Bool
    let hasLiveStats: Bool
    let nameAliases: [String]
    let bans: [PickSuggestion]
    let picks: PickPlan
    let candidates: [Candidate]
    let template: TemplateDescriptor?

    struct Candidate: Decodable {
        let id: Int
        let name: String
        let role: String
        let base: Double
        let winRate: Double?
        let useRate: Double?
    }
}

struct PickPlan: Decodable {
    /// 初手（1番目）: 対策されにくい環境最強
    let first: [PickSuggestion]
    /// 中盤（2〜5番目）: シナジー + 部分的カウンター
    let middle: Middle
    /// ラスト（6番目）: 相手構成への絶対的カウンター
    let last: Last

    struct Middle: Decodable {
        let general: [PickSuggestion]
        let byAllyRole: [String: [PickSuggestion]]
        let byEnemyRole: [String: [PickSuggestion]]
    }

    struct Last: Decodable {
        let byEnemyRole: [String: [PickSuggestion]]
    }
}

struct PickSuggestion: Decodable {
    let id: Int
    let name: String
    let role: String
    let roleJa: String?
    let score: Double
    let reason: String?
    let winRate: Double?
    let useRate: Double?
    let advantage: Double?
    let synergy: Double?
    let vulnerability: Double?
}

// MARK: - templates.json

/// `scripts/download_icons.py` が生成するキャラアイコンの記述子パック。
struct TemplatePack: Decodable {
    let schema: Int
    let variant: String
    let graySize: Int
    let colorSize: Int
    let count: Int
    let templates: [Entry]

    struct Entry: Decodable {
        let id: Int
        let name: String
        let rarity: String?
        let gray: [Double]
        let color: [Double]
        let dhash: String
    }
}

struct TemplateDescriptor: Decodable {
    let gray: [Double]
    let color: [Double]
    let dhash: String
}

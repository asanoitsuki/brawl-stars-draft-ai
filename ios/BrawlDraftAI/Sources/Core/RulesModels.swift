import Foundation

// MARK: - rules.json

/// `scripts/update_meta.py` が毎日生成する rules.json をそのまま写したもの。
struct RulesDocument: Decodable {
    let schema: Int
    let generatedAt: String
    let dataQuality: DataQuality
    let draftOrder: [String]
    /// モード英語キー -> 日本語名・アーキタイプ別重み。
    /// マップが特定できないときの土台として、OCR で読んだモード名からこれを引く。
    let modes: [String: ModeInfo]
    /// アーキタイプ英語キー -> 日本語表示名
    let archetypes: [String: String]
    /// アーキタイプ英語キー -> 「どう立ち回るか」の一言アドバイス。
    let roleTips: [String: String]
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
    /// data/tier_overrides.json の手入力強さ補正（-1.5〜+1.5）。実測ではなく手入力の初期値。
    /// 役割ごとの「メタキャラ例」表示に使う。
    let tier: Double
    /// スターパワー・ガジェット（Brawlify 由来。名前・説明は原文の英語のまま — 機械翻訳で
    /// 誤訳を混ぜると信頼性を損なうため）。ギアは Brawlify API に無いため非対応。
    let starPowers: [Loadout]
    let gadgets: [Loadout]

    struct Loadout: Decodable, Identifiable {
        let id: Int
        let name: String
        let description: String
        /// バンドル同梱ファイル名（拡張子なし）。取得できなかった場合は nil。
        let image: String?
        /// 実測勝率（brawltime.ninja 由来、%）。measured statistics — 意見ではない。
        let measuredWinRate: Double?
        /// 攻略サイトの意見（timesaver.gg 由来）。実測ではないので区別して表示する。
        let communityNote: String?
    }
}

struct MapRules: Decodable {
    let id: Int
    let name: String
    /// マップ名の日本語表記（OCR でブラインドピック画面から読み取ったマップ名の突き合わせに使う）
    let nameJa: String?
    let mode: String
    let modeJa: String
    let environment: String?
    let inRotation: Bool
    let hasLiveStats: Bool
    /// 画像・データの出典（Brawlify）。信憑性を示すための「出典」表示に使う。
    let imageUrl: String?
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
        /// base の内訳（マップ適性・手動ティア・実測勝率）を人間可読にしたもの。
        /// 味方シナジーはここに含まれない（対戦相手・味方は解析時にしか分からないため）。
        let reason: String?
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

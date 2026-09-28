import Foundation

/// アプリ設定。ショートカット経由の起動でも同じ値を読むので UserDefaults に置く。
enum AppSettings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let rulesURL = "rulesURL"
        static let speechEnabled = "speechEnabled"
        static let speechRate = "speechRate"
        static let notificationEnabled = "notificationEnabled"
        static let lastRefresh = "lastRefreshAt"
        static let autoRefreshHours = "autoRefreshHours"
        static let maxAnnouncedPicks = "maxAnnouncedPicks"
        static let excludedBrawlerIDs = "excludedBrawlerIDs"
    }

    /// 毎日 GitHub Actions が更新する rules.json の置き場所。
    /// 既定でこのプロジェクトの公開リポジトリを指す — 一般ユーザーが設定を一切
    /// 触らなくても、初回起動後は自動で毎日最新データに更新されるようにするため。
    /// 自分でフォークして運用する場合はこの値を書き換える。
    static var rulesURL: String {
        get { defaults.string(forKey: Key.rulesURL) ?? defaultRulesURL }
        set { defaults.set(newValue, forKey: Key.rulesURL) }
    }

    static let defaultRulesURL =
        "https://raw.githubusercontent.com/asanoitsuki/brawl-stars-draft-ai/main/rules/rules_rotation.json"

    static var isRulesURLConfigured: Bool {
        !rulesURL.contains("YOUR_NAME") && URL(string: rulesURL) != nil
    }

    static var speechEnabled: Bool {
        get { defaults.object(forKey: Key.speechEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.speechEnabled) }
    }

    /// 0.45〜0.65 くらいが聞き取れる上限。既定は少し速め。
    static var speechRate: Double {
        get { defaults.object(forKey: Key.speechRate) as? Double ?? 0.56 }
        set { defaults.set(newValue, forKey: Key.speechRate) }
    }

    static var notificationEnabled: Bool {
        get { defaults.object(forKey: Key.notificationEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.notificationEnabled) }
    }

    /// 読み上げるキャラ数（1〜3）。多いと喋り終わる前にピックが終わる。
    static var maxAnnouncedPicks: Int {
        get { max(1, min(3, defaults.object(forKey: Key.maxAnnouncedPicks) as? Int ?? 2)) }
        set { defaults.set(newValue, forKey: Key.maxAnnouncedPicks) }
    }

    static var autoRefreshHours: Double {
        get { defaults.object(forKey: Key.autoRefreshHours) as? Double ?? 6 }
        set { defaults.set(newValue, forKey: Key.autoRefreshHours) }
    }

    static var lastRefreshAt: Date? {
        get { defaults.object(forKey: Key.lastRefresh) as? Date }
        set { defaults.set(newValue, forKey: Key.lastRefresh) }
    }

    static var needsRefresh: Bool {
        guard let last = lastRefreshAt else { return true }
        return Date().timeIntervalSince(last) > autoRefreshHours * 3600
    }

    /// 「持っていない」と手動で外したキャラの ID。
    /// 初期状態は空 = 全キャラ所持扱い（キャラ一覧画面で個別にオフにしていく運用）。
    static var excludedBrawlerIDs: Set<Int> {
        get { Set((defaults.array(forKey: Key.excludedBrawlerIDs) as? [Int]) ?? []) }
        set {
            defaults.set(Array(newValue), forKey: Key.excludedBrawlerIDs)
            // 解析中の重い画像処理でアプリがメモリ不足のまま強制終了された場合に備え、
            // ディスクへの反映をその場で確定させる（通常は不要だが所持設定は消えると
            // 実害が大きいため明示的に synchronize する）。
            defaults.synchronize()
        }
    }

    static func isOwned(_ brawlerID: Int) -> Bool {
        !excludedBrawlerIDs.contains(brawlerID)
    }

    static func setOwned(_ brawlerID: Int, owned: Bool) {
        var s = excludedBrawlerIDs
        if owned { s.remove(brawlerID) } else { s.insert(brawlerID) }
        excludedBrawlerIDs = s
    }

    /// 全キャラをまとめて所持/非所持にする。
    /// `setOwned` を要素数ぶん繰り返すと、その都度 UserDefaults の配列全体を
    /// 読み書きすることになり（109 体なら 109 回の read-modify-write）、
    /// メインスレッド上で体感できる遅延になり得る。1 回の書き込みで済ませる。
    static func setAllOwned(_ ids: some Sequence<Int>, owned: Bool) {
        excludedBrawlerIDs = owned ? [] : Set(ids)
    }
}

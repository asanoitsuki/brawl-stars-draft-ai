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
    }

    /// 毎日 GitHub Actions が更新する rules.json の置き場所。
    /// 自分のリポジトリに合わせて設定画面から書き換える。
    static var rulesURL: String {
        get { defaults.string(forKey: Key.rulesURL) ?? defaultRulesURL }
        set { defaults.set(newValue, forKey: Key.rulesURL) }
    }

    static let defaultRulesURL =
        "https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/rules/rules_rotation.json"

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
}

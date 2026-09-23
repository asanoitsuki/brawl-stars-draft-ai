import AppIntents

/// Siri とショートカットアプリに出てくる定型フレーズ。
@available(iOS 17.0, *)
struct BrawlDraftShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AnalyzeLatestScreenshotIntent(),
            phrases: [
                "\(.applicationName)でドラフト解析",
                "\(.applicationName)でピックを教えて",
                "Analyze draft with \(.applicationName)"
            ],
            shortTitle: "ドラフト解析",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: PrepareRulesIntent(),
            phrases: [
                "\(.applicationName)のルールを更新",
                "Update \(.applicationName) rules"
            ],
            shortTitle: "ルール更新",
            systemImageName: "arrow.clockwise"
        )
    }
}

import AppIntents
import Foundation
import UniformTypeIdentifiers

/// ショートカットから「スクリーンショットを渡して解析する」入口。
///
/// 背面タップ → ショートカット の構成例:
///   1. 「写真を検索」: アルバム＝スクリーンショット / 撮影日時が新しい順 / 1 件
///   2. このアクション（ドラフトを解析）に渡す
@available(iOS 17.0, *)
struct AnalyzeDraftIntent: AppIntent {
    static var title: LocalizedStringResource = "ドラフトを解析"
    static var description = IntentDescription(
        "ブロスタのガチバトル・ドラフト画面のスクリーンショットから、いま取るべきキャラを提案します。",
        categoryName: "ブロスタ"
    )
    /// アプリを前面に出さない = ゲームに戻らずに済む
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "スクリーンショット",
        description: "省略すると、写真ライブラリの最新のスクリーンショットを使います。",
        supportedTypeIdentifiers: ["public.image"]
    )
    var screenshot: IntentFile?

    @Parameter(title: "読み上げる", default: true)
    var speak: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$screenshot) からドラフトを解析") {
            \.$speak
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppSettings.speechEnabled = speak

        let recommendation: Recommendation
        if let screenshot {
            recommendation = try await DraftService.analyze(data: screenshot.data)
        } else {
            recommendation = try await DraftService.analyzeLatestScreenshot()
        }
        return .result(dialog: IntentDialog(stringLiteral: recommendation.title))
    }
}

/// パラメータ無しの最短ルート。背面タップに割り当てるのはこちらが手軽。
@available(iOS 17.0, *)
struct AnalyzeLatestScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "最新スクショでドラフト解析"
    static var description = IntentDescription(
        "写真ライブラリの最新のスクリーンショットを解析して、次に取るべきキャラを通知と音声で知らせます。",
        categoryName: "ブロスタ"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recommendation = try await DraftService.analyzeLatestScreenshot()
        return .result(dialog: IntentDialog(stringLiteral: recommendation.title))
    }
}

/// ルールデータだけ先に温めておくアクション（対戦前に走らせる用）。
@available(iOS 17.0, *)
struct PrepareRulesIntent: AppIntent {
    static var title: LocalizedStringResource = "ルールデータを準備"
    static var description = IntentDescription(
        "最新の rules.json を取得してメモリに載せます。対戦前に 1 回走らせておくと初回の解析も速くなります。",
        categoryName: "ブロスタ"
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await RulesStore.shared.refreshFromRemote(force: true)
        let rules = try await RulesStore.shared.rules()
        return .result(dialog: IntentDialog(stringLiteral:
            "ルール準備完了（\(rules.document.maps.count) マップ / \(rules.generatedAt)）"))
    }
}

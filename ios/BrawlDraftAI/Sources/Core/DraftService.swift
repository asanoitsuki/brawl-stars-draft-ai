import CoreGraphics
import Foundation

/// 「画像 1 枚 → 提案を通知＆読み上げ」までを 1 本にまとめた入口。
///
/// App Intent も URL スキームもアプリ内のテストボタンも、全部ここを呼ぶ。
enum DraftService {
    /// 直近の結果（アプリ画面で確認できるようにしておく）
    @MainActor private(set) static var lastResult: (snapshot: DraftSnapshot, recommendation: Recommendation)?

    @discardableResult
    static func analyze(image: CGImage, announce: Bool = true) async throws -> Recommendation {
        let rules = try await RulesStore.shared.rules()
        let snapshot = DraftAnalyzer.analyze(image: image, rules: rules)
        let recommendation = Recommender.make(from: snapshot, rules: rules)

        await MainActor.run { lastResult = (snapshot, recommendation) }

        if announce {
            // 読み上げを先に始める（バナーより耳の方が速い）
            SpeechAnnouncer.shared.announce(recommendation.speech)
            await NotificationPresenter.shared.present(recommendation)
        }
        return recommendation
    }

    @discardableResult
    static func analyze(data: Data, announce: Bool = true) async throws -> Recommendation {
        try await analyze(image: ScreenshotSource.image(from: data), announce: announce)
    }

    @discardableResult
    static func analyzeLatestScreenshot(announce: Bool = true) async throws -> Recommendation {
        try await analyze(image: try await ScreenshotSource.latestScreenshot(), announce: announce)
    }

    /// 起動直後に呼ぶ準備処理。判定の瞬間に I/O を残さないための先読み。
    static func warmUp() {
        Task { @MainActor in
            RulesStore.shared.preload()
            _ = try? await RulesStore.shared.rules()
            await RulesStore.shared.refreshFromRemote()
        }
        Task { await NotificationPresenter.shared.requestAuthorization() }
    }
}

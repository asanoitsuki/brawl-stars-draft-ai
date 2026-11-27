import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 「画像 1 枚 → 提案を通知＆読み上げ」までを 1 本にまとめた入口。
///
/// App Intent も URL スキームもアプリ内のボタンも、全部ここを呼ぶ。
enum DraftService {
    /// - announce: 通知バナーと読み上げを出すか
    /// - speak: false なら読み上げだけ止める（nil は設定に従う）
    @discardableResult
    static func analyze(image: CGImage, announce: Bool = true, speak: Bool? = nil) async throws -> Recommendation {
        let rules = try await RulesStore.shared.rules()
        let snapshot = try DraftAnalyzer.analyze(image: image, rules: rules)
        let recommendation = Recommender.make(from: snapshot, rules: rules)

        await AnalysisStore.shared.publish(snapshot, recommendation)
        LastScreenshot.save(image)

        if announce {
            // 読み上げを先に始める（バナーより耳の方が速い）
            if speak != false { SpeechAnnouncer.shared.announce(recommendation.speech) }
            await NotificationPresenter.shared.present(recommendation)
        }
        return recommendation
    }

    @discardableResult
    static func analyze(data: Data, announce: Bool = true, speak: Bool? = nil) async throws -> Recommendation {
        try await analyze(image: ScreenshotSource.image(from: data), announce: announce, speak: speak)
    }

    @discardableResult
    static func analyzeLatestScreenshot(announce: Bool = true) async throws -> Recommendation {
        try await analyze(image: try await ScreenshotSource.latestScreenshot(), announce: announce)
    }

    /// 起動直後に呼ぶ準備処理。判定の瞬間に I/O を残さないための先読み。
    static func warmUp() {
        Task { @MainActor in
            RulesStore.shared.preload()
            if let rules = try? await RulesStore.shared.rules() {
                Task { await GameArtLoader.prefetchBrawlerIcons(rules.document.brawlers.map(\.id)) }
            }
            await AnalysisStore.shared.restoreLastIfNeeded()
            await RulesStore.shared.refreshFromRemote()
        }
    }
}

/// 画面に出す直近の解析結果。
@MainActor
final class AnalysisStore: ObservableObject {
    static let shared = AnalysisStore()

    struct Analysis {
        var snapshot: DraftSnapshot
        var recommendation: Recommendation
        let date: Date
    }

    @Published private(set) var current: Analysis?

    func publish(_ snapshot: DraftSnapshot, _ recommendation: Recommendation, date: Date = Date()) {
        current = Analysis(snapshot: snapshot, recommendation: recommendation, date: date)
    }

    func clear() {
        current = nil
        LastScreenshot.delete()
    }

    /// ステージ名を読み違えた（読めなかった）ときに、手で選び直して提案を作り直す。
    func correct(map: MapRules, rules: LoadedRules) {
        guard let current else { return }
        let s = current.snapshot
        let fixed = DraftSnapshot(
            kind: s.kind, mode: map.mode, modeJa: map.modeJa, map: map, mapScore: 1, mapMargin: 1,
            bans: s.bans, allies: s.allies, enemies: s.enemies, phase: s.phase,
            layoutName: s.layoutName, elapsed: s.elapsed
        )
        publish(fixed, Recommender.make(from: fixed, rules: rules), date: current.date)
    }

    /// 背面タップで解析したあとにアプリを開いても結果が見られるように、直近の画像を読み直す。
    func restoreLastIfNeeded() async {
        guard current == nil, let saved = LastScreenshot.load(),
              Date().timeIntervalSince(saved.date) < 6 * 3600,
              let rules = try? await RulesStore.shared.rules() else { return }
        guard let snapshot = try? DraftAnalyzer.analyze(image: saved.image, rules: rules),
              current == nil else { return }
        publish(snapshot, Recommender.make(from: snapshot, rules: rules), date: saved.date)
    }
}

/// 直近に解析した 1 枚だけを端末内（アプリの書類フォルダ）に置く。外には送らない。
enum LastScreenshot {
    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("last_screenshot.jpg")
    }

    static func save(_ image: CGImage) {
        guard let url, let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImageDestinationImageMaxPixelSize: DraftAnalyzer.workingMaxSide,
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func load() -> (image: CGImage, date: Date)? {
        guard let url,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let image = try? ScreenshotSource.image(atPath: url.path) else { return nil }
        return (image, date)
    }

    static func delete() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

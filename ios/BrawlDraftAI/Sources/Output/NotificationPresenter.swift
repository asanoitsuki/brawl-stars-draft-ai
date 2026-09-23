import Foundation
import UserNotifications

/// 画面上部バナーで結果を出す。
///
/// ブロスタを全画面で遊んでいる最中に割り込む必要があるので、
/// `interruptionLevel = .timeSensitive` を使う（集中モード中でも表示される）。
/// Xcode の Signing & Capabilities で "Time Sensitive Notifications" を有効にすること。
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func registerDelegate() {
        center.delegate = self
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    var authorizationStatus: UNAuthorizationStatus {
        get async { await center.notificationSettings().authorizationStatus }
    }

    /// 結果をバナーとして出す。直前の提案は消してから出す（古い手が残らないように）。
    func present(_ recommendation: Recommendation) async {
        guard AppSettings.notificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = recommendation.title
        content.body = recommendation.caution.map { "\(recommendation.body)\n⚠️ \($0)" }
            ?? recommendation.body
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0
        content.sound = nil  // 読み上げと被るので無音

        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])

        let request = UNNotificationRequest(identifier: Self.identifier,
                                            content: content, trigger: nil)
        try? await center.add(request)
    }

    func presentError(_ message: String) async {
        let content = UNMutableNotificationContent()
        content.title = "ドラフト解析エラー"
        content.body = message
        content.interruptionLevel = .timeSensitive
        try? await center.add(UNNotificationRequest(identifier: Self.identifier + ".error",
                                                    content: content, trigger: nil))
    }

    private static let identifier = "brawldraft.advice"

    // アプリを前面に出したまま使う場合でもバナーを出す
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

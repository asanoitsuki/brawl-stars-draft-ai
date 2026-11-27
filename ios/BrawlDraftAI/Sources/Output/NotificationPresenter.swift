import Foundation
import Intents
import SwiftUI
import UIKit
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
    ///
    /// 提案した 3 体のアイコンを左から並べた画像を付ける（通知を長押しすると大きく出る）。
    /// Personal 構成では、メッセージ通知の形にして 1 位のアイコンをバナーの左端に出す。
    func present(_ recommendation: Recommendation) async {
        guard AppSettings.notificationEnabled else { return }

        // 対戦中に一目で読めるように、順位・名前・勝率だけに絞る（詳しくは通知を開いて画面で見る）
        let isBan = recommendation.phase == .ban
        let heading = recommendation.advices.isEmpty
            ? recommendation.title
            : (isBan ? "BAN おすすめ" : "ピックおすすめ")
        let stage = recommendation.map.map { "\($0.nameJa ?? $0.name)・\($0.modeJa)" }
        let lines = zip(["①", "②", "③"], recommendation.advices).map { mark, a in
            "\(mark) \(a.nameJa ?? a.name)" + (a.winRate.map { "　\(String(format: "%.1f", $0))%" } ?? "")
        }

        let content = UNMutableNotificationContent()
        content.title = heading
        if let stage { content.subtitle = stage }
        content.body = lines.isEmpty ? recommendation.body : lines.joined(separator: "\n")
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1.0
        content.sound = nil  // 読み上げと被るので無音

        let icons = await iconImages(recommendation.advices.prefix(3).map(\.id))
        #if DEBUG
        print("[notify] icons:", icons.count, icons.map(\.size))
        if let strip = Self.iconStrip(icons, isBan: isBan), let d = strip.pngData(),
           let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? d.write(to: dir.appendingPathComponent("last_strip.png"))
        }
        #endif
        if let strip = Self.iconStrip(icons, isBan: isBan),
           let attachment = Self.attachment(strip, name: "picks") {
            content.attachments = [attachment]
        }

        var final: UNNotificationContent = content
        #if REAL_ICONS
        if let first = icons.first {
            let name = ([heading, stage].compactMap { $0 }).joined(separator: "｜")
            if let updated = await Self.asMessage(content, sender: name, avatar: first) { final = updated }
        }
        #endif

        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        let request = UNNotificationRequest(identifier: Self.identifier, content: final, trigger: nil)
        try? await center.add(request)
    }

    // MARK: - アイコン画像

    @MainActor
    private func iconImages(_ ids: [Int]) async -> [UIImage] {
        var images: [UIImage] = []
        for id in ids {
            if let real = await GameArtLoader.image("brawlers/borders/\(id)") {
                images.append(real)
            } else {
                let renderer = ImageRenderer(content: BrawlerIcon(id: id, size: 160))
                renderer.scale = 1
                if let own = renderer.uiImage { images.append(own) }
            }
        }
        return images
    }

    /// アイコンを左から順に並べ、順位の数字を付けた 1 枚の画像を作る。
    private static func iconStrip(_ icons: [UIImage], isBan: Bool) -> UIImage? {
        guard !icons.isEmpty else { return nil }
        let side: CGFloat = 180, gap: CGFloat = 24, pad: CGFloat = 20
        let size = CGSize(width: pad * 2 + side * 3 + gap * 2, height: pad * 2 + side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.08, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let accent = isBan ? UIColor.systemRed : UIColor.systemMint
            for (i, icon) in icons.prefix(3).enumerated() {
                let rect = CGRect(x: pad + CGFloat(i) * (side + gap), y: pad, width: side, height: side)
                let clip = UIBezierPath(roundedRect: rect, cornerRadius: 28)
                ctx.cgContext.saveGState()
                clip.addClip()
                icon.draw(in: rect)
                ctx.cgContext.restoreGState()
                accent.withAlphaComponent(i == 0 ? 1 : 0.5).setStroke()
                clip.lineWidth = i == 0 ? 8 : 4
                clip.stroke()

                let badge = CGRect(x: rect.minX - 8, y: rect.minY - 8, width: 52, height: 52)
                accent.setFill()
                UIBezierPath(ovalIn: badge).fill()
                let label = "\(i + 1)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 32, weight: .black),
                    .foregroundColor: UIColor.black,
                ]
                let textSize = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                           withAttributes: attrs)
            }
        }
    }

    private static func attachment(_ image: UIImage, name: String) -> UNNotificationAttachment? {
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return nil }
        do {
            return try UNNotificationAttachment(identifier: name, url: url, options: nil)
        } catch {
            #if DEBUG
            print("[notify] attachment failed:", error)
            #endif
            return nil
        }
    }

    #if REAL_ICONS
    /// メッセージ通知の形にすると、送り主の画像がバナーの左端に出る。
    private static func asMessage(_ content: UNMutableNotificationContent, sender name: String,
                                  avatar: UIImage) async -> UNNotificationContent? {
        guard let data = avatar.pngData() else { return nil }
        let image = INImage(imageData: data)
        let sender = INPerson(personHandle: INPersonHandle(value: "brawlboard.advice", type: .unknown),
                              nameComponents: nil, displayName: name, image: image,
                              contactIdentifier: nil, customIdentifier: "brawlboard.advice")
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
                                         content: content.body, speakableGroupName: nil,
                                         conversationIdentifier: "brawlboard.draft", serviceName: nil,
                                         sender: sender, attachments: nil)
        intent.setImage(image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return try? content.updating(from: intent)
    }
    #endif

    /// 設定画面の確認用
    func presentTest() async {
        let content = UNMutableNotificationContent()
        content.title = "テスト通知"
        content.body = "解析結果はこの形で出ます。\n◎ キャラ名　55.0%"
        content.interruptionLevel = .timeSensitive
        try? await center.add(UNNotificationRequest(identifier: Self.identifier + ".test",
                                                    content: content, trigger: nil))
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

import CloudKit
import Foundation

/// 募集ごとのチャットの 1 メッセージ。募集を見ている人なら誰でも読める公開チャット。
struct TeamMessage: Identifiable, Equatable {
    let id: CKRecord.ID
    let postRecordName: String
    let text: String
    let senderName: String
    let senderIconID: Int?
    let senderProfile: String?
    let createdAt: Date
    let creatorID: String?

    static let recordType = "TeamMessage"
    static let maxLength = 120

    init?(record: CKRecord) {
        guard let post = record["postRecordName"] as? String,
              let text = record["text"] as? String,
              let created = record["createdAt"] as? Date else { return nil }
        id = record.recordID
        postRecordName = post
        self.text = text
        senderName = record["senderName"] as? String ?? "名無し"
        senderIconID = (record["senderIconID"] as? Int64).map(Int.init)
        senderProfile = record["senderProfile"] as? String
        createdAt = created
        creatorID = record.creatorUserRecordID?.recordName
    }

    #if DEBUG
    init(demo text: String, sender: String, ago: TimeInterval, mine: Bool = false) {
        id = CKRecord.ID(recordName: UUID().uuidString)
        postRecordName = "demo"
        self.text = text
        senderName = sender
        senderIconID = 28000000
        senderProfile = nil
        createdAt = Date().addingTimeInterval(-ago)
        creatorID = mine ? "me" : sender
    }
    #endif
}

/// 1 つの募集のチャット。開いている間だけ数秒ごとに新着を取りに行く。
@MainActor
final class TeamChatStore: ObservableObject {
    @Published private(set) var messages: [TeamMessage] = []
    @Published private(set) var errorText: String?
    @Published private(set) var sending = false
    @Published private(set) var myUserID: String?

    let postRecordName: String

    init(postRecordName: String) {
        self.postRecordName = postRecordName
    }

    func isMine(_ m: TeamMessage) -> Bool {
        if m.creatorID == "me" { return true }
        if let myUserID, m.creatorID == myUserID { return true }
        return false
    }

    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BDA_DEMO"] != nil {
            if messages.isEmpty {
                messages = [TeamMessage(demo: "ミシック帯です！入っていいですか？", sender: "ころね", ago: 120),
                            TeamMessage(demo: "どうぞ！ガスとベル取れる人だと助かる", sender: "あと1人・たった今", ago: 90),
                            TeamMessage(demo: "ガス使えます。いま入ります", sender: "ころね", ago: 40)]
            }
            return
        }
        #endif
        guard Cloud.isEnabled else { return }
        if myUserID == nil { myUserID = await Cloud.myUserRecordName() }
        // 必要な索引: TeamMessage.postRecordName（QUERYABLE）と createdAt（SORTABLE）
        let query = CKQuery(recordType: TeamMessage.recordType,
                            predicate: NSPredicate(format: "postRecordName == %@", postRecordName))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        do {
            let (results, _) = try await Cloud.database.records(matching: query, resultsLimit: 200)
            let blocked = TeamModeration.blockedCreators
            messages = results.compactMap { try? $0.1.get() }
                .compactMap(TeamMessage.init(record:))
                .filter { !blocked.contains($0.creatorID ?? "") }
            errorText = nil
        } catch let error as CKError where error.code == .unknownItem {
            messages = []
        } catch {
            errorText = TeamBoardStore.describe(error)
        }
    }

    /// 送れなかった理由（nil なら送信済み）
    func send(_ raw: String, as profile: PlayerProfile) async -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count <= TeamMessage.maxLength else { return "\(TeamMessage.maxLength)文字までです" }
        if TeamModeration.containsBlockedWord(text) { return "使えない言葉が含まれています" }
        guard Cloud.isEnabled else { return "チャットはまだ使えません" }

        sending = true
        defer { sending = false }
        let record = CKRecord(recordType: TeamMessage.recordType)
        record["postRecordName"] = postRecordName as CKRecordValue
        record["text"] = text as CKRecordValue
        record["senderName"] = (profile.isEmpty ? "名無し" : profile.name) as CKRecordValue
        if let icon = profile.iconID { record["senderIconID"] = Int64(icon) as CKRecordValue }
        if let me = await ProfileStore.shared.myProfileRecordName(), !profile.isEmpty {
            record["senderProfile"] = me as CKRecordValue
        }
        record["createdAt"] = Date() as CKRecordValue
        do {
            _ = try await Cloud.database.save(record)
            await refresh()
            return nil
        } catch {
            return TeamBoardStore.describe(error)
        }
    }

    func report(_ m: TeamMessage, reason: String) async -> Bool {
        guard Cloud.isEnabled else { return false }
        let record = CKRecord(recordType: "TeamReport")
        record["postRecordName"] = postRecordName as CKRecordValue
        record["reportedCreator"] = (m.creatorID ?? "") as CKRecordValue
        record["reason"] = reason as CKRecordValue
        record["snapshot"] = "[chat] \(m.senderName): \(m.text)" as CKRecordValue
        return (try? await Cloud.database.save(record)) != nil
    }

    func block(_ m: TeamMessage) {
        guard let creator = m.creatorID else { return }
        TeamModeration.blockedCreators.insert(creator)
        messages.removeAll { $0.creatorID == creator }
    }
}

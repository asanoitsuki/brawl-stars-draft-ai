import CloudKit
import Foundation

/// チーム募集の 1 投稿。ブロスタ本体の「チームに招待」で作れる招待リンク（またはチームコード）を
/// 共有し、見た人は「参加」を押すとブロスタが開いてそのままチームに入れる。
struct TeamPost: Identifiable, Equatable {
    enum Purpose: String, CaseIterable, Identifiable {
        case ranked, trophy, casual, club
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ranked: return "ガチバトル"
            case .trophy: return "トロフィー上げ"
            case .casual: return "まったり"
            case .club: return "クラブ勧誘"
            }
        }
    }

    /// ガチバトルのランク帯（ブロンズ〜プロ）
    static let ranks = ["指定なし", "ブロンズ", "シルバー", "ゴールド", "ダイヤモンド", "ミシック", "レジェンド", "マスター", "プロ"]

    let id: CKRecord.ID
    var playerName: String
    var purpose: Purpose
    /// rules.json の英語モードキー。空 = 指定なし
    var mode: String
    var rank: Int
    /// あと何人ほしいか（1〜2）
    var slots: Int
    var comment: String
    /// ブロスタの招待リンク（https://link.brawlstars.com/...）
    var inviteURL: String?
    /// リンクではなくチームコードだけ貼られた場合
    var teamCode: String?
    var createdAt: Date
    var expiresAt: Date
    /// 投稿者（ブロック用）。自分の投稿かどうかの判定にも使う
    var creatorID: String?
    /// 投稿者のプロフィール（Profile レコード名）。タップで詳しく見られる
    var profileRecordName: String? = nil
    /// 投稿時点のプロフィールの写し（一覧で毎回プロフィールを引かずに済むように）
    var iconID: Int? = nil
    var trophies: Int? = nil
    /// 投稿者のガチバトル最高ランク（RankTier）
    var highestRank: Int? = nil
    /// Discord のサーバー招待やボイスチャンネルのリンク
    var discordURL: String? = nil
    /// 参加条件（nil = 条件なし）。最低トロフィーと、ガチバトル最高ランクの下限（RankTier）
    var minTrophies: Int? = nil
    var minRank: Int? = nil

    /// このプロフィールの人が条件を満たすか。満たさない理由を返す（nil = 参加できる）
    func unmetCondition(for p: PlayerProfile) -> String? {
        if let min = minTrophies, (p.trophies ?? 0) < min {
            return "トロフィー \(min.formatted()) 以上が条件です"
        }
        if let min = minRank, min > 0, (p.highestRank ?? 0) < min {
            return "最高ランク \(RankTier.label(min)) 以上が条件です"
        }
        return nil
    }

    static let trophyThresholds = [5_000, 10_000, 20_000, 30_000, 40_000, 50_000, 60_000, 70_000, 80_000, 90_000]

    var isExpired: Bool { expiresAt < Date() }

    static let recordType = "TeamPost"
    /// 募集の有効時間。ブロスタのチームは放置するとすぐ解散するので短めにする。
    static let lifetime: TimeInterval = 20 * 60
}

extension TeamPost {
    init?(record: CKRecord) {
        guard let name = record["playerName"] as? String,
              let created = record["createdAt"] as? Date,
              let expires = record["expiresAt"] as? Date else { return nil }
        self.id = record.recordID
        self.playerName = name
        self.purpose = Purpose(rawValue: record["purpose"] as? String ?? "") ?? .casual
        self.mode = record["mode"] as? String ?? ""
        self.rank = (record["rank"] as? Int64).map(Int.init) ?? 0
        self.slots = (record["slots"] as? Int64).map(Int.init) ?? 1
        self.comment = record["comment"] as? String ?? ""
        self.inviteURL = record["inviteURL"] as? String
        self.teamCode = record["teamCode"] as? String
        self.createdAt = created
        self.expiresAt = expires
        self.creatorID = record.creatorUserRecordID?.recordName
        self.profileRecordName = record["profileRecordName"] as? String
        self.iconID = (record["iconID"] as? Int64).map(Int.init)
        self.trophies = (record["trophies"] as? Int64).map(Int.init)
        self.highestRank = (record["highestRank"] as? Int64).map(Int.init)
        self.discordURL = record["discordURL"] as? String
        self.minTrophies = (record["minTrophies"] as? Int64).map(Int.init)
        self.minRank = (record["minRank"] as? Int64).map(Int.init)
    }

    func makeRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["playerName"] = playerName as CKRecordValue
        record["purpose"] = purpose.rawValue as CKRecordValue
        record["mode"] = mode as CKRecordValue
        record["rank"] = Int64(rank) as CKRecordValue
        record["slots"] = Int64(slots) as CKRecordValue
        record["comment"] = comment as CKRecordValue
        if let inviteURL { record["inviteURL"] = inviteURL as CKRecordValue }
        if let teamCode { record["teamCode"] = teamCode as CKRecordValue }
        record["createdAt"] = createdAt as CKRecordValue
        record["expiresAt"] = expiresAt as CKRecordValue
        if let profileRecordName { record["profileRecordName"] = profileRecordName as CKRecordValue }
        if let iconID { record["iconID"] = Int64(iconID) as CKRecordValue }
        if let trophies { record["trophies"] = Int64(trophies) as CKRecordValue }
        if let highestRank, highestRank > 0 { record["highestRank"] = Int64(highestRank) as CKRecordValue }
        if let discordURL { record["discordURL"] = discordURL as CKRecordValue }
        if let minTrophies { record["minTrophies"] = Int64(minTrophies) as CKRecordValue }
        if let minRank, minRank > 0 { record["minRank"] = Int64(minRank) as CKRecordValue }
        return record
    }
}

// MARK: - 招待リンクの読み取り

enum TeamInvite {
    /// 貼り付けられた文章（ブロスタの「招待リンクを共有」の文面そのままでもよい）から
    /// 招待リンクかチームコードを取り出す。
    static func parse(_ text: String) -> (url: String?, code: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"https?://link\.brawlstars\.com/\S+"#, options: .regularExpression) {
            let url = String(trimmed[range]).trimmingCharacters(in: CharacterSet(charactersIn: "」』)）。、"))
            let code = URLComponents(string: url)?.queryItems?.first { $0.name == "tag" }?.value
            return (url, code)
        }
        let upper = trimmed.uppercased().replacingOccurrences(of: "#", with: "")
        if upper.range(of: #"^[A-Z0-9]{5,12}$"#, options: .regularExpression) != nil {
            return (nil, upper)
        }
        return (nil, nil)
    }

    /// 参加ボタンで開く URL。リンクがあればそれ、コードだけならブロスタのチーム招待リンクを組み立てる。
    static func joinURL(for post: TeamPost) -> URL? {
        if let s = post.inviteURL, let url = URL(string: s) { return url }
        if let code = post.teamCode {
            return URL(string: "https://link.brawlstars.com/invite/gameroom/ja?tag=\(code)")
        }
        return nil
    }

    /// Discord のリンクとして受け付けるもの（サーバー招待・チャンネル・アプリ内リンク）
    static func discordURL(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"https?://(discord\.gg|discord\.com|discordapp\.com)/\S+"#,
                                        options: .regularExpression) else { return nil }
        return String(trimmed[range])
    }
}

// MARK: - 不適切な投稿の対策（App Store ガイドライン 1.2: フィルタ・通報・ブロック）

enum TeamModeration {
    /// 明らかな暴言・出会い目的・外部誘導だけを弾く最小限のリスト。
    private static let blockedWords = [
        "死ね", "しね", "殺す", "ころす", "きもい", "キモい", "ガイジ", "がいじ", "カス", "ゴミ",
        "fuck", "shit", "LINE交換", "ライン交換", "line.me", "出会い", "援交", "パパ活",
    ]

    static func containsBlockedWord(_ text: String) -> Bool {
        let lower = text.lowercased()
        return blockedWords.contains { lower.contains($0.lowercased()) }
    }

    private static let blockedKey = "teamBlockedCreators"

    static var blockedCreators: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: blockedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: blockedKey) }
    }
}

// MARK: - CloudKit とのやり取り

@MainActor
final class TeamBoardStore: ObservableObject {
    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    @Published private(set) var posts: [TeamPost] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var myPostID: CKRecord.ID?
    @Published private(set) var canPost = false
    @Published private(set) var accountMessage: String?

    static var isCloudEnabled: Bool { Cloud.isEnabled }

    private var container: CKContainer { Cloud.container }
    private var database: CKDatabase { Cloud.database }
    private var myUserID: String?

    private static let myPostKey = "teamMyPostRecordName"

    init() {
        if let name = UserDefaults.standard.string(forKey: Self.myPostKey) {
            myPostID = CKRecord.ID(recordName: name)
        }
    }

    func checkAccount() async {
        guard Self.isCloudEnabled else {
            canPost = false
            accountMessage = nil
            return
        }
        do {
            switch try await container.accountStatus() {
            case .available:
                canPost = true
                accountMessage = nil
                myUserID = await Cloud.myUserRecordName()
            case .noAccount:
                canPost = false
                accountMessage = "投稿するには iPhone の設定で iCloud にサインインしてください（見るだけならそのまま使えます）"
            case .restricted, .couldNotDetermine, .temporarilyUnavailable:
                canPost = false
                accountMessage = "iCloud が使えないため、いまは投稿できません"
            @unknown default:
                canPost = false
            }
        } catch {
            canPost = false
            accountMessage = "iCloud の状態を確認できませんでした"
        }
    }

    func refresh() async {
        #if DEBUG
        // 見た目確認用: BDA_DEMO=1 で起動するとダミーの募集を表示する（iCloud を使わない）
        if ProcessInfo.processInfo.environment["BDA_DEMO"] != nil {
            let now = Date()
            func demo(_ n: String, _ purpose: TeamPost.Purpose, _ slots: Int, _ ago: TimeInterval, _ c: String) -> TeamPost {
                TeamPost(id: CKRecord.ID(recordName: n), playerName: n, purpose: purpose, mode: "Gem Grab",
                         rank: 5, slots: slots, comment: c, inviteURL: nil, teamCode: "ABC12345",
                         createdAt: now.addingTimeInterval(-ago), expiresAt: now.addingTimeInterval(900),
                         creatorID: nil, profileRecordName: "demo", iconID: 28000000, trophies: 38_420,
                         highestRank: slots == 1 ? 20 : 15, discordURL: "https://discord.gg/example")
            }
            var strict = demo("条件あり・たった今", .ranked, 1, 20, "プロ目指してる人")
            strict.minTrophies = 60_000
            strict.minRank = 19
            posts = [strict,
                     demo("あと1人・たった今", .ranked, 1, 5, "ミシック帯 VCなし"),
                     demo("あと2人・たった今", .trophy, 2, 5, "トロ上げ行こう"),
                     demo("あと2人・5分前", .casual, 2, 300, "まったり"),
                     demo("あと1人・5分前", .ranked, 1, 300, "あと1人で出発")]
            loadState = .loaded
            return
        }
        #endif
        guard Self.isCloudEnabled else {
            loadState = .failed("チーム募集はサーバー（iCloud）の準備中です。もうしばらくお待ちください")
            return
        }
        if loadState != .loaded { loadState = .loading }
        // expiresAt だけで絞り込み・並び替えするので、CloudKit 側に必要な索引は
        // TeamPost.expiresAt の Queryable と Sortable の 2 つだけ。
        let query = CKQuery(recordType: TeamPost.recordType,
                            predicate: NSPredicate(format: "expiresAt > %@", Date() as NSDate))
        query.sortDescriptors = [NSSortDescriptor(key: "expiresAt", ascending: false)]
        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 100)
            let blocked = TeamModeration.blockedCreators
            posts = results.compactMap { try? $0.1.get() }
                .compactMap(TeamPost.init(record:))
                .filter { !$0.isExpired && !blocked.contains($0.creatorID ?? "") }
            if let myPostID, !posts.contains(where: { $0.id == myPostID }) {
                clearMyPost()   // 期限切れで一覧から消えた
            }
            loadState = .loaded
        } catch let error as CKError where error.code == .unknownItem {
            // まだ 1 件も投稿されていない（レコード型が未作成）
            posts = []
            loadState = .loaded
        } catch {
            loadState = .failed(Self.describe(error))
        }
    }

    func isMine(_ post: TeamPost) -> Bool {
        if post.id == myPostID { return true }
        if let myUserID, post.creatorID == myUserID { return true }
        return false
    }

    /// 1 人 1 件まで。新しく出すと前の募集は消す。
    func publish(_ draft: TeamPost) async throws {
        guard Self.isCloudEnabled else { throw CKError(.missingEntitlement) }
        if let old = myPostID {
            _ = try? await database.deleteRecord(withID: old)
        }
        let saved = try await database.save(draft.makeRecord())
        myPostID = saved.recordID
        UserDefaults.standard.set(saved.recordID.recordName, forKey: Self.myPostKey)
        await refresh()
    }

    func closeMyPost() async {
        guard Self.isCloudEnabled, let id = myPostID else { return }
        _ = try? await database.deleteRecord(withID: id)
        clearMyPost()
        posts.removeAll { $0.id == id }
    }

    func report(_ post: TeamPost, reason: String) async -> Bool {
        guard Self.isCloudEnabled else { return false }
        let record = CKRecord(recordType: "TeamReport")
        record["postRecordName"] = post.id.recordName as CKRecordValue
        record["reportedCreator"] = (post.creatorID ?? "") as CKRecordValue
        record["reason"] = reason as CKRecordValue
        record["snapshot"] = "\(post.playerName): \(post.comment)" as CKRecordValue
        do {
            _ = try await database.save(record)
            return true
        } catch {
            return false
        }
    }

    func block(_ post: TeamPost) {
        guard let creator = post.creatorID else { return }
        TeamModeration.blockedCreators.insert(creator)
        posts.removeAll { $0.creatorID == creator }
    }

    private func clearMyPost() {
        myPostID = nil
        UserDefaults.standard.removeObject(forKey: Self.myPostKey)
    }

    static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .networkUnavailable, .networkFailure:
            return "ネットワークに接続できません"
        case .notAuthenticated:
            return "iCloud にサインインしてください"
        case .badContainer, .missingEntitlement:
            return "募集サーバー（iCloud コンテナ）がまだ用意されていません"
        case .invalidArguments where ck.localizedDescription.contains("queryable")
                                  || ck.localizedDescription.contains("sortable"):
            return "募集サーバーの初期設定が未完了です（CloudKit の索引 expiresAt が未作成）"
        case .quotaExceeded, .requestRateLimited, .zoneBusy, .serviceUnavailable:
            return "混み合っています。少し待ってから更新してください"
        default:
            return "読み込みに失敗しました（\(ck.code.rawValue)）"
        }
    }
}

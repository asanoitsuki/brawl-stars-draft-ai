import CloudKit
import Foundation

/// CloudKit 公開データベースへの共通の入口。チーム募集・プロフィール・チャットが共有する。
enum Cloud {
    /// CloudKit を有効にしたビルドか（Local.xcconfig の BDA_SWIFT_FLAGS = CLOUDKIT_ENABLED）。
    /// iCloud の権限が無いビルドで CKContainer.default() に触るとアプリが落ちるため、
    /// 無効なビルドではコンテナに一切触れない。
    static var isEnabled: Bool {
        #if CLOUDKIT_ENABLED
        return true
        #else
        return false
        #endif
    }

    static var container: CKContainer { CKContainer.default() }
    static var database: CKDatabase { container.publicCloudDatabase }

    @MainActor private static var cachedUserRecordName: String?

    /// この端末の iCloud ユーザーの匿名 ID。サインインしていなければ nil。
    @MainActor
    static func myUserRecordName() async -> String? {
        guard isEnabled else { return nil }
        if let cachedUserRecordName { return cachedUserRecordName }
        let name = try? await container.userRecordID().recordName
        cachedUserRecordName = name
        return name
    }
}

/// 自分のブロスタのプロフィール。プレイヤータグから公式 API の値を自動で埋め、
/// フレンド招待リンク・Discord・ひとことは自分で足す。
struct PlayerProfile: Codable, Equatable {
    struct TopBrawler: Codable, Equatable, Identifiable {
        var id: Int
        var name: String
        var power: Int?
        var rank: Int?
        var trophies: Int?
    }

    var tag: String = ""
    var name: String = ""
    var iconID: Int?
    var trophies: Int?
    var highestTrophies: Int?
    var expLevel: Int?
    var trioVictories: Int?
    var soloVictories: Int?
    var duoVictories: Int?
    var club: String?
    var brawlerCount: Int?
    var topBrawlers: [TopBrawler] = []
    /// ブロスタの「フレンド招待」リンク。開くと相手にフレンド申請が飛ぶ。
    var friendLink: String?
    var discordName: String?
    var discordInvite: String?
    var bio: String = ""
    /// 旧版の自己申告ランク帯（TeamPost.ranks の添字）。今は highestRank を使う
    var rank: Int = 0
    var fetchedAt: Date?
    /// ガチバトルの最高ランク（RankTier: 1 = ブロンズⅠ … 22 = プロ）。古い保存データには無いので任意
    var highestRank: Int?
    /// ガチバトルのポイント（最高 / 現在）。Brawl Insights などの画像から読めたときだけ入る
    var rankedHighest: Int?
    var rankedCurrent: Int?
    /// 全キャラのトロフィー（プロフィール画像用）。公式 API から取れたときだけ入る
    var brawlers: [TopBrawler]?

    var isEmpty: Bool { name.isEmpty }
    /// 募集に出せる状態か（名前とタグがそろっている）
    var isComplete: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && tag.count >= 4 }

    /// ブロスタのプロフィールアイコン画像（Brawlify の CDN）
    var iconURL: URL? { iconID.flatMap(PlayerProfile.iconURL(for:)) }

    static func iconURL(for id: Int) -> URL? {
        URL(string: "https://cdn.brawlify.com/profile-icons/regular/\(id).png")
    }
}

// MARK: - 入力の読み取り

enum ProfileLink {
    /// 貼り付けられた文字（ブロスタの「フレンド招待」の文面・リンク・タグ）から
    /// タグとフレンド招待リンクを取り出す。
    static func parse(_ text: String) -> (tag: String?, friendLink: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"https?://link\.brawlstars\.com/\S+"#, options: .regularExpression) {
            let url = String(trimmed[range]).trimmingCharacters(in: CharacterSet(charactersIn: "」』)）。、"))
            let tag = URLComponents(string: url)?.queryItems?.first { $0.name == "tag" }?.value
            let isFriend = url.contains("/friend")
            return (tag.map(normalize), isFriend ? url : nil)
        }
        let cleaned = normalize(trimmed)
        if cleaned.range(of: #"^#[0289PYLQGRJCUV]{3,14}$"#, options: .regularExpression) != nil {
            return (cleaned, nil)
        }
        return (nil, nil)
    }

    /// "#abc o12" → "#ABC012"（O と 0 の打ち間違いを寄せる）
    static func normalize(_ tag: String) -> String {
        let core = tag.uppercased()
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "O", with: "0")
        return "#" + core
    }
}

// MARK: - 公式 API（Vercel の中継関数経由）

enum ProfileAPI {
    enum LookupError: LocalizedError {
        case invalidTag, notFound, notConfigured, rateLimited, network, server(Int)

        var errorDescription: String? {
            switch self {
            case .invalidTag: return "タグの形式が正しくありません（例: #2PP0Y8LQ）"
            case .notFound: return "このタグのプレイヤーが見つかりません"
            case .notConfigured: return "自動取得サーバーの準備中です。プロフィール画面のスクショか手入力で作れます"
            case .rateLimited: return "混み合っています。少し待ってからもう一度試してください"
            case .network: return "サーバーに接続できません"
            case .server(let code): return "取得に失敗しました（\(code)）"
            }
        }
    }

    private struct Response: Decodable {
        let tag: String
        let name: String
        let iconId: Int?
        let trophies: Int?
        let highestTrophies: Int?
        let expLevel: Int?
        let trioVictories: Int?
        let soloVictories: Int?
        let duoVictories: Int?
        let club: String?
        let brawlerCount: Int?
        let topBrawlers: [PlayerProfile.TopBrawler]
        let brawlers: [PlayerProfile.TopBrawler]?
    }

    /// タグから公式のプロフィールを取り、既存のプロフィールの「自分で足した部分」は残して上書きする。
    static func lookup(tag: String, into base: PlayerProfile) async throws -> PlayerProfile {
        let core = ProfileLink.normalize(tag).dropFirst()
        guard !core.isEmpty,
              var components = URLComponents(string: AppSettings.profileAPIBase + "/api/player") else {
            throw LookupError.invalidTag
        }
        components.queryItems = [URLQueryItem(name: "tag", value: String(core))]
        guard let url = components.url else { throw LookupError.invalidTag }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LookupError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 自分たちのサーバーは必ず {"error": ...} の JSON で返す。それ以外の 404 は
        // 「サーバー自体がまだ無い」（Vercel の DEPLOYMENT_NOT_FOUND など）なので、
        // 「タグが見つからない」と取り違えないよう区別する。
        let serverError = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch status {
        case 200: break
        case 400: throw LookupError.invalidTag
        case 404 where serverError == "not_found": throw LookupError.notFound
        case 404: throw LookupError.notConfigured
        case 429: throw LookupError.rateLimited
        case 503: throw LookupError.notConfigured
        default: throw LookupError.server(status)
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        var p = base
        p.tag = r.tag
        p.name = r.name
        p.iconID = r.iconId
        p.trophies = r.trophies
        p.highestTrophies = r.highestTrophies
        p.expLevel = r.expLevel
        p.trioVictories = r.trioVictories
        p.soloVictories = r.soloVictories
        p.duoVictories = r.duoVictories
        p.club = r.club
        p.brawlerCount = r.brawlerCount
        p.topBrawlers = r.topBrawlers
        if let all = r.brawlers, !all.isEmpty { p.brawlers = all }
        p.fetchedAt = Date()
        return p
    }
}

// MARK: - 保存（端末 + iCloud 公開データベース）

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var me: PlayerProfile

    private static let localKey = "myPlayerProfile"
    static let recordType = "Profile"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.localKey),
           let saved = try? JSONDecoder().decode(PlayerProfile.self, from: data) {
            me = saved
        } else {
            me = PlayerProfile()
        }
        #if DEBUG
        // 見た目確認用: BDA_DEMO_PROFILE=1 で起動するとサンプルのプロフィールを入れる
        if ProcessInfo.processInfo.environment["BDA_DEMO_PROFILE"] != nil {
            let all = (0..<48).map { i in
                PlayerProfile.TopBrawler(id: 16_000_000 + i, name: "B\(i)", power: 11, rank: 30,
                                         trophies: max(200, 2402 - i * 45))
            }
            me = PlayerProfile(tag: "#PCJJPRP", name: "7位傀儡", iconID: 28000000, trophies: 83_845,
                               highestTrophies: 83_845, trioVictories: 17_485, club: "worthwhile",
                               brawlerCount: 48, topBrawlers: Array(all.prefix(5)), bio: "ガチバトル毎日やってます",
                               highestRank: 20, rankedHighest: 9294, rankedCurrent: 6304, brawlers: all)
        }
        #endif
    }

    /// 端末に保存し、iCloud にも公開する（募集を見た人がプロフィールを開けるように）。
    func save(_ profile: PlayerProfile) async throws {
        me = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.localKey)
        }
        guard Cloud.isEnabled, let recordName = await myProfileRecordName() else { return }
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: recordName))
        record["name"] = profile.name as CKRecordValue
        record["tag"] = profile.tag as CKRecordValue
        record["json"] = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self) as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        _ = try await Cloud.database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    /// 自分のプロフィールのレコード名（iCloud のユーザー ID から決まる。ID で直接引けるので索引が要らない）
    func myProfileRecordName() async -> String? {
        guard let user = await Cloud.myUserRecordName() else { return nil }
        return Self.recordName(forUser: user)
    }

    static func recordName(forUser user: String) -> String { "profile-\(user)" }

    /// 他の人のプロフィールを取る。
    static func fetch(recordName: String, fallbackName: String = "") async -> PlayerProfile? {
        #if DEBUG
        // 見た目確認用（BDA_DEMO=1）
        if ProcessInfo.processInfo.environment["BDA_DEMO"] != nil {
            return PlayerProfile(tag: "#2PP0Y8LQ", name: fallbackName, iconID: 28000000, trophies: 38_420,
                                 highestTrophies: 41_002, trioVictories: 12_340, club: "Brawl Board JP",
                                 topBrawlers: [.init(id: 16000000, name: "SHELLY", trophies: 1250),
                                               .init(id: 16000001, name: "COLT", trophies: 1180),
                                               .init(id: 16000002, name: "BULL", trophies: 1102)],
                                 friendLink: "https://link.brawlstars.com/invite/friend/ja?tag=2PP0Y8LQ",
                                 discordName: "brawler_jp", bio: "ミシック帯。ガス・ベル得意", rank: 5, highestRank: 20)
        }
        #endif
        guard Cloud.isEnabled else { return nil }
        guard let record = try? await Cloud.database.record(for: CKRecord.ID(recordName: recordName)),
              let json = record["json"] as? String else { return nil }
        return try? JSONDecoder().decode(PlayerProfile.self, from: Data(json.utf8))
    }
}

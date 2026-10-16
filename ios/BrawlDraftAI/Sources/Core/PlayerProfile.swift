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
    /// 1 キャラの状態（公式 API の brawlers[] から）。古い保存データには無い項目が多いので全部任意。
    struct TopBrawler: Codable, Equatable, Identifiable {
        var id: Int
        var name: String
        var power: Int?
        /// キャラのランク（プレステージ）
        var rank: Int?
        var trophies: Int?
        var highestTrophies: Int?
        var gears: Int?
        var gadgets: Int?
        var starPowers: Int?
        var hyperCharges: Int?
        var buffies: Int?
    }

    var tag: String = ""
    var name: String = ""
    var iconID: Int?
    var trophies: Int?
    var highestTrophies: Int?
    var expLevel: Int?
    var expPoints: Int?
    var trioVictories: Int?
    var soloVictories: Int?
    var duoVictories: Int?
    var club: String?
    var brawlerCount: Int?
    var topBrawlers: [TopBrawler] = []
    /// ロボットパニックの最高記録（秒）/ ビッグブロウラーの最高時間（秒）。公式 API に項目があるとき
    var bestRoboRumbleTime: Int?
    var bestTimeAsBigBrawler: Int?
    /// 公式 API が返した、アプリがまだ名前を知らない項目（ガチバトルのレートなどが追加されたとき用）。
    /// 値は文字列にして持ち、プロフィールの「公式のその他の項目」に出す。
    var officialExtra: [String: String]?
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

    /// 育成状況（公式の brawlers[] から集計）。全キャラ分が取れていないときは nil
    var growth: Growth? {
        guard let list = brawlers, !list.isEmpty else { return nil }
        func total(_ key: KeyPath<TopBrawler, Int?>) -> Int? {
            let values = list.compactMap { $0[keyPath: key] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        let powers = list.compactMap(\.power)
        return Growth(
            owned: list.count,
            gadgets: total(\.gadgets), starPowers: total(\.starPowers), gears: total(\.gears),
            hyperCharges: total(\.hyperCharges), buffies: total(\.buffies),
            power11: powers.filter { $0 >= 11 }.count,
            averagePower: powers.isEmpty ? nil : Double(powers.reduce(0, +)) / Double(powers.count),
            highestBrawlerTrophies: list.compactMap(\.highestTrophies).max()
        )
    }

    struct Growth: Equatable {
        let owned: Int
        let gadgets: Int?
        let starPowers: Int?
        let gears: Int?
        let hyperCharges: Int?
        let buffies: Int?
        let power11: Int
        let averagePower: Double?
        let highestBrawlerTrophies: Int?
    }

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
        case invalidTag, notFound, notConfigured, maintenance, rateLimited, network, server(Int)

        var errorDescription: String? {
            switch self {
            case .invalidTag: return "タグの形式が正しくありません（例: #2PP0Y8LQ）"
            case .notFound: return "このタグのプレイヤーが見つかりません"
            case .notConfigured: return "自動取得サーバーが未設定です。プロフィール画面のスクショから作れます"
            case .maintenance: return "ブロスタ公式がメンテナンス中です。終わってからもう一度試してください（画像からは作れます）"
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
        let expPoints: Int?
        let trioVictories: Int?
        let soloVictories: Int?
        let duoVictories: Int?
        let bestRoboRumbleTime: Int?
        let bestTimeAsBigBrawler: Int?
        let club: String?
        let brawlerCount: Int?
        let topBrawlers: [PlayerProfile.TopBrawler]
        let brawlers: [PlayerProfile.TopBrawler]?
        let extra: [String: JSONScalar]?
    }

    /// extra に来る値を「文字列にできるもの」だけ受ける（入れ子は無視）
    private enum JSONScalar: Decodable {
        case text(String)
        case none

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(String.self) { self = .text(v) }
            else if let v = try? c.decode(Int.self) { self = .text(String(v)) }
            else if let v = try? c.decode(Double.self) { self = .text(String(v)) }
            else if let v = try? c.decode(Bool.self) { self = .text(v ? "はい" : "いいえ") }
            else { self = .none }
        }
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
        case 503 where serverError == "maintenance": throw LookupError.maintenance
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
        p.expPoints = r.expPoints
        p.bestRoboRumbleTime = r.bestRoboRumbleTime
        p.bestTimeAsBigBrawler = r.bestTimeAsBigBrawler
        if let extra = r.extra {
            var flat: [String: String] = [:]
            for (k, v) in extra { if case .text(let t) = v { flat[k] = t } }
            p.officialExtra = flat.isEmpty ? nil : flat
        }
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
                                         trophies: max(200, 2402 - i * 45), highestTrophies: 2500 - i * 40,
                                         gears: 2, gadgets: 2, starPowers: 2, hyperCharges: 1, buffies: 3)
            }
            me = PlayerProfile(tag: "#PCJJPRP", name: "7位傀儡", iconID: 28000000, trophies: 83_845,
                               highestTrophies: 83_845, expLevel: 40, expPoints: 33_680,
                               trioVictories: 17_485, soloVictories: 10_594, duoVictories: 4_734, club: "worthwhile",
                               brawlerCount: 48, topBrawlers: Array(all.prefix(5)), bio: "ガチバトル毎日やってます",
                               highestRank: 20, rankedHighest: 9294, rankedCurrent: 6304, brawlers: all)
        }
        #endif
    }

    /// 公式の最新の値に更新する。アプリを開いたときに呼び、前回から 3 時間以内なら何もしない。
    /// 名前・トロフィーなどの公式の値は、自分では書き換えられず、ここでだけ変わる。
    func refreshFromOfficial(force: Bool = false) async {
        guard me.isComplete else { return }
        if !force, let last = me.fetchedAt, Date().timeIntervalSince(last) < 3 * 3600 { return }
        guard var latest = try? await ProfileAPI.lookup(tag: me.tag, into: me) else { return }
        // 公式の項目が新しく取れなかった場合に備え、画像から読んだ値は残す
        latest.highestRank = me.highestRank
        latest.rankedHighest = me.rankedHighest
        latest.rankedCurrent = me.rankedCurrent
        try? await save(latest)
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

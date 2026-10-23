import CoreGraphics
import Foundation

/// 解析に必要なものを全部束ねた、読み込み済みの状態。
struct LoadedRules {
    let document: RulesDocument
    let mapsByID: [Int: MapRules]
    let roleByName: [String: String]
    let roleByID: [Int: String]
    let nameByID: [Int: String]
    /// キャラアイコンの照合器
    let brawlerMatcher: TemplateMatcher
    /// マップ画像の照合器（マップ名の OCR をしないで済むようにするため）
    let mapMatcher: TemplateMatcher
    let mapIDByMatcherIndex: [Int: Int]
    /// マップ日本語名 -> マップ ID。ブラインドピック画面のステージ名 OCR に使う。
    /// キーはマッチング用に空白除去済み。
    let mapIDByJapaneseName: [String: Int]
    let origin: Origin

    enum Origin: String {
        case bundled = "アプリ同梱"
        case cached = "ダウンロード済みキャッシュ"
        case remote = "サーバーから取得"
    }

    var generatedAt: String { document.generatedAt }
    var hasLiveStats: Bool { document.dataQuality.liveStats }

    func map(id: Int) -> MapRules? { mapsByID[id] }
    func role(of name: String) -> String? { roleByName[name] }
    func japaneseRole(_ role: String) -> String { document.archetypes[role] ?? role }
    func roleTip(_ role: String) -> String? { document.roleTips[role] }

    /// OCR で読んだテキストに含まれるマップ名を探す（完全一致 → 部分一致の順）。
    func findMap(inOCRText text: String) -> MapRules? {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        if let id = mapIDByJapaneseName[cleaned] { return mapsByID[id] }
        for (name, id) in mapIDByJapaneseName where cleaned.contains(name) {
            return mapsByID[id]
        }
        return nil
    }

    func advantage(_ mine: String, vs enemy: String) -> Double {
        document.advantage[mine]?[enemy] ?? 0
    }

    func synergy(_ mine: String, with ally: String) -> Double {
        document.synergy[mine]?[ally] ?? 0
    }

    /// 実測の対面相性。delta は「素の強さの差」を除いた相性（%pt）。データが無ければ nil。
    func matchup(_ mine: Int, vs enemy: Int) -> PairStat? {
        guard mine != enemy else { return nil }
        let (lo, hi) = mine < enemy ? (mine, enemy) : (enemy, mine)
        guard let row = document.matchups?.vs["\(lo)-\(hi)"], row.count >= 3 else { return nil }
        return mine == lo
            ? PairStat(delta: row[0], winRate: row[1], games: Int(row[2]))
            : PairStat(delta: -row[0], winRate: 100 - row[1], games: Int(row[2]))
    }

    /// 実測の同チーム相性（対称）。
    func duo(_ a: Int, _ b: Int) -> PairStat? {
        guard a != b else { return nil }
        let (lo, hi) = a < b ? (a, b) : (b, a)
        guard let row = document.matchups?.with["\(lo)-\(hi)"], row.count >= 3 else { return nil }
        return PairStat(delta: row[0], winRate: row[1], games: Int(row[2]))
    }

    struct PairStat {
        let delta: Double
        let winRate: Double
        let games: Int
    }

    /// 実測データの鮮度（時間）。実測が無ければ nil。
    var statsAgeHours: Double? {
        guard let s = document.dataQuality.statsUpdatedAt,
              let date = ISO8601DateFormatter().date(from: s) else { return nil }
        return Date().timeIntervalSince(date) / 3600
    }
}

/// rules.json / templates.json の読み込み・キャッシュ・更新を一手に引き受ける。
///
/// 0.5 秒以内に返すため、**判定の直前には一切 I/O をしない**。
/// アプリ起動時（およびショートカットからの初回呼び出し時）にここで全部メモリへ載せる。
@MainActor
final class RulesStore: ObservableObject {
    static let shared = RulesStore()

    enum State {
        case idle
        case loading
        case ready(LoadedRules)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastRefreshMessage: String?

    private var loadTask: Task<LoadedRules, Error>?

    private init() {}

    var loaded: LoadedRules? {
        if case .ready(let r) = state { return r }
        return nil
    }

    /// 起動直後に呼ぶ。すでに読み込み済みなら何もしない。
    func preload() {
        _ = ensureLoadTask()
    }

    /// 読み込み完了を待つ。Intent からはこれを await する。
    @discardableResult
    func rules() async throws -> LoadedRules {
        if let loaded { return loaded }
        return try await ensureLoadTask().value
    }

    private func ensureLoadTask() -> Task<LoadedRules, Error> {
        if let loadTask { return loadTask }
        state = .loading
        let task = Task<LoadedRules, Error> {
            let result = try await Self.loadEverything()
            await MainActor.run { self.state = .ready(result) }
            return result
        }
        loadTask = task
        Task {
            do { _ = try await task.value }
            catch { self.state = .failed(error.localizedDescription) }
        }
        return task
    }

    /// サーバー上の最新 rules.json を取り込む。失敗しても既存データは壊さない。
    func refreshFromRemote(force: Bool = false) async {
        guard AppSettings.isRulesURLConfigured else {
            lastRefreshMessage = "rules.json の URL が未設定です（設定画面で指定してください）"
            return
        }
        guard force || AppSettings.needsRefresh else { return }
        guard let url = URL(string: AppSettings.rulesURL) else { return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastRefreshMessage = "サーバーから取得できませんでした"
                return
            }
            // 壊れたデータで上書きしないよう、先にデコードして検証する
            let document = try JSONDecoder().decode(RulesDocument.self, from: data)
            guard document.schema == 2, !document.maps.isEmpty else {
                lastRefreshMessage = "受け取った rules.json の形式が想定と違います"
                return
            }
            // CDN の古いキャッシュなどで「今より古いデータ」が返ってきたら採用しない
            if let current = loaded, document.generatedAt < current.generatedAt {
                AppSettings.lastRefreshAt = Date()
                lastRefreshMessage = "最新です（生成 \(Self.displayDate(current.generatedAt))）"
                return
            }
            try data.write(to: Self.cacheURL, options: .atomic)
            AppSettings.lastRefreshAt = Date()

            let pack = try Self.loadTemplatePack()
            let built = try Self.build(document: document, pack: pack, origin: .remote)
            state = .ready(built)
            lastRefreshMessage = "更新しました（生成 \(Self.displayDate(document.generatedAt))）"
        } catch {
            lastRefreshMessage = "更新に失敗: \(error.localizedDescription)"
        }
    }

    /// "2026-10-14T08:52:10+00:00" → "10/14 17:52"（端末のタイムゾーン）
    nonisolated static func displayDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d H:mm"
        return f.string(from: date)
    }

    // MARK: - 読み込み本体

    nonisolated static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("rules_cache.json")
    }

    nonisolated private static func loadEverything() async throws -> LoadedRules {
        try await Task.detached(priority: .userInitiated) {
            let pack = try loadTemplatePack()
            guard let url = Bundle.main.url(forResource: "rules", withExtension: "json") else {
                throw StoreError.missingResource("rules.json")
            }
            let bundled = try JSONDecoder().decode(RulesDocument.self, from: Data(contentsOf: url))
            // ダウンロード済みキャッシュと同梱版のうち「新しいほう」を使う。
            // アプリ更新で同梱版のほうが新しくなっていることがあるため、キャッシュを無条件には優先しない。
            if let data = try? Data(contentsOf: cacheURL),
               let doc = try? JSONDecoder().decode(RulesDocument.self, from: data),
               doc.schema == 2, !doc.maps.isEmpty, doc.generatedAt >= bundled.generatedAt {
                return try build(document: doc, pack: pack, origin: .cached)
            }
            return try build(document: bundled, pack: pack, origin: .bundled)
        }.value
    }

    nonisolated static func loadTemplatePack() throws -> TemplatePack {
        guard let url = Bundle.main.url(forResource: "templates", withExtension: "json") else {
            throw StoreError.missingResource("templates.json")
        }
        return try JSONDecoder().decode(TemplatePack.self, from: Data(contentsOf: url))
    }

    /// テストからも呼べるように internal にしてある。
    nonisolated static func build(document: RulesDocument, pack: TemplatePack,
                              origin: LoadedRules.Origin) throws -> LoadedRules {
        let roleByName = Dictionary(uniqueKeysWithValues: document.brawlers.map { ($0.name, $0.role) })
        let roleByID = Dictionary(uniqueKeysWithValues: document.brawlers.map { ($0.id, $0.role) })
        let nameByID = Dictionary(uniqueKeysWithValues: document.brawlers.map { ($0.id, $0.name) })
        BrawlerNameRegistry.names = nameByID

        let brawlerMatcher = TemplateMatcher(
            grayDim: pack.graySize * pack.graySize,
            colorDim: pack.colorSize * pack.colorSize * 3,
            gray: pack.templates.map { $0.gray.map(Float.init) },
            color: pack.templates.map { $0.color.map(Float.init) },
            hashes: pack.templates.map { UInt64($0.dhash, radix: 16) ?? 0 },
            ids: pack.templates.map { $0.id },
            names: pack.templates.map { $0.name }
        )

        let mapsWithTemplate = document.maps.filter { $0.template != nil }
        var indexToMapID: [Int: Int] = [:]
        for (i, m) in mapsWithTemplate.enumerated() { indexToMapID[i] = m.id }

        let mapMatcher = TemplateMatcher(
            grayDim: ImageDescriptor.graySize * ImageDescriptor.graySize,
            colorDim: ImageDescriptor.colorSize * ImageDescriptor.colorSize * 3,
            gray: mapsWithTemplate.map { $0.template!.gray.map(Float.init) },
            color: mapsWithTemplate.map { $0.template!.color.map(Float.init) },
            hashes: mapsWithTemplate.map { UInt64($0.template!.dhash, radix: 16) ?? 0 },
            ids: mapsWithTemplate.map { $0.id },
            names: mapsWithTemplate.map { $0.name }
        )

        var mapIDByJapaneseName: [String: Int] = [:]
        for m in document.maps {
            guard let ja = m.nameJa else { continue }
            mapIDByJapaneseName[ja] = m.id
        }

        return LoadedRules(
            document: document,
            mapsByID: Dictionary(uniqueKeysWithValues: document.maps.map { ($0.id, $0) }),
            roleByName: roleByName,
            roleByID: roleByID,
            nameByID: nameByID,
            brawlerMatcher: brawlerMatcher,
            mapMatcher: mapMatcher,
            mapIDByMatcherIndex: indexToMapID,
            mapIDByJapaneseName: mapIDByJapaneseName,
            origin: origin
        )
    }

    enum StoreError: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "\(name) がアプリに同梱されていません。scripts/sync_ios_resources.sh を実行してください。"
            }
        }
    }
}

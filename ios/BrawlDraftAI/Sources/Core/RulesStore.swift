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

    func advantage(_ mine: String, vs enemy: String) -> Double {
        document.advantage[mine]?[enemy] ?? 0
    }

    func synergy(_ mine: String, with ally: String) -> Double {
        document.synergy[mine]?[ally] ?? 0
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
            try data.write(to: Self.cacheURL, options: .atomic)
            AppSettings.lastRefreshAt = Date()

            let pack = try Self.loadTemplatePack()
            let built = try Self.build(document: document, pack: pack, origin: .remote)
            state = .ready(built)
            lastRefreshMessage = "更新しました（生成 \(document.generatedAt)）"
        } catch {
            lastRefreshMessage = "更新に失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - 読み込み本体

    nonisolated static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("rules_cache.json")
    }

    nonisolated private static func loadEverything() async throws -> LoadedRules {
        try await Task.detached(priority: .userInitiated) {
            let pack = try loadTemplatePack()
            // キャッシュ優先。壊れていたら同梱版にフォールバックする。
            if let data = try? Data(contentsOf: cacheURL),
               let doc = try? JSONDecoder().decode(RulesDocument.self, from: data),
               doc.schema == 2, !doc.maps.isEmpty {
                return try build(document: doc, pack: pack, origin: .cached)
            }
            guard let url = Bundle.main.url(forResource: "rules", withExtension: "json") else {
                throw StoreError.missingResource("rules.json")
            }
            let doc = try JSONDecoder().decode(RulesDocument.self, from: Data(contentsOf: url))
            return try build(document: doc, pack: pack, origin: .bundled)
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

        return LoadedRules(
            document: document,
            mapsByID: Dictionary(uniqueKeysWithValues: document.maps.map { ($0.id, $0) }),
            roleByName: roleByName,
            roleByID: roleByID,
            nameByID: nameByID,
            brawlerMatcher: brawlerMatcher,
            mapMatcher: mapMatcher,
            mapIDByMatcherIndex: indexToMapID,
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

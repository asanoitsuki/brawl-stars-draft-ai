import CoreGraphics
import Foundation

/// スクリーンショット内の位置を「0〜1 の比率」で表す矩形（左上原点）。
struct NRect: Codable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height,
               width: w * size.width, height: h * size.height)
    }

    /// 中心を保ったままスケール・平行移動する（探索ジッタ用）。
    func adjusted(dx: Double, dy: Double, scale: Double) -> NRect {
        let cx = x + w / 2 + dx * w
        let cy = y + h / 2 + dy * h
        let nw = w * scale
        let nh = h * scale
        return NRect(x: cx - nw / 2, y: cy - nh / 2, w: nw, h: nh)
    }
}

/// ドラフト画面のどこに何が描かれているかの定義。
///
/// 端末サイズ・言語・UI 更新で位置は変わるので、アプリ内のキャリブレーション画面から
/// 実際のスクリーンショットに合わせて調整できるようにしてある。
/// 保存先は App Group（Documents）で、次回以降はそちらが優先される。
struct ScreenLayout: Codable, Identifiable {
    var id: String { name }

    var name: String
    /// この配置を合わせたスクリーンショットの縦横比（幅 / 高さ）。
    var aspectRatio: Double
    /// マップのプレビュー画像
    var mapPreview: NRect
    /// BAN されたキャラのアイコン（自チーム・相手チームぶん）
    var banSlots: [NRect]
    /// 自チームのピック枠（左から順）
    var allySlots: [NRect]
    /// 相手チームのピック枠（左から順）
    var enemySlots: [NRect]

    /// 縦横比がどれだけ近いか（プロファイル自動選択に使う）
    func aspectDistance(for size: CGSize) -> Double {
        guard size.height > 0 else { return .infinity }
        return abs(Double(size.width / size.height) - aspectRatio)
    }
}

/// 端末ごとのプロファイル束。
struct LayoutProfiles: Codable {
    var schema: Int
    var profiles: [ScreenLayout]

    func best(for size: CGSize) -> ScreenLayout? {
        profiles.min { $0.aspectDistance(for: size) < $1.aspectDistance(for: size) }
    }
}

enum LayoutStore {
    private static let fileName = "screen_layout.json"

    /// 端末にキャリブレーション結果があればそれを、無ければバンドル同梱の既定値を返す。
    static func load() -> LayoutProfiles {
        if let url = overrideURL, let data = try? Data(contentsOf: url),
           let doc = try? JSONDecoder().decode(LayoutProfiles.self, from: data) {
            return doc
        }
        if let url = Bundle.main.url(forResource: "screen_layout", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let doc = try? JSONDecoder().decode(LayoutProfiles.self, from: data) {
            return doc
        }
        return LayoutProfiles(schema: 1, profiles: [.builtInLandscape])
    }

    static func save(_ profiles: LayoutProfiles) throws {
        guard let url = overrideURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }

    static func resetToBundled() {
        if let url = overrideURL { try? FileManager.default.removeItem(at: url) }
    }

    static var hasOverride: Bool {
        guard let url = overrideURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static var overrideURL: URL? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return dir?.appendingPathComponent(fileName)
    }
}

extension ScreenLayout {
    /// 既定値（横持ち 19.5:9 想定）。
    ///
    /// ⚠️ これは「だいたいこの辺」という出発点。実機のスクリーンショットは
    /// 機種・ノッチ・UI バージョンで位置が変わるので、初回は必ずアプリ内の
    /// 「枠合わせ」画面で調整すること。ズレていてもジッタ探索である程度は吸収する。
    static let builtInLandscape = ScreenLayout(
        name: "iPhone 横持ち (19.5:9)",
        aspectRatio: 19.5 / 9.0,
        mapPreview: NRect(x: 0.415, y: 0.045, w: 0.170, h: 0.300),
        banSlots: [
            NRect(x: 0.045, y: 0.055, w: 0.058, h: 0.105),
            NRect(x: 0.113, y: 0.055, w: 0.058, h: 0.105),
            NRect(x: 0.829, y: 0.055, w: 0.058, h: 0.105),
            NRect(x: 0.897, y: 0.055, w: 0.058, h: 0.105)
        ],
        allySlots: [
            NRect(x: 0.055, y: 0.560, w: 0.105, h: 0.190),
            NRect(x: 0.175, y: 0.560, w: 0.105, h: 0.190),
            NRect(x: 0.295, y: 0.560, w: 0.105, h: 0.190)
        ],
        enemySlots: [
            NRect(x: 0.600, y: 0.560, w: 0.105, h: 0.190),
            NRect(x: 0.720, y: 0.560, w: 0.105, h: 0.190),
            NRect(x: 0.840, y: 0.560, w: 0.105, h: 0.190)
        ]
    )

    /// 縦持ちスクリーンショット（横持ち画面を縦のまま撮った場合など）の保険。
    static let builtInPortrait = ScreenLayout(
        name: "iPhone 縦持ち (9:19.5)",
        aspectRatio: 9.0 / 19.5,
        mapPreview: NRect(x: 0.300, y: 0.180, w: 0.400, h: 0.140),
        banSlots: [
            NRect(x: 0.080, y: 0.150, w: 0.130, h: 0.055),
            NRect(x: 0.230, y: 0.150, w: 0.130, h: 0.055),
            NRect(x: 0.640, y: 0.150, w: 0.130, h: 0.055),
            NRect(x: 0.790, y: 0.150, w: 0.130, h: 0.055)
        ],
        allySlots: [
            NRect(x: 0.090, y: 0.600, w: 0.230, h: 0.100),
            NRect(x: 0.385, y: 0.600, w: 0.230, h: 0.100),
            NRect(x: 0.680, y: 0.600, w: 0.230, h: 0.100)
        ],
        enemySlots: [
            NRect(x: 0.090, y: 0.730, w: 0.230, h: 0.100),
            NRect(x: 0.385, y: 0.730, w: 0.230, h: 0.100),
            NRect(x: 0.680, y: 0.730, w: 0.230, h: 0.100)
        ]
    )
}

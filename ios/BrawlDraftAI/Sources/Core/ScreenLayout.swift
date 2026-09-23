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

/// ドラフト画面の種類。ブロスタのガチバトルは段位によって UI がまったく違う。
enum ScreenKind: String, Codable {
    /// エリート未満: マップ画像も BAN も無く、自チーム 3 人が同時にブラインドで選ぶ。
    /// 相手の選択は対戦開始まで常に「?」で伏せられている（実機スクショで確認済み）。
    case blindPick
    /// エリート以上: BAN フェーズの後、順番にピックが公開されていく。
    /// ⚠️ この画面のレイアウトはまだ実機スクショで確認できていない。
    /// 既定プロファイルは用意していないので、使うには枠合わせで自分の画面に合わせること。
    case draftPick
}

/// ドラフト画面のどこに何が描かれているかの定義。
///
/// 端末サイズ・言語・UI 更新で位置は変わるので、アプリ内のキャリブレーション画面から
/// 実際のスクリーンショットに合わせて調整できるようにしてある。
/// 保存先は App Group（Documents）で、次回以降はそちらが優先される。
struct ScreenLayout: Codable, Identifiable {
    var id: String { name }

    var name: String
    var kind: ScreenKind = .blindPick
    /// この配置を合わせたスクリーンショットの縦横比（幅 / 高さ）。
    var aspectRatio: Double
    /// モード名の文字が書かれている領域（Vision OCR で読む）。blindPick で使用。
    var modeTextRegion: NRect?
    /// マップのプレビュー画像。draftPick 画面にのみ存在する。
    var mapPreview: NRect?
    /// BAN されたキャラのアイコン（draftPick のみ）。
    var banSlots: [NRect] = []
    /// 自チームのピック枠（左から順）
    var allySlots: [NRect]
    /// 相手チームのピック枠（左から順）。
    /// blindPick では対戦開始まで常に「?」で伏せられているため、認識対象にしない。
    var enemySlots: [NRect]
    /// 相手の選択がこの画面で実際に見えるか。blindPick では常に false。
    var enemyVisible: Bool = true

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
    /// 既定値（横持ち iPhone、エリート未満のブラインドピック画面）。
    ///
    /// 実機スクショ（2622x1206）から黄色い選択枠・カード境界のピクセル座標を実測して
    /// 比率化したもの。以下の構造:
    ///   * 上部: キャラクター一覧グリッド（常に全キャラ表示。ここは選択状態を表さないので
    ///     認識対象にしない — 全キャラがヒットしてしまい何の情報にもならない）
    ///   * 下部: 自チーム 3 枠（ブルー）+ 相手チーム 3 枠（レッド、常に「?」で伏せられている）
    ///
    /// それでも実機ごとの余白・ノッチ差は残るので、初回は必ず枠合わせで確認すること。
    static let builtInLandscape = ScreenLayout(
        name: "iPhone 横持ち・ブラインドピック (19.5:9)",
        kind: .blindPick,
        aspectRatio: 2622.0 / 1206.0,
        modeTextRegion: NRect(x: 0.0496, y: 0.0083, w: 0.2174, h: 0.1368),
        mapPreview: nil,
        banSlots: [],
        allySlots: [
            NRect(x: 0.1991, y: 0.7363, w: 0.0789, h: 0.1410),
            NRect(x: 0.2979, y: 0.7363, w: 0.0797, h: 0.1410),
            NRect(x: 0.3982, y: 0.7363, w: 0.0793, h: 0.1410)
        ],
        enemySlots: [
            NRect(x: 0.5511, y: 0.7363, w: 0.0801, h: 0.1410),
            NRect(x: 0.6373, y: 0.7363, w: 0.0801, h: 0.1410),
            NRect(x: 0.7266, y: 0.7363, w: 0.0797, h: 0.1410)
        ],
        enemyVisible: false
    )

    /// 縦持ちスクリーンショットの保険。
    /// ⚠️ 横持ち版と違い実機で測っていない、比率からの概算値。ズレる前提で枠合わせを。
    static let builtInPortrait = ScreenLayout(
        name: "iPhone 縦持ち・ブラインドピック (9:19.5, 未検証)",
        kind: .blindPick,
        aspectRatio: 1206.0 / 2622.0,
        modeTextRegion: NRect(x: 0.10, y: 0.02, w: 0.55, h: 0.06),
        mapPreview: nil,
        banSlots: [],
        allySlots: [
            NRect(x: 0.09, y: 0.62, w: 0.24, h: 0.10),
            NRect(x: 0.38, y: 0.62, w: 0.24, h: 0.10),
            NRect(x: 0.67, y: 0.62, w: 0.24, h: 0.10)
        ],
        enemySlots: [
            NRect(x: 0.09, y: 0.75, w: 0.24, h: 0.10),
            NRect(x: 0.38, y: 0.75, w: 0.24, h: 0.10),
            NRect(x: 0.67, y: 0.75, w: 0.24, h: 0.10)
        ],
        enemyVisible: false
    )
}

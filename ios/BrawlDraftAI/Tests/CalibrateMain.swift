// 枠合わせの初期値を、実際のスクリーンショットから自動で求めるツール。
// scripts/calibrate_layout.sh から実行する。
//
// やること:
//   1. 画像全体をマルチスケールのスライディングウィンドウで走査し、
//      キャラアイコンとして高スコアな位置を洗い出す（粗探索は縮小画像で高速に）
//   2. 重なりを非最大抑制でつぶし、各検出を等倍画像で微調整する
//   3. マップ画像の位置も同じ要領で探す
//   4. 大きさと位置から BAN 枠 / 味方枠 / 相手枠へ振り分け、ScreenLayout として書き出す
//
// これは「枠がどこにあるか分からない状態」から始められる探索なので、
// 既定値がどれだけズレていても関係なく動く。

import Foundation
import CoreGraphics
import ImageIO

// MARK: - 入力

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("使い方: calibrate <screenshot.png> [--out <path>] [--adopt] [--name <プロファイル名>]\n".utf8))
    exit(2)
}
let screenshotPath = args[1]
let adopt = args.contains("--adopt")
func flagValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let root = ProcessInfo.processInfo.environment["BRAWLDRAFT_ROOT"]
    ?? FileManager.default.currentDirectoryPath
let outPath = flagValue("--out") ?? "\(root)/assets/calibration_result.json"

func loadPNG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

guard let screenshot = loadPNG(screenshotPath) else {
    FileHandle.standardError.write(Data("画像を読めません: \(screenshotPath)\n".utf8))
    exit(1)
}

// MARK: - ルール読み込み

let doc = try JSONDecoder().decode(
    RulesDocument.self,
    from: Data(contentsOf: URL(fileURLWithPath: "\(root)/rules/rules.json"))
)
let pack = try JSONDecoder().decode(
    TemplatePack.self,
    from: Data(contentsOf: URL(fileURLWithPath: "\(root)/assets/brawler_templates/templates.json"))
)
let rules = try RulesStore.build(document: doc, pack: pack, origin: .bundled)

print("▶ 対象: \(URL(fileURLWithPath: screenshotPath).lastPathComponent) "
      + "(\(screenshot.width)x\(screenshot.height))")
print("  テンプレ: キャラ \(rules.brawlerMatcher.count) / マップ \(rules.mapMatcher.count)")

// MARK: - 探索

struct Detection {
    var rect: CGRect        // 正規化座標 (0〜1, 左上原点)
    var name: String
    var id: Int
    var score: Float
}

/// 走査で見つけた候補のうち、重なっているものを高スコア優先で 1 つに絞る。
func suppress(_ candidates: [Detection], iouThreshold: Double) -> [Detection] {
    var kept: [Detection] = []
    for c in candidates.sorted(by: { $0.score > $1.score }) {
        let overlaps = kept.contains { k in
            let inter = k.rect.intersection(c.rect)
            if inter.isNull || inter.isEmpty { return false }
            let interArea = Double(inter.width * inter.height)
            let union = Double(k.rect.width * k.rect.height + c.rect.width * c.rect.height) - interArea
            return union > 0 && interArea / union > iouThreshold
        }
        if !overlaps { kept.append(c) }
    }
    return kept
}

/// マルチスケールのスライディングウィンドウ走査。
func scan(raster: ImageRaster, matcher: TemplateMatcher,
          widthFractions: [Double], aspect: Double,
          strideRatio: Double, minScore: Float) -> [Detection] {
    let size = CGSize(width: raster.width, height: raster.height)
    var found: [Detection] = []

    for fraction in widthFractions {
        let w = Double(raster.width) * fraction
        let h = w * aspect
        guard w >= 8, h >= 8, h <= Double(raster.height) else { continue }
        let step = max(4.0, w * strideRatio)

        var y = 0.0
        while y + h <= Double(raster.height) {
            var x = 0.0
            while x + w <= Double(raster.width) {
                let rect = CGRect(x: x, y: y, width: w, height: h)
                if let d = ImageDescriptor.make(from: raster, crop: rect),
                   d.contrast >= 0.045,
                   let m = matcher.best(for: d), m.score >= minScore {
                    found.append(Detection(
                        rect: CGRect(x: x / size.width, y: y / size.height,
                                     width: w / size.width, height: h / size.height),
                        name: m.name, id: m.id, score: m.score
                    ))
                }
                x += step
            }
            y += step
        }
    }
    return found
}

/// 粗探索で見つけた位置を、等倍画像の上で細かく詰める。
/// - Parameter freeAspect: true なら縦横を独立に動かす（マップ枠のように縦横比が読めないとき）
func refine(_ detection: Detection, raster: ImageRaster,
            matcher: TemplateMatcher, freeAspect: Bool = false) -> Detection {
    let size = CGSize(width: raster.width, height: raster.height)
    var best = detection
    let offsets = stride(from: -0.30, through: 0.30, by: 0.10)
    let scales = Array(stride(from: 0.80, through: 1.25, by: 0.05))
    let hScales = freeAspect ? Array(stride(from: 0.70, through: 1.40, by: 0.10)) : [Double]()

    for scale in scales {
        for hScale in (freeAspect ? hScales : [scale]) {
        let w = detection.rect.width * scale
        let h = detection.rect.height * hScale
        for dx in offsets {
            for dy in offsets {
                let cx = detection.rect.midX + dx * detection.rect.width
                let cy = detection.rect.midY + dy * detection.rect.height
                let n = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
                guard n.minX >= 0, n.minY >= 0, n.maxX <= 1, n.maxY <= 1 else { continue }
                let pixels = CGRect(x: n.minX * size.width, y: n.minY * size.height,
                                    width: n.width * size.width, height: n.height * size.height)
                guard let d = ImageDescriptor.make(from: raster, crop: pixels),
                      let m = matcher.best(for: d) else { continue }
                if m.score > best.score {
                    best = Detection(rect: n, name: m.name, id: m.id, score: m.score)
                }
            }
        }
        }
    }
    return best
}

guard let coarse = ImageDescriptor.rasterize(screenshot, maxSide: 800),
      let fine = ImageDescriptor.rasterize(screenshot, maxSide: 1600) else {
    FileHandle.standardError.write(Data("ラスタライズに失敗しました\n".utf8))
    exit(1)
}

let started = CFAbsoluteTimeGetCurrent()

// --- キャラアイコン ---
print("▶ キャラアイコンを全面走査中 …")
let brawlerFractions = stride(from: 0.040, through: 0.150, by: 0.012).map { $0 }
let rawIcons = scan(raster: coarse, matcher: rules.brawlerMatcher,
                    widthFractions: brawlerFractions, aspect: 1.0,
                    strideRatio: 0.30, minScore: 0.52)
let iconCandidates = suppress(rawIcons, iouThreshold: 0.25)
    .prefix(24)
    .map { refine($0, raster: fine, matcher: rules.brawlerMatcher) }
var icons = suppress(Array(iconCandidates), iouThreshold: 0.25)
    .sorted { $0.score > $1.score }

// 背景に偶然マッチしただけの検出を落とす。
// 絶対値のしきい値だけだと画質次第でぶれるので、最良スコアからの相対でも切る。
let iconFloor = max(0.62, (icons.first?.score ?? 0) * 0.80)
icons = icons.filter { $0.score >= iconFloor }

// ドラフト画面に同じキャラは 2 回出ない。重複は高スコア側だけ残す。
var seenBrawlers = Set<Int>()
icons = icons.filter { seenBrawlers.insert($0.id).inserted }

print("  候補 \(rawIcons.count) → 抑制後 \(icons.count) "
      + "(しきい値 \(String(format: "%.2f", iconFloor)))")

// --- マップ画像 ---
print("▶ マップ画像を走査中 …")
var mapHits: [Detection] = []
// マップ画像は縦長 (h/w ≒ 1.5) だが、UI 側の枠が正方形寄りのこともあるので広めに振る
for aspect in [0.9, 1.15, 1.4, 1.55, 1.75, 2.0] {
    mapHits += scan(raster: coarse, matcher: rules.mapMatcher,
                    widthFractions: stride(from: 0.07, through: 0.30, by: 0.015).map { $0 },
                    aspect: aspect, strideRatio: 0.30, minScore: 0.45)
}
// 粗探索の 1 位がそのまま正解とは限らない（グリッドが枠に乗り切らないと
// 別のマップの方が高く出ることがある）。上位をまとめて詰めてから選び直す。
let mapBest = suppress(mapHits, iouThreshold: 0.20)
    .prefix(8)
    .map { refine($0, raster: fine, matcher: rules.mapMatcher, freeAspect: true) }
    .max { $0.score < $1.score }

let elapsed = CFAbsoluteTimeGetCurrent() - started

// MARK: - 振り分け

/// アイコンを「大きい群 = ピック枠 / 小さい群 = BAN 枠」に分ける。
func split(icons: [Detection]) -> (picks: [Detection], bans: [Detection]) {
    guard icons.count > 3 else { return (icons, []) }
    let widths = icons.map { Double($0.rect.width) }.sorted()
    let median = widths[widths.count / 2]
    // 中央値の 75% 未満を BAN 枠とみなす（BAN アイコンはピックより小さく描かれる）
    let picks = icons.filter { Double($0.rect.width) >= median * 0.75 }
    let bans = icons.filter { Double($0.rect.width) < median * 0.75 }
    return (picks, bans)
}

let (pickHits, banHits) = split(icons: icons)
let midX = 0.5
let allies = pickHits.filter { $0.rect.midX < midX }.sorted { $0.rect.minX < $1.rect.minX }
let enemies = pickHits.filter { $0.rect.midX >= midX }.sorted { $0.rect.minX < $1.rect.minX }
let bans = banHits.sorted { $0.rect.minX < $1.rect.minX }

print("\n=== 検出結果（\(String(format: "%.1f", elapsed)) 秒）===")
if let mapBest {
    print(String(format: "マップ : %-22s 一致度 %.3f  枠 x=%.3f y=%.3f w=%.3f h=%.3f",
                 (mapBest.name as NSString).utf8String!, mapBest.score,
                 mapBest.rect.minX, mapBest.rect.minY, mapBest.rect.width, mapBest.rect.height))
} else {
    print("マップ : 見つかりませんでした")
}
for (label, list) in [("味方", allies), ("相手", enemies), ("BAN ", bans)] {
    for (i, d) in list.enumerated() {
        print(String(format: "%@%d : %-22s 一致度 %.3f  枠 x=%.3f y=%.3f w=%.3f h=%.3f",
                     label, i + 1, (d.name as NSString).utf8String!, d.score,
                     d.rect.minX, d.rect.minY, d.rect.width, d.rect.height))
    }
}

// MARK: - 書き出し

func nrect(_ r: CGRect) -> [String: Double] {
    ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)]
}

let aspectRatio = Double(screenshot.width) / Double(screenshot.height)
let profileName = flagValue("--name")
    ?? String(format: "自動検出 (%.2f:1)", aspectRatio)

var profile: [String: Any] = [
    "name": profileName,
    "aspectRatio": aspectRatio,
    "mapPreview": nrect(mapBest?.rect ?? CGRect(x: 0.42, y: 0.05, width: 0.16, height: 0.30)),
    "banSlots": bans.map { nrect($0.rect) },
    "allySlots": allies.map { nrect($0.rect) },
    "enemySlots": enemies.map { nrect($0.rect) }
]
profile["_detected"] = [
    "map": mapBest.map { ["name": $0.name, "score": Double($0.score)] } as Any,
    "allies": allies.map { ["name": $0.name, "score": Double($0.score)] },
    "enemies": enemies.map { ["name": $0.name, "score": Double($0.score)] },
    "bans": bans.map { ["name": $0.name, "score": Double($0.score)] }
]

let result: [String: Any] = [
    "schema": 1,
    "_source": screenshotPath,
    "_note": "scripts/calibrate_layout.sh が自動生成。アプリの「枠合わせ」で最終確認すること。",
    "profiles": [profile]
]
let json = try JSONSerialization.data(withJSONObject: result,
                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: URL(fileURLWithPath: outPath))
print("\n→ \(outPath) に書き出しました")

if adopt {
    let dest = "\(root)/ios/BrawlDraftAI/Sources/Resources/screen_layout.json"
    var existing: [String: Any] = ["schema": 1, "profiles": []]
    if let data = FileManager.default.contents(atPath: dest),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        existing = parsed
    }
    var profiles = (existing["profiles"] as? [[String: Any]]) ?? []
    profiles.removeAll { ($0["name"] as? String) == profileName }
    profiles.insert(profile, at: 0)
    existing["profiles"] = profiles
    let out = try JSONSerialization.data(withJSONObject: existing,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try out.write(to: URL(fileURLWithPath: dest))
    print("→ --adopt: \(dest) のプロファイル「\(profileName)」を更新しました")
}

// 妥当性チェック（合成画像での自己検証用）
if let expected = flagValue("--expect-map"), mapBest?.name != expected {
    FileHandle.standardError.write(Data("✖ マップ期待値 \(expected) / 実際 \(mapBest?.name ?? "nil")\n".utf8))
    exit(1)
}
if let expectPicks = flagValue("--expect-picks") {
    let want = Set(expectPicks.split(separator: ",").map(String.init))
    let got = Set(pickHits.map(\.name))
    if want != got {
        FileHandle.standardError.write(Data("✖ ピック期待値 \(want.sorted()) / 実際 \(got.sorted())\n".utf8))
        exit(1)
    }
}
print("✔ 完了")

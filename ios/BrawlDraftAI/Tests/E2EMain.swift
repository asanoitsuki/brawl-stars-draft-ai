// swiftlint:disable all
// 認識コアの結合テスト。scripts/run_swift_e2e.sh から実行する。
//
// ブラインドピック画面（エリート未満、実機スクショの実測値に基づく既定レイアウト）を
// 合成画像で再現し、切り出し→記述子→照合→フェーズ判定→提案 まで通しで検証する。
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// プロジェクトルート。scripts/run_swift_e2e.sh から環境変数で渡される。
let root = ProcessInfo.processInfo.environment["BRAWLDRAFT_ROOT"]
    ?? FileManager.default.currentDirectoryPath

func loadPNG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// --- ルール読み込み（アプリでは RulesStore がやること） ---
let rulesData = try Data(contentsOf: URL(fileURLWithPath: "\(root)/rules/rules.json"))
let t0 = CFAbsoluteTimeGetCurrent()
let doc = try JSONDecoder().decode(RulesDocument.self, from: rulesData)
let decodeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
let packData = try Data(contentsOf: URL(fileURLWithPath: "\(root)/assets/brawler_templates/templates.json"))
let pack = try JSONDecoder().decode(TemplatePack.self, from: packData)
let t1 = CFAbsoluteTimeGetCurrent()
let rules = try RulesStore.build(document: doc, pack: pack, origin: .bundled)
let buildMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
print(String(format: "rules.json デコード %.0f ms / インデックス構築 %.0f ms", decodeMs, buildMs))
print("マップ \(doc.maps.count) / キャラ \(pack.templates.count) / モード \(doc.modes.count) / 実測勝率 \(doc.dataQuality.liveStats)")

// --- 合成スクリーンショットを作る（実機スクショの実測比率で再現） ---
let W = 2622, H = 1206
let layout = ScreenLayout.builtInLandscape  // 実測済みの既定プロファイルをそのまま検証する

let allyNames = ["Piper", "Poco"]  // 3 枠中 2 人だけ決まっている状態（ブラインドピック途中）
let idByName = Dictionary(uniqueKeysWithValues: doc.brawlers.map { ($0.name, $0.id) })

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: W * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("context")
}
ctx.setFillColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
ctx.interpolationQuality = .high

let canvas = CGSize(width: W, height: H)
/// CoreGraphics は左下原点なので、上下を反転して配置する
func draw(_ image: CGImage, into n: NRect) {
    let r = n.rect(in: canvas)
    let flipped = CGRect(x: r.minX, y: CGFloat(H) - r.maxY, width: r.width, height: r.height)
    ctx.draw(image, in: flipped)
}

// モード名を実際のフォントで描画し、Vision OCR が現実に近い条件で読めるか検証する
func drawText(_ text: String, into n: NRect) {
    let r = n.rect(in: canvas)
    let flipped = CGRect(x: r.minX, y: CGFloat(H) - r.maxY, width: r.width, height: r.height)
    ctx.saveGState()
    ctx.setFillColor(red: 0.9, green: 0.55, blue: 0.1, alpha: 1)  // オレンジ帯（実機同様の背景）
    ctx.fill(flipped)
    let font = CTFontCreateWithName("HiraginoSans-W7" as CFString, flipped.height * 0.55, nil)
    let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                   kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
    let line = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
    )
    ctx.textPosition = CGPoint(x: flipped.minX + 12, y: flipped.minY + flipped.height * 0.28)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

if let region = layout.modeTextRegion {
    drawText("ノックアウト", into: region)
}
for (i, name) in allyNames.enumerated() {
    if let id = idByName[name], let img = loadPNG("\(root)/assets/brawler_icons/borders/\(id).png") {
        draw(img, into: layout.allySlots[i])
    }
}
// 3 枠目はあえて空のまま（「?」プレースホルダ相当 = 何も描かない平坦な背景）
// 相手枠も常に空のまま（実機同様、対戦開始まで非公開）

guard let synthetic = ctx.makeImage() else { fatalError("image") }

let outURL = URL(fileURLWithPath: "\(root)/assets/synthetic_draft_test.png")
if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, synthetic, nil)
    CGImageDestinationFinalize(dest)
}

print("\n=== 期待値 ===")
print("モード: ノックアウト / 味方: \(allyNames)（3枠目は未選択）/ 相手: 非公開")

var times: [Double] = []
var snapshot: DraftSnapshot!
for _ in 0..<5 {
    let s = CFAbsoluteTimeGetCurrent()
    snapshot = DraftAnalyzer.analyze(image: synthetic, rules: rules, layoutOverride: layout)
    times.append((CFAbsoluteTimeGetCurrent() - s) * 1000)
}

print("\n=== 解析結果 ===")
print(snapshot.diagnosticSummary)
print(String(format: "解析時間: 初回 %.0f ms / 2回目以降の中央値 %.0f ms",
             times[0], times.sorted()[times.count / 2]))

let rec = Recommender.make(from: snapshot, rules: rules)
print("\n=== 提案 ===")
print(rec.title)
print(rec.body)
if let c = rec.caution { print("⚠️ \(c)") }
print("読み上げ: " + rec.speech.map(\.text).joined())

// --- 判定 ---
var failures: [String] = []
let gotAllies = Set(snapshot.allies.map(\.name))
if gotAllies != Set(allyNames) { failures.append("味方: \(gotAllies.sorted()) (期待: \(allyNames))") }
if !snapshot.enemies.isEmpty { failures.append("相手が検出されてしまった（非公開のはず）: \(snapshot.enemies.map(\.name))") }
if case .blind(let filled, let total) = snapshot.phase {
    if filled != 2 || total != 3 { failures.append("フェーズ: \(filled)/\(total)（期待: 2/3）") }
} else {
    failures.append("フェーズが blind になっていない: \(snapshot.phase)")
}
if snapshot.mode != "Knockout" {
    failures.append("モード誤判定またはOCR失敗: \(snapshot.mode ?? "nil")（期待: Knockout）")
}
if rec.advices.isEmpty { failures.append("推薦が空") }

// ModeRecognizer の文字列マッチ単体（OCR 精度に依存しない部分の健全性チェック）
let matched = ModeRecognizer.bestMatch(for: "ノックアウト オープンフィールド", in: doc.modes)
if matched != "Knockout" { failures.append("ModeRecognizer.bestMatch が不正: \(matched ?? "nil")") }
let fuzzyMatched = ModeRecognizer.bestMatch(for: "ノックアウト卜", in: doc.modes)  // 1文字誤読を想定
if fuzzyMatched != "Knockout" { failures.append("ModeRecognizer のあいまい一致が不正: \(fuzzyMatched ?? "nil")") }

print("\n=== 判定 ===")
if failures.isEmpty {
    print("✔ すべて一致")
} else {
    failures.forEach { print("✖ \($0)") }
    exit(1)
}

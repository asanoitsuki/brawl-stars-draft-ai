// swiftlint:disable all
// 認識コアの結合テスト。scripts/run_swift_e2e.sh から実行する。
import Foundation
import CoreGraphics
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
print("マップ \(doc.maps.count) / キャラ \(pack.templates.count) / 実測勝率 \(doc.dataQuality.liveStats)")

// --- 合成スクリーンショットを作る ---
// 正方形スロットの単純な配置。実機は必ずキャリブレーションが要るが、
// 「切り出し → 記述子 → 照合 → 提案」の経路はこれで検証できる。
let W = 2556, H = 1179
func nrect(_ x: Double, _ y: Double, _ s: Double) -> NRect {
    NRect(x: x, y: y, w: s, h: s * Double(W) / Double(H))
}
let slotS = 0.085
let testLayout = ScreenLayout(
    name: "synthetic",
    aspectRatio: Double(W) / Double(H),
    // マップ画像は縦長 (h/w ≒ 1.55)。引き伸ばすとテンプレートと形が変わってしまうので、
    // 実際の縦横比のまま置く。
    mapPreview: NRect(x: 0.435, y: 0.06, w: 0.13, h: 0.13 * 1.55 * Double(W) / Double(H)),
    banSlots: [nrect(0.04, 0.06, 0.05), nrect(0.10, 0.06, 0.05),
               nrect(0.85, 0.06, 0.05), nrect(0.91, 0.06, 0.05)],
    allySlots: [nrect(0.06, 0.60, slotS), nrect(0.16, 0.60, slotS), nrect(0.26, 0.60, slotS)],
    enemySlots: [nrect(0.60, 0.60, slotS), nrect(0.70, 0.60, slotS), nrect(0.80, 0.60, slotS)]
)

// 適当なマップを 1 つ選んで、その画像とキャラを配置する
guard let targetMap = doc.maps.first(where: { $0.mode == "Bounty" && $0.template != nil }) else {
    fatalError("テスト用マップが見つかりません")
}
let allyNames = ["Piper", "Poco", "Bull"]
let enemyNames = ["Mortis", "Barley"]           // 5 体埋まっている = 6 手目 (ラストピック)
let banNames = ["Angelo", "Edgar", "Tick", "Max"]
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

if let mapImg = loadPNG("\(root)/assets/map_thumbs/\(targetMap.id).png") {
    draw(mapImg, into: testLayout.mapPreview)
}
for (i, name) in allyNames.enumerated() {
    if let id = idByName[name], let img = loadPNG("\(root)/assets/brawler_icons/borders/\(id).png") {
        draw(img, into: testLayout.allySlots[i])
    }
}
for (i, name) in enemyNames.enumerated() {
    if let id = idByName[name], let img = loadPNG("\(root)/assets/brawler_icons/borders/\(id).png") {
        draw(img, into: testLayout.enemySlots[i])
    }
}
for (i, name) in banNames.enumerated() {
    if let id = idByName[name], let img = loadPNG("\(root)/assets/brawler_icons/borders/\(id).png") {
        draw(img, into: testLayout.banSlots[i])
    }
}
guard let synthetic = ctx.makeImage() else { fatalError("image") }

// 合成した画像は、アプリの「枠合わせ」を試すサンプルとして残しておく
let outURL = URL(fileURLWithPath: "\(root)/assets/synthetic_draft_test.png")
if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, synthetic, nil)
    CGImageDestinationFinalize(dest)
}

// --- 解析 ---
print("\n=== 期待値 ===")
print("マップ: \(targetMap.name) (\(targetMap.modeJa)) / 味方 \(allyNames) / 相手 \(enemyNames) / BAN \(banNames)")

var times: [Double] = []
var snapshot: DraftSnapshot!
for _ in 0..<5 {
    let s = CFAbsoluteTimeGetCurrent()
    snapshot = DraftAnalyzer.analyze(image: synthetic, rules: rules, layoutOverride: testLayout)
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
if snapshot.map?.id != targetMap.id { failures.append("マップ誤判定: \(snapshot.map?.name ?? "nil")") }
let gotAllies = Set(snapshot.allies.map(\.name)), gotEnemies = Set(snapshot.enemies.map(\.name))
if gotAllies != Set(allyNames) { failures.append("味方: \(gotAllies.sorted())") }
if gotEnemies != Set(enemyNames) { failures.append("相手: \(gotEnemies.sorted())") }
if Set(snapshot.bans.map(\.name)) != Set(banNames) { failures.append("BAN: \(snapshot.bans.map(\.name))") }
if snapshot.phase != .last { failures.append("フェーズ: \(snapshot.phase.label)") }

print("\n=== 判定 ===")
if failures.isEmpty {
    print("✔ すべて一致")
} else {
    failures.forEach { print("✖ \($0)") }
    exit(1)
}

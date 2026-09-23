// swiftlint:disable all
// AutoDetector（枠合わせ画面が使う「既定位置からスナップ」方式）のセルフテスト。
// scripts/calibrate_layout.sh --self-test から実行する。
//
// 旧方式（画面全体をブラインドで総当たりスキャン）は、常に全キャラが表示されている
// キャラ一覧グリッドに惑わされて誤検出しやすいことが実機検証で判明したため廃止した。
// 現在アプリが実際に使っているのは「実測済みの既定位置を出発点に局所探索でスナップする」
// AutoDetector の方式なので、検証もそちらに合わせる。
import Foundation
import CoreGraphics
import ImageIO

let root = ProcessInfo.processInfo.environment["BRAWLDRAFT_ROOT"]
    ?? FileManager.default.currentDirectoryPath

func loadPNG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

let doc = try JSONDecoder().decode(
    RulesDocument.self,
    from: Data(contentsOf: URL(fileURLWithPath: "\(root)/rules/rules.json"))
)
let pack = try JSONDecoder().decode(
    TemplatePack.self,
    from: Data(contentsOf: URL(fileURLWithPath: "\(root)/assets/brawler_templates/templates.json"))
)
let rules = try RulesStore.build(document: doc, pack: pack, origin: .bundled)

let imgPath = "\(root)/assets/synthetic_draft_test.png"
guard let screenshot = loadPNG(imgPath) else {
    FileHandle.standardError.write(Data("画像を読めません: \(imgPath)\n".utf8))
    FileHandle.standardError.write(Data("先に ./scripts/run_swift_e2e.sh を実行してください\n".utf8))
    exit(1)
}

print("▶ 対象: \(imgPath)")
print("▶ AutoDetector.refine() で既定位置からスナップ …")

let started = CFAbsoluteTimeGetCurrent()
let result = AutoDetector.refine(image: screenshot, base: .builtInLandscape, rules: rules)
let elapsed = CFAbsoluteTimeGetCurrent() - started

print(String(format: "  %.2f 秒", elapsed))
for (i, s) in result.allySlots.enumerated() {
    print("  味方\(i + 1): \(s.matchedName ?? "(未検出)") 一致度 \(String(format: "%.3f", s.score))"
          + " 枠 x=\(String(format: "%.3f", s.rect.x)) y=\(String(format: "%.3f", s.rect.y))"
          + " w=\(String(format: "%.3f", s.rect.w)) h=\(String(format: "%.3f", s.rect.h))")
}
for (i, s) in result.enemySlots.enumerated() {
    print("  相手\(i + 1): \(s.matchedName ?? "(スキップ = 非公開画面)")")
}

// --- 判定 ---
// 合成画像は Piper, Poco の 2 人だけ確定、3 枠目は未選択（プレースホルダ）。
var failures: [String] = []
let names = result.allySlots.map { $0.matchedName }
if names.count < 3 { failures.append("ally スロット数が 3 ではない: \(names.count)") } else {
    if names[0] != "Piper" { failures.append("味方1 誤検出: \(names[0] ?? "nil")（期待: Piper）") }
    if names[1] != "Poco" { failures.append("味方2 誤検出: \(names[1] ?? "nil")（期待: Poco）") }
    if names[2] != nil { failures.append("味方3 は未選択のはずが誤検出: \(names[2]!)") }
}
// enemyVisible=false の画面なので、相手はスナップを試みず base の位置のまま返るはず
if result.enemySlots.contains(where: { $0.matchedName != nil }) {
    failures.append("相手（非公開のはず）が検出されてしまった")
}
if elapsed > 3.0 {
    failures.append("自動検出が遅すぎる: \(elapsed) 秒（キャリブレーション画面での体感に関わる）")
}

print("\n=== 判定 ===")
if failures.isEmpty {
    print("✔ すべて一致")
} else {
    failures.forEach { print("✖ \($0)") }
    exit(1)
}

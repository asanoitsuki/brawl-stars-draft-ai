import CoreGraphics
import Foundation

/// スクリーンショット 1 枚からドラフトの状況を読み取る。
///
/// 速度設計:
///   * CoreGraphics の描画は **最初の 1 回だけ**（`ImageDescriptor.rasterize`）
///   * 以降の切り出し・縮小はバッファ上の算術のみ
///   * 照合は vDSP の内積。110 テンプレ × 256 次元で数十マイクロ秒
/// iPhone 15 実機で概ね 60〜120 ms。0.5 秒の予算に対して十分な余裕がある。
enum DraftAnalyzer {
    /// 解析用に縮小する長辺サイズ。小さくするほど速いが、枠が小さいと精度が落ちる。
    static let workingMaxSide = 1600

    /// 1 発目でこのスコアを超えたらジッタ探索を省略する。
    private static let fastAcceptScore: Float = 0.80
    /// 枠が平坦（＝まだ誰も選んでいない）と判断する閾値。
    private static let emptyContrast: Float = 0.045

    static func analyze(image: CGImage, rules: LoadedRules,
                        layoutOverride: ScreenLayout? = nil) -> DraftSnapshot {
        let started = CFAbsoluteTimeGetCurrent()

        guard let raster = ImageDescriptor.rasterize(image, maxSide: workingMaxSide) else {
            return DraftSnapshot(map: nil, mapScore: 0, mapMargin: 0, bans: [], allies: [],
                                 enemies: [], phase: .first, layoutName: "-",
                                 elapsed: CFAbsoluteTimeGetCurrent() - started)
        }
        let size = CGSize(width: raster.width, height: raster.height)
        let layout = layoutOverride
            ?? LayoutStore.load().best(for: size)
            ?? (size.width >= size.height ? .builtInLandscape : .builtInPortrait)

        // --- マップ判定（OCR ではなくマップ画像そのものを照合する） ---
        let mapMatch = search(raster: raster, size: size, rect: layout.mapPreview,
                              matcher: rules.mapMatcher, excluding: [])
        var map: MapRules?
        if let m = mapMatch.result, m.score >= TemplateMatcher.acceptScore {
            map = rules.map(id: m.id)
        }

        // --- BAN 枠とピック枠 ---
        var taken = Set<Int>()
        let bans = detect(slots: layout.banSlots, raster: raster, size: size,
                          rules: rules, taken: &taken)
        let allies = detect(slots: layout.allySlots, raster: raster, size: size,
                            rules: rules, taken: &taken)
        let enemies = detect(slots: layout.enemySlots, raster: raster, size: size,
                             rules: rules, taken: &taken)

        let phase = DraftPhase.from(pickedCount: allies.count + enemies.count,
                                    banCount: bans.count,
                                    expectedBans: layout.banSlots.count)

        return DraftSnapshot(
            map: map,
            mapScore: mapMatch.result?.score ?? 0,
            mapMargin: mapMatch.result?.margin ?? 0,
            bans: bans, allies: allies, enemies: enemies,
            phase: phase,
            layoutName: layout.name,
            elapsed: CFAbsoluteTimeGetCurrent() - started
        )
    }

    // MARK: - 内部

    private static func detect(slots: [NRect], raster: ImageRaster, size: CGSize,
                               rules: LoadedRules, taken: inout Set<Int>) -> [DetectedBrawler] {
        var found: [DetectedBrawler] = []
        for (index, slot) in slots.enumerated() {
            let hit = search(raster: raster, size: size, rect: slot,
                             matcher: rules.brawlerMatcher, excluding: taken)
            guard let result = hit.result, let contrast = hit.contrast else { continue }
            // 誰も選んでいない枠は平坦な背景になるので落とす
            if contrast < emptyContrast { continue }
            guard result.score >= TemplateMatcher.acceptScore else { continue }

            let role = rules.roleByID[result.id] ?? rules.role(of: result.name) ?? "damage"
            taken.insert(result.id)
            found.append(DetectedBrawler(
                id: result.id, name: result.name,
                role: role, roleJa: rules.japaneseRole(role),
                score: result.score, margin: result.margin, slot: index
            ))
        }
        return found
    }

    /// 枠のズレを吸収するための小さな探索。
    ///
    /// キャリブレーションが多少ずれていても、位置 ±6% / 拡大縮小 ±8% の範囲で
    /// 最良の一致を拾う。1 発目で十分な一致が出たら探索自体を省く。
    private static func search(raster: ImageRaster, size: CGSize, rect: NRect,
                               matcher: TemplateMatcher,
                               excluding: Set<Int>) -> (result: MatchResult?, contrast: Float?) {
        guard let base = ImageDescriptor.make(from: raster, crop: rect.rect(in: size)) else {
            return (nil, nil)
        }
        var best = matcher.best(for: base, excluding: excluding)
        var bestContrast = base.contrast
        if let best, best.score >= fastAcceptScore {
            return (best, bestContrast)
        }

        let offsets: [Double] = [-0.06, 0, 0.06]
        let scales: [Double] = [0.92, 1.0, 1.08]
        for scale in scales {
            for dx in offsets {
                for dy in offsets {
                    if scale == 1.0 && dx == 0 && dy == 0 { continue }
                    let jittered = rect.adjusted(dx: dx, dy: dy, scale: scale)
                    guard let d = ImageDescriptor.make(from: raster, crop: jittered.rect(in: size)),
                          let candidate = matcher.best(for: d, excluding: excluding) else { continue }
                    if candidate.score > (best?.score ?? -1) {
                        best = candidate
                        bestContrast = d.contrast
                    }
                }
            }
        }
        return (best, bestContrast)
    }
}

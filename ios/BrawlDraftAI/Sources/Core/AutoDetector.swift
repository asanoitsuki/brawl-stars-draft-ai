import CoreGraphics
import Foundation

/// 枠合わせ画面用の「自動検出」。
///
/// キャラ一覧グリッドには常に全キャラが表示されているため、画面全体をブラインドで
/// 総当たりスキャンすると grid のダミー候補ばかり拾ってしまい実用にならない
/// （実機検証で確認済み）。代わりに、実測済みの既定レイアウトを出発点にして、
/// 各枠を局所的に最適化（スナップ）する方式を取る。
///
/// これにより「枠を一から手で置く」のではなく「だいたい合っている状態から微調整するだけ」
/// で済むようにする。
enum AutoDetector {
    struct SlotResult {
        var rect: NRect
        var matchedName: String?
        var score: Float
    }

    struct Result {
        var allySlots: [SlotResult]
        var enemySlots: [SlotResult]
    }

    /// `base` の枠位置を出発点に、各枠を画像に対して局所探索でスナップさせる。
    /// 相手枠は `enemyVisible` が false なら探索せず、base の位置をそのまま返す
    /// （このゲームでは対戦開始まで常に伏せられているため、探索しても無意味）。
    static func refine(image: CGImage, base: ScreenLayout,
                       rules: LoadedRules) -> Result {
        guard let raster = ImageDescriptor.rasterize(image, maxSide: 1600) else {
            return Result(
                allySlots: base.allySlots.map { SlotResult(rect: $0, matchedName: nil, score: 0) },
                enemySlots: base.enemySlots.map { SlotResult(rect: $0, matchedName: nil, score: 0) }
            )
        }
        let size = CGSize(width: raster.width, height: raster.height)

        let allies = base.allySlots.map {
            snap(rect: $0, raster: raster, size: size, matcher: rules.brawlerMatcher)
        }
        let enemies = base.enemyVisible
            ? base.enemySlots.map { snap(rect: $0, raster: raster, size: size, matcher: rules.brawlerMatcher) }
            : base.enemySlots.map { SlotResult(rect: $0, matchedName: nil, score: 0) }

        return Result(allySlots: allies, enemySlots: enemies)
    }

    /// 1 枠ぶんの局所探索。枠合わせの初期ズレを吸収するため、
    /// DraftAnalyzer の実行時ジッタ探索より広い範囲（位置 ±12% / 拡大縮小 ±18%）で探す。
    private static func snap(rect: NRect, raster: ImageRaster, size: CGSize,
                             matcher: TemplateMatcher) -> SlotResult {
        var best: (rect: NRect, result: MatchResult)?

        let offsets: [Double] = [-0.12, -0.06, 0, 0.06, 0.12]
        let scales: [Double] = [0.80, 0.90, 1.0, 1.10, 1.20]

        for scale in scales {
            for dx in offsets {
                for dy in offsets {
                    let candidate = rect.adjusted(dx: dx, dy: dy, scale: scale)
                    guard let d = ImageDescriptor.make(from: raster, crop: candidate.rect(in: size)),
                          d.contrast >= 0.045,  // 「?」の平坦なプレースホルダは除外
                          let m = matcher.best(for: d) else { continue }
                    if m.score > (best?.result.score ?? -1) {
                        best = (candidate, m)
                    }
                }
            }
        }

        guard let best, best.result.score >= 0.55 else {
            // 有意な一致が無い（誰も選んでいない枠、または画像がそもそも違う）。
            // 元の位置のまま返し、後段で人間が確認できるようにする。
            return SlotResult(rect: rect, matchedName: nil, score: 0)
        }
        return SlotResult(rect: best.rect, matchedName: best.result.name, score: best.result.score)
    }
}

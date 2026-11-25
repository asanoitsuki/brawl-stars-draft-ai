import CoreGraphics
import Foundation

/// スクリーンショット 1 枚からドラフトの状況を読み取る。
///
/// 速度設計:
///   * CoreGraphics の描画は **最初の 1 回だけ**（`ImageDescriptor.rasterize`）
///   * 以降の切り出し・縮小はバッファ上の算術のみ
///   * 照合は vDSP の内積。110 テンプレ × 256 次元で数十マイクロ秒
///   * OCR (Vision) はモード名の小さな 1 領域だけなので数十 ms 以内
/// iPhone 15 実機で概ね 100〜200 ms。0.5 秒の予算に対して十分な余裕がある。
///
/// **重要**: ブロスタのドラフト画面は段位で UI がまったく違う（実機で確認済み）。
///   * エリート未満（`kind == .blindPick`）: 上部にキャラ一覧グリッド（常に全キャラ表示、
///     選択状態を表さない）、下部に自チーム 3 枠＋相手チーム 3 枠（相手は常に「?」で伏せ）。
///     BAN も無い。→ グリッドは走査しない（全キャラがヒットして無意味）。
///   * エリート以上（`kind == .draftPick`）: BAN フェーズ後に順番へ公開。
///     ステージ名と「BAN の番かどうか」は文字で読む。
enum DraftAnalyzer {
    /// 解析用に縮小する長辺サイズ。小さくするほど速いが、枠が小さいと精度が落ちる。
    static let workingMaxSide = 1600

    /// 1 発目でこのスコアを超えたらジッタ探索を省略する。
    private static let fastAcceptScore: Float = 0.80
    /// 枠が平坦（＝まだ誰も選んでいない「?」プレースホルダ）と判断する閾値。
    private static let emptyContrast: Float = 0.045

    static func analyze(image: CGImage, rules: LoadedRules,
                        layoutOverride: ScreenLayout? = nil) -> DraftSnapshot {
        let started = CFAbsoluteTimeGetCurrent()

        guard let raster = ImageDescriptor.rasterize(image, maxSide: workingMaxSide) else {
            return DraftSnapshot(kind: .blindPick, mode: nil, modeJa: nil,
                                 map: nil, mapScore: 0, mapMargin: 0, bans: [], allies: [],
                                 enemies: [], phase: .blind(filled: 0, total: 3), layoutName: "-",
                                 elapsed: CFAbsoluteTimeGetCurrent() - started)
        }
        let size = CGSize(width: raster.width, height: raster.height)
        if let layoutOverride {
            return analyze(raster: raster, size: size, layout: layoutOverride, rules: rules, started: started)
        }
        // ブラインドピックと BAN ありの画面は見た目がまったく違うので、
        // 画面の種類ごとにいちばん縦横比が近い配置を試して、よく読めた方を採用する。
        var layouts = LayoutStore.load().candidates(for: size)
        if layouts.isEmpty {
            layouts = [size.width >= size.height ? .builtInLandscape : .builtInPortrait]
        }
        let results = layouts.map {
            analyze(raster: raster, size: size, layout: $0, rules: rules, started: started)
        }
        return results.max { confidence($0) < confidence($1) }!
    }

    /// どれだけ読めたか。キャラの一致度の合計に、ステージ・モードが読めた分を足す。
    private static func confidence(_ s: DraftSnapshot) -> Float {
        (s.bans + s.allies + s.enemies).reduce(0) { $0 + $1.score }
            + (s.map != nil ? 1.5 : 0) + (s.mode != nil ? 1 : 0)
            + (s.phase == .ban ? 2 : 0)
    }

    private static func analyze(raster: ImageRaster, size: CGSize, layout: ScreenLayout,
                                rules: LoadedRules, started: CFAbsoluteTime) -> DraftSnapshot {
        switch layout.kind {
        case .blindPick:
            return analyzeBlindPick(raster: raster, size: size, layout: layout,
                                    rules: rules, started: started)
        case .draftPick:
            return analyzeDraftPick(raster: raster, size: size, layout: layout,
                                    rules: rules, started: started)
        }
    }

    // MARK: - ブラインドピック（エリート未満）

    private static func analyzeBlindPick(raster: ImageRaster, size: CGSize, layout: ScreenLayout,
                                         rules: LoadedRules, started: CFAbsoluteTime) -> DraftSnapshot {
        var taken = Set<Int>()
        let allies = detect(slots: layout.allySlots, raster: raster, size: size,
                            rules: rules, taken: &taken)

        // 相手はこの画面では最後まで「?」のまま。走査しても意味がないので、
        // layout が enemyVisible=true と申告している（公開後などの）場合だけ試みる。
        let enemies: [DetectedBrawler]
        if layout.enemyVisible {
            enemies = detect(slots: layout.enemySlots, raster: raster, size: size,
                             rules: rules, taken: &taken)
        } else {
            enemies = []
        }

        var mode: String?
        var modeJa: String?
        var map: MapRules?
        if let region = layout.modeTextRegion {
            let stage = ModeRecognizer.recognizeStage(in: raster, region: region, rules: rules)
            mode = stage.mode
            map = stage.map
            modeJa = map?.modeJa ?? mode.flatMap { rules.document.modes[$0]?.ja }
            // マップが特定できたら、そのマップが属するモードで上書きする
            // （モード名の OCR に失敗していても、マップ名だけ読めれば十分特定できる）。
            if let map { mode = map.mode }
        }

        let phase = DraftPhase.blind(filled: allies.count, total: layout.allySlots.count)

        return DraftSnapshot(
            kind: .blindPick, mode: mode, modeJa: modeJa,
            map: map, mapScore: map != nil ? 1 : 0, mapMargin: 0,
            bans: [], allies: allies, enemies: enemies,
            phase: phase, layoutName: layout.name,
            elapsed: CFAbsoluteTimeGetCurrent() - started
        )
    }

    // MARK: - BAN + 順次公開（エリート以上、未検証）

    private static func analyzeDraftPick(raster: ImageRaster, size: CGSize, layout: ScreenLayout,
                                         rules: LoadedRules, started: CFAbsoluteTime) -> DraftSnapshot {
        var mode: String?
        var map: MapRules?
        var mapScore: Float = 0
        var mapMargin: Float = 0
        // 画面上部の文字（モード名・ステージ名）が読めれば、絵の照合より確実
        if let region = layout.modeTextRegion {
            let stage = ModeRecognizer.recognizeStage(in: raster, region: region, rules: rules)
            mode = stage.map?.mode ?? stage.mode
            if let m = stage.map {
                map = m
                mapScore = 1
                mapMargin = 1
            }
        }
        if map == nil, let mapRect = layout.mapPreview {
            let hit = search(raster: raster, size: size, rect: mapRect,
                             matcher: rules.mapMatcher, excluding: [])
            if let m = hit.result, m.score >= TemplateMatcher.acceptScore {
                map = rules.map(id: m.id)
                mapScore = m.score
                mapMargin = m.margin
            }
        }

        var taken = Set<Int>()
        let bans = detect(slots: layout.banSlots, raster: raster, size: size,
                          rules: rules, taken: &taken)
        let allies = detect(slots: layout.allySlots, raster: raster, size: size,
                            rules: rules, taken: &taken)
        let enemies = layout.enemyVisible
            ? detect(slots: layout.enemySlots, raster: raster, size: size, rules: rules, taken: &taken)
            : []

        let isBanTurn = layout.phaseTextRegion.map {
            ModeRecognizer.recognizeText(in: raster, region: $0).contains("禁止")
        } ?? false
        let phase = isBanTurn
            ? .ban
            : DraftPhase.from(pickedCount: allies.count + enemies.count,
                              banCount: bans.count,
                              expectedBans: layout.banSlots.count)

        return DraftSnapshot(
            kind: .draftPick, mode: mode,
            modeJa: map?.modeJa ?? mode.flatMap { rules.document.modes[$0]?.ja },
            map: map, mapScore: mapScore, mapMargin: mapMargin,
            bans: bans, allies: allies, enemies: enemies,
            phase: phase, layoutName: layout.name,
            elapsed: CFAbsoluteTimeGetCurrent() - started
        )
    }

    // MARK: - 共通部品

    private static func detect(slots: [NRect], raster: ImageRaster, size: CGSize,
                               rules: LoadedRules, taken: inout Set<Int>) -> [DetectedBrawler] {
        var found: [DetectedBrawler] = []
        for (index, slot) in slots.enumerated() {
            let hit = search(raster: raster, size: size, rect: slot,
                             matcher: rules.brawlerMatcher, excluding: taken)
            guard let result = hit.result, let contrast = hit.contrast else { continue }
            // 誰も選んでいない枠（「?」プレースホルダ）は平坦な絵になるので落とす
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

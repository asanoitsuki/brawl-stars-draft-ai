import Foundation

/// 対話モードのAIコア演出（`DynamicCoreImage`）が使う、時間経過とパルスだけの
/// 軽量な状態管理。`View` の再生成をまたいで状態を持つため参照型。
///
/// あえて `@Observable` にしていない。毎フレーム `TimelineView` の描画クロージャの
/// 中でプロパティを書き換えるため、もし Observable にすると「body 評価中に監視対象の
/// プロパティを書き換える」形になり、SwiftUI が再描画→書き換え→再描画…と
/// 連鎖する再描画ストームを起こしうる（実機で「対話を始める」を押すと画面が
/// 固まる不具合の原因だった）。再描画は `TimelineView(.animation)` 側のスケジュールだけに
/// 任せれば十分なので、ここは監視対象にしない。
final class ParticleEngine {
    private(set) var currentEnergy: Double = 0.22
    private(set) var phase: Double = 0
    /// 吸い込み粒子用の、スケールしていない生の経過秒数。
    private(set) var elapsedSeconds: Double = 0
    private var lastDate: Date?

    private struct Pulse { let start: Date }
    private var pulseHistory: [Pulse] = []
    private var lastTargetForPulse: Double = 0.22

    /// 中心に向かって吸い込まれていく粒子。1 個ずつ `period` 秒かけて外周から
    /// 中心まで渦を巻きながら落ちて消え、`phaseOffset` でずらすことで
    /// 途切れず次々と吸い込まれているように見せる。
    struct AbsorbParticle {
        let angle0: Double
        let period: Double
        let phaseOffset: Double
        let spin: Double
        let size: Double
        let colorIndex: Int
    }
    let absorbParticles: [AbsorbParticle]

    init(absorbCount: Int = 46) {
        var built: [AbsorbParticle] = []
        for i in 0..<absorbCount {
            let angle0: Double = Double.random(in: 0...(2 * .pi))
            let period: Double = Double.random(in: 3.2...7.0)
            let phaseOffset: Double = Double(i) / Double(absorbCount) * period
                + Double.random(in: 0...(period * 0.3))
            let spin: Double = Double.random(in: 1.4...3.2) * (i % 2 == 0 ? 1 : -1)
            let size: Double = Double.random(in: 1.4...3.4)
            let colorIndex: Int = i % 3
            built.append(AbsorbParticle(
                angle0: angle0, period: period, phaseOffset: phaseOffset,
                spin: spin, size: size, colorIndex: colorIndex
            ))
        }
        absorbParticles = built
    }

    func advance(to date: Date, target: Double) {
        let dt = lastDate.map { date.timeIntervalSince($0) } ?? 0
        lastDate = date
        phase += dt * 6
        elapsedSeconds += dt
        currentEnergy += (target - currentEnergy) * min(1, dt * 3.0)

        if target > lastTargetForPulse + 0.15 {
            pulseHistory.append(Pulse(start: date))
        }
        lastTargetForPulse = target
        pulseHistory.removeAll { date.timeIntervalSince($0.start) > 1.2 }
    }

    struct DrawnPulse { let radius: Double; let opacity: Double }
    func pulses(now: Double) -> [DrawnPulse] {
        guard let last = lastDate else { return [] }
        return pulseHistory.compactMap { p in
            let t = last.timeIntervalSince(p.start)
            guard t >= 0, t <= 1.2 else { return nil }
            let progress = t / 1.2
            return DrawnPulse(radius: 40 + progress * 260, opacity: max(0, 0.5 * (1 - progress)))
        }
    }
}

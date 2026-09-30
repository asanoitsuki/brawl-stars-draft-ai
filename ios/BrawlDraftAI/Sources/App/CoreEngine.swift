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
    private var lastDate: Date?

    private struct Pulse { let start: Date }
    private var pulseHistory: [Pulse] = []
    private var lastTargetForPulse: Double = 0.22

    func advance(to date: Date, target: Double) {
        let dt = lastDate.map { date.timeIntervalSince($0) } ?? 0
        lastDate = date
        phase += dt * 6
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

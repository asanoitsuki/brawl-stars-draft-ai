import SwiftUI

/// 対話モードの背景。参考アプリの「暗い宇宙空間に淡い星が瞬く」雰囲気を、
/// 画面全体の控えめな土台として敷く（主役の演出は `AICoreOrb` 側）。
struct SpaceBackdrop: View {
    @State private var stars: [Star] = Star.generate(count: 70)

    struct Star {
        let x: Double // 0...1
        let y: Double
        let size: Double
        let baseOpacity: Double
        let seed: Double
        let twinkleSpeed: Double

        static func generate(count: Int) -> [Star] {
            var result: [Star] = []
            for _ in 0..<count {
                result.append(Star(
                    x: Double.random(in: 0...1), y: Double.random(in: 0...1),
                    size: Double.random(in: 0.6...1.8),
                    baseOpacity: Double.random(in: 0.15...0.55),
                    seed: Double.random(in: 0...(2 * .pi)),
                    twinkleSpeed: Double.random(in: 0.2...0.6)
                ))
            }
            return result
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for s in stars {
                    let twinkle = 0.4 + 0.6 * (0.5 + 0.5 * sin(t * s.twinkleSpeed + s.seed))
                    var c = context
                    c.opacity = s.baseOpacity * twinkle
                    let r = s.size
                    let pos = CGPoint(x: s.x * size.width, y: s.y * size.height)
                    var p = Path()
                    p.addEllipse(in: CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2))
                    c.fill(p, with: .color(.white))
                }
            }
            .background(
                LinearGradient(
                    colors: [Color(red: 0.03, green: 0.03, blue: 0.08), Color(red: 0.08, green: 0.06, blue: 0.16)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .ignoresSafeArea()
        }
    }
}

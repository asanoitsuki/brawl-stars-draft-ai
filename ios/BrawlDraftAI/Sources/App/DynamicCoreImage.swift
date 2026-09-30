import SwiftUI
import UIKit

/// ユーザー本人が作成した「光る球体」の静止画（`Resources/AICore/ai_core.jpg`）を土台に、
/// ゆっくりズーム・パン・回転させて、静止画のままでも生きているように見せる
/// 対話モードのAIコア演出。`energy`（0…1）で輝き・脈動を、`pulses` で話者交代の
/// ソナー風リングを表現する。
struct DynamicCoreImage: View {
    var energy: Double
    var accent: Color = .cyan

    @State private var engine = ParticleEngine()
    private static let image: UIImage? = {
        guard let url = Bundle.main.url(forResource: "ai_core", withExtension: "jpg") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = advancedPhase(at: timeline.date)

            GeometryReader { geo in
                let w = geo.size.width
                let zoom = 1.12 + sin(t * 0.05) * 0.05
                let panX = sin(t * 0.037) * w * 0.025
                let panY = cos(t * 0.029) * w * 0.02
                let rot = sin(t * 0.02) * 2.5
                let glow = 0.35 + energy * 0.35

                ZStack {
                    coreImage
                        .frame(width: w, height: w)
                        .scaleEffect(zoom)
                        .offset(x: panX, y: panY)
                        .rotationEffect(.degrees(rot))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(accent.opacity(glow), lineWidth: 2))
                        .shadow(color: accent.opacity(glow), radius: 16 + energy * 12)

                    ForEach(Array(engine.pulses(now: t).enumerated()), id: \.offset) { _, p in
                        let d = p.radius * 2 * (w / 720)
                        Circle()
                            .stroke(accent, lineWidth: 2)
                            .frame(width: d, height: d)
                            .opacity(p.opacity)
                    }
                }
                .frame(width: w, height: geo.size.height)
                .position(x: w / 2, y: geo.size.height / 2)
            }
        }
    }

    /// `TimelineView` の中身は `@ViewBuilder` なので、Void を返すだけの文を
    /// そのまま書くと「View を返す式」として扱われてビルドエラーになる。
    /// `let` 束縛越しに呼ぶことでその扱いを避けている。
    private func advancedPhase(at date: Date) -> Double {
        engine.advance(to: date, target: energy)
        return engine.phase
    }

    @ViewBuilder
    private var coreImage: some View {
        if let image = Self.image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            // 画像がバンドルに無い場合の保険（ビルド漏れ等）
            Circle().fill(RadialGradient(
                colors: [.white, accent, .clear], center: .center, startRadius: 0, endRadius: 140))
        }
    }
}

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

                    // 周囲から中心へ、渦を巻きながら吸い込まれていく粒子。
                    // 円の外から見え始め、コアに触れる瞬間に一瞬光って消える。
                    Canvas { context, size in
                        drawAbsorption(context: context, size: size, elapsed: engine.elapsedSeconds)
                    }
                    .frame(width: w, height: w)

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

    private func drawAbsorption(context: GraphicsContext, size: CGSize, elapsed: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rMax = size.width * 0.78
        let colors = [accent, Color.white, Color.purple]

        for p in engine.absorbParticles {
            let tt = ((elapsed + p.phaseOffset).truncatingRemainder(dividingBy: p.period)) / p.period
            // 中心に近づくほど加速するイージング（吸い込まれる感じ）
            let radius = rMax * pow(1 - tt, 0.6)
            let angle = p.angle0 + tt * p.spin
            let pos = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))

            let fadeIn = min(1, tt / 0.08)
            let flash = tt > 0.88 ? (tt - 0.88) / 0.12 : 0
            let opacity = fadeIn * (1 - flash * 0.3) // 消える直前だけ少し明るく張り出す
            guard opacity > 0.02 else { continue }

            let baseSize = p.size * (1 - tt * 0.55) + flash * p.size * 1.6
            var path = Path(ellipseIn: CGRect(
                x: pos.x - baseSize, y: pos.y - baseSize, width: baseSize * 2, height: baseSize * 2))
            var c = context
            c.opacity = opacity
            c.fill(path, with: .color(colors[p.colorIndex]))
        }
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

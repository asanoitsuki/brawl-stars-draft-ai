import SwiftUI

/// 対話モードの「AIコア」演出。中空のグラデーションリングの周りに、淡い軌道リングと
/// 常時流れ込む粒子、そして時々外周から飛んでくる「流れ星」が中心に吸い込まれて
/// 消える——宇宙空間でブラックホールに星が落ちていくようなイメージ。
/// `energy`（0…1）で輝き・脈動を、`pulses` で話者交代のソナー風リングを表現する。
struct AICoreOrb: View {
    var energy: Double
    var accent: Color = .cyan

    @State private var engine = ParticleEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = advancedPhase(at: timeline.date)

            GeometryReader { geo in
                let w = geo.size.width
                let glow = 0.4 + energy * 0.35
                let ringR = w * 0.32

                ZStack {
                    // 淡い軌道リング（ゆっくり回転するだけの装飾）
                    orbitRings(w: w, t: t)

                    // 外周から中心へ、渦を巻きながら常時流れ込む粒子
                    Canvas { context, size in
                        drawAbsorption(context: context, size: size, elapsed: engine.elapsedSeconds)
                    }
                    .frame(width: w, height: w)

                    // 不定期に外周から飛んでくる「流れ星」
                    Canvas { context, size in
                        drawMeteors(context: context, size: size)
                    }
                    .frame(width: w, height: w)

                    // 中心の中空グラデーションリング
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [.cyan, .purple, .pink, .cyan],
                                center: .center, angle: .degrees(t * 6)
                            ),
                            lineWidth: max(2, w * 0.018)
                        )
                        .background(
                            Circle().fill(RadialGradient(
                                colors: [accent.opacity(0.35 + energy * 0.25), .clear],
                                center: .center, startRadius: 0, endRadius: ringR
                            ))
                        )
                        .frame(width: ringR * 2, height: ringR * 2)
                        .shadow(color: accent.opacity(glow), radius: 14 + energy * 14)

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

    private func orbitRings(w: Double, t: Double) -> some View {
        ZStack {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 10]))
                .foregroundStyle(.white.opacity(0.18))
                .frame(width: w * 0.86, height: w * 0.86)
                .rotationEffect(.degrees(t * 1.1))
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [1, 7]))
                .foregroundStyle(.white.opacity(0.12))
                .frame(width: w * 0.62, height: w * 0.62)
                .rotationEffect(.degrees(-t * 1.6))
        }
    }

    private func drawAbsorption(context: GraphicsContext, size: CGSize, elapsed: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rMax = size.width * 0.44
        let colors = [accent, Color.white, Color.purple]

        for p in engine.absorbParticles {
            let tt = ((elapsed + p.phaseOffset).truncatingRemainder(dividingBy: p.period)) / p.period
            let radius = rMax * pow(1 - tt, 0.6)
            let angle = p.angle0 + tt * p.spin
            let pos = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))

            let fadeIn = min(1, tt / 0.08)
            let flash = tt > 0.88 ? (tt - 0.88) / 0.12 : 0
            let opacity = fadeIn * (1 - flash * 0.3)
            guard opacity > 0.02 else { continue }

            let baseSize = p.size * (1 - tt * 0.55) + flash * p.size * 1.6
            var path = Path(ellipseIn: CGRect(
                x: pos.x - baseSize, y: pos.y - baseSize, width: baseSize * 2, height: baseSize * 2))
            var c = context
            c.opacity = opacity
            c.fill(path, with: .color(colors[p.colorIndex]))
        }
    }

    private func drawMeteors(context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radiusScale = size.width / 2
        for m in engine.drawnMeteors() {
            guard m.opacity > 0.02 else { continue }
            let head = CGPoint(x: center.x + m.head.x * radiusScale, y: center.y + m.head.y * radiusScale)
            let tail = CGPoint(x: center.x + m.tail.x * radiusScale, y: center.y + m.tail.y * radiusScale)

            var line = Path()
            line.move(to: tail)
            line.addLine(to: head)
            var lineLayer = context
            lineLayer.opacity = m.opacity * 0.8
            lineLayer.stroke(line, with: .color(.white), lineWidth: 1.6)

            let headSize: Double = 3
            var headPath = Path(ellipseIn: CGRect(
                x: head.x - headSize, y: head.y - headSize, width: headSize * 2, height: headSize * 2))
            var headLayer = context
            headLayer.opacity = m.opacity
            headLayer.fill(headPath, with: .color(.white))
        }
    }
}

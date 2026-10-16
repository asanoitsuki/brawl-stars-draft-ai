import SwiftUI

/// 募集カードのまわりに出る、炎のようにうねるオーラ。
///
/// * 投稿された瞬間: 枠から光の輪がはじけるように広がる
/// * そのあと: 枠の外側で光の帯がウネウネ波打ち、色が枠を一周するように流れる
/// * 「あと1人」: 波が大きく速く、赤〜黄の炎色で火花も散る。時間が経っても消えずに燃え続ける
/// * 「あと2人」: 細く穏やかな波で、1 分ほどで静まる
struct AuraGlow: View {
    let post: TeamPost
    let tint: Color

    /// 光をカードの外へにじませる幅
    static let spill: CGFloat = 22
    private let corner: CGFloat = 20

    private var urgent: Bool { post.slots == 1 }
    private var fadeSeconds: Double { urgent ? 180 : 60 }

    var body: some View {
        let age = Date().timeIntervalSince(post.createdAt)
        if urgent || age < fadeSeconds {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                Canvas { gc, size in
                    draw(in: &gc, size: size, now: context.date)
                }
            }
            .padding(-Self.spill)
            .allowsHitTesting(false)
        }
    }

    // MARK: - 描画

    private func draw(in gc: inout GraphicsContext, size: CGSize, now: Date) {
        let age = max(0, now.timeIntervalSince(post.createdAt))
        let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
        let card = CGRect(origin: .zero, size: size).insetBy(dx: Self.spill, dy: Self.spill)

        // 強さ: 投稿直後が最大 → 静まる。あと1人は下限があり、ずっと燃える
        let fresh = max(0, 1 - age / fadeSeconds)
        let strength = urgent ? max(0.55, fresh) : fresh * 0.75
        guard strength > 0.01 else { return }

        let colors: [Color] = urgent
            ? [.red, .orange, .yellow, .orange, .pink, .red]
            : [tint, tint.opacity(0.35), .white.opacity(0.6), tint.opacity(0.35), tint]
        let amplitude: CGFloat = urgent ? 15 : 7
        let speed = urgent ? 3.0 : 1.6

        let rotation = Angle.radians(t * (urgent ? 1.4 : 0.6))
        let shading = GraphicsContext.Shading.conicGradient(
            Gradient(colors: colors),
            center: CGPoint(x: card.midX, y: card.midY),
            angle: rotation
        )

        // 1) 太くぼかした波（外側のにじみ）
        var glow = gc
        glow.addFilter(.blur(radius: urgent ? 7 : 5))
        glow.opacity = 0.8 * strength
        glow.stroke(wavyPath(card, amplitude: amplitude, waves: urgent ? 9 : 6, phase: t * speed, offset: 3),
                    with: shading, lineWidth: urgent ? 9 : 6)

        // 2) 逆向きに流れる、くっきりした波（炎の舌のように尖らせる）
        var mid = gc
        mid.addFilter(.blur(radius: 0.8))
        mid.opacity = 0.95 * strength
        mid.stroke(wavyPath(card, amplitude: amplitude * 0.8, waves: urgent ? 13 : 9, phase: -t * speed * 1.3, offset: 1.5),
                   with: shading, lineWidth: urgent ? 2.2 : 1.4)

        // 3) さらに別の速さで流れる細い波（重なりでウネウネを強く見せる）
        var thin = gc
        thin.addFilter(.blur(radius: 1.6))
        thin.opacity = 0.7 * strength
        thin.stroke(wavyPath(card, amplitude: amplitude * 0.55, waves: urgent ? 17 : 12, phase: t * speed * 1.9 + 2, offset: 1),
                    with: shading, lineWidth: urgent ? 1.6 : 1)

        // 4) 枠そのもののくっきりした光
        var rim = gc
        rim.opacity = min(1, 0.6 + strength)
        rim.stroke(Path(roundedRect: card, cornerRadius: corner, style: .continuous),
                   with: shading, lineWidth: 1.6)

        // 5) 投稿された瞬間: 光の輪がはじける
        if age < 2.2 {
            let p = age / 2.2
            let grow = CGFloat(p) * Self.spill * 0.95
            var burst = gc
            burst.addFilter(.blur(radius: 3 + 6 * p))
            burst.opacity = (1 - p) * 0.95
            burst.stroke(Path(roundedRect: card.insetBy(dx: -grow, dy: -grow),
                              cornerRadius: corner + grow, style: .continuous),
                         with: .color(urgent ? .yellow : .white), lineWidth: 3 * (1 - p) + 1)
        }

        // 6) あと1人: 枠から火花が舞い上がる
        if urgent {
            drawSparks(in: &gc, card: card, t: t, strength: strength)
        }
    }

    /// 角丸四角の外周を、法線方向に sin 波で揺らした閉じた線。
    private func wavyPath(_ rect: CGRect, amplitude: CGFloat, waves: Double, phase: Double, offset: CGFloat) -> Path {
        let samples = 180
        var path = Path()
        for i in 0...samples {
            let s = Double(i) / Double(samples)
            let (p, n) = perimeterPoint(rect, radius: corner, s: s)
            // 2 つの波を重ねて単調にならないようにする
            let w = 0.65 * sin(2 * .pi * waves * s + phase) + 0.35 * sin(2 * .pi * (waves * 1.7) * s - phase * 1.6 + 1.3)
            // 山を尖らせて「炎の舌」にする（谷は枠に沿い、山だけ外へ伸びる）
            let tongue = pow(0.5 + 0.5 * w, 2.2)
            let d = offset + amplitude * CGFloat(tongue)
            let q = CGPoint(x: p.x + n.dx * d, y: p.y + n.dy * d)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        return path
    }

    private func drawSparks(in gc: inout GraphicsContext, card: CGRect, t: Double, strength: Double) {
        var sparks = gc
        sparks.addFilter(.blur(radius: 0.6))
        let count = 14
        for k in 0..<count {
            let seed = Double(k) * 12.9898
            let speed = 0.12 + 0.08 * fract(sin(seed) * 43758.5)
            let life = fract(t * 0.55 + fract(sin(seed * 1.7) * 9631.1))   // 0→1 で生まれて消える
            let s = fract(fract(sin(seed * 3.1) * 1731.7) + t * speed)
            let (p, n) = perimeterPoint(card, radius: corner, s: s)
            let lift = CGFloat(life) * (Self.spill - 4)
            let center = CGPoint(x: p.x + n.dx * (4 + lift), y: p.y + n.dy * (4 + lift) - CGFloat(life) * 4)
            let r = CGFloat(2.4 * (1 - life) + 0.6)
            sparks.opacity = (1 - life) * strength
            sparks.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: .color(k % 3 == 0 ? .white : .yellow))
        }
    }

    private func fract(_ x: Double) -> Double { x - x.rounded(.down) }

    /// 角丸四角の外周上の点と外向き法線（s: 0..1 で一周）。
    private func perimeterPoint(_ r: CGRect, radius: CGFloat, s: Double) -> (CGPoint, CGVector) {
        let rad = min(radius, min(r.width, r.height) / 2)
        let w = r.width - 2 * rad, h = r.height - 2 * rad
        let arc = .pi / 2 * rad
        let total = 2 * (w + h) + 4 * arc
        var d = CGFloat(s) * total

        func corner(_ cx: CGFloat, _ cy: CGFloat, _ start: CGFloat, _ len: CGFloat) -> (CGPoint, CGVector) {
            let a = start + (len / arc) * (.pi / 2)
            return (CGPoint(x: cx + rad * cos(a), y: cy + rad * sin(a)), CGVector(dx: cos(a), dy: sin(a)))
        }

        // 上辺（左→右）
        if d < w { return (CGPoint(x: r.minX + rad + d, y: r.minY), CGVector(dx: 0, dy: -1)) }
        d -= w
        if d < arc { return corner(r.maxX - rad, r.minY + rad, -.pi / 2, d) }
        d -= arc
        if d < h { return (CGPoint(x: r.maxX, y: r.minY + rad + d), CGVector(dx: 1, dy: 0)) }
        d -= h
        if d < arc { return corner(r.maxX - rad, r.maxY - rad, 0, d) }
        d -= arc
        if d < w { return (CGPoint(x: r.maxX - rad - d, y: r.maxY), CGVector(dx: 0, dy: 1)) }
        d -= w
        if d < arc { return corner(r.minX + rad, r.maxY - rad, .pi / 2, d) }
        d -= arc
        if d < h { return (CGPoint(x: r.minX, y: r.maxY - rad - d), CGVector(dx: -1, dy: 0)) }
        d -= h
        return corner(r.minX + rad, r.minY + rad, .pi, min(d, arc))
    }
}

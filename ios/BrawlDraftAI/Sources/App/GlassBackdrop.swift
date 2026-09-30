import SwiftUI

/// グラスモーフィズム背景。暗いグラデーションの上に、ぼかした色付きの「ブロブ」を
/// ゆっくり漂わせる。カード類はこの上に `.ultraThinMaterial` を重ねて浮かせる。
struct GlassBackdrop: View {
    var colors: [Color] = [.cyan, .purple, .green]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.06, blue: 0.14), Color(red: 0.10, green: 0.09, blue: 0.22)],
                    startPoint: .top, endPoint: .bottom
                )
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    let speed = 0.08 + Double(index) * 0.03
                    let angle = t * speed + Double(index) * 2.4
                    Circle()
                        .fill(color.opacity(0.35))
                        .frame(width: 320, height: 320)
                        .blur(radius: 70)
                        .offset(x: cos(angle) * 120, y: sin(angle * 0.8) * 180 + Double(index) * 40 - 60)
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// フロストガラス風のカード修飾子。
struct GlassCard: ViewModifier {
    var tint: Color = .white
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.55), lineWidth: 1.2)
            )
            .shadow(color: tint.opacity(0.25), radius: 16, y: 6)
    }
}

extension View {
    func glassCard(tint: Color = .white, cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassCard(tint: tint, cornerRadius: cornerRadius))
    }
}

import SwiftUI

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

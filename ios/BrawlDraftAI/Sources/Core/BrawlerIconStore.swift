import SwiftUI

/// キャラの丸角アイコン。既定は自作（ID から決まる色と頭文字）。個人用ビルドは本物の画像を重ねる。
/// （同じキャラは常に同じ色になる。）
struct BrawlerIcon: View {
    let id: Int
    var size: CGFloat = 40

    private var hue: Double {
        // ID を散らして、隣り合うキャラでも色が離れるようにする
        Double((id &* 2_654_435_761) % 360) / 360
    }

    private var initial: String {
        guard let name = BrawlerNameRegistry.names[id], let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95),
                                    Color(hue: hue, saturation: 0.75, brightness: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: size * 0.9, height: size * 0.9)
                .offset(x: size * 0.28, y: -size * 0.3)
            Text(initial)
                .font(.system(size: size * 0.5, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: size * 0.03)
        }
        .frame(width: size, height: size)
        .gameArt("brawlers/borders/\(id)")
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(.black.opacity(0.35), lineWidth: 1))
    }
}

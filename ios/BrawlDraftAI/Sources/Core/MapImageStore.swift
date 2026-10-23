import SwiftUI

/// マップを表す自作のサムネイル。ゲームの画像は使わず、ID から決まる色と格子で描く。
struct MapThumbnail: View {
    let id: Int
    var cornerRadius: CGFloat = 8
    /// 詳細画面用は縦横比を保って中央に置く。一覧用は枠いっぱいに敷く。
    var fit = false

    private var hue: Double { Double((id &* 2_654_435_761) % 360) / 360 }

    var body: some View {
        GeometryReader { geo in
            let w = fit ? min(geo.size.width, geo.size.height * 0.75) : geo.size.width
            let h = fit ? geo.size.height : geo.size.height
            ZStack {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.55),
                                        Color(hue: hue, saturation: 0.7, brightness: 0.3)],
                               startPoint: .top, endPoint: .bottom)
                Canvas { ctx, size in
                    let step = max(size.width / 6, 6)
                    var path = Path()
                    var x = step
                    while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                    var y = step
                    while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                    ctx.stroke(path, with: .color(.white.opacity(0.1)), lineWidth: 1)
                }
                Image(systemName: "map.fill")
                    .font(.system(size: min(w, h) * 0.34, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

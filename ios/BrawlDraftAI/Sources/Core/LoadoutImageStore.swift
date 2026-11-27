import SwiftUI

/// ガジェット / スターパワーを表す自作のアイコン。ゲームの画像は使わず、種別のシンボルで描く。
/// `filename` の先頭文字（g = ガジェット / s = スターパワー）で種別を決める。
struct LoadoutIcon: View {
    let filename: String?
    var size: CGFloat = 44

    private var isGadget: Bool { filename?.hasPrefix("g") ?? false }

    /// "g23000255" → "gadgets/regular/23000255"
    private var artPath: String? {
        filename.map { "\(isGadget ? "gadgets" : "star-powers")/regular/\($0.dropFirst())" }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: isGadget
                           ? [Color(red: 0.25, green: 0.8, blue: 0.5), Color(red: 0.1, green: 0.5, blue: 0.35)]
                           : [Color(red: 1, green: 0.78, blue: 0.2), Color(red: 0.85, green: 0.45, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: isGadget ? "bolt.fill" : "star.fill")
                .font(.system(size: size * 0.5, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 1)
        }
        .frame(width: size, height: size)
        .gameArt(artPath, background: .black.opacity(0.001))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        .overlay(RoundedRectangle(cornerRadius: size * 0.2).strokeBorder(.black.opacity(0.35), lineWidth: 1))
    }
}

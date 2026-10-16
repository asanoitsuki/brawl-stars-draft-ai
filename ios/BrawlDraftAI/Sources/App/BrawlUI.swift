import SwiftUI
import UIKit

extension RankTier {
    private static var cache: [Int: UIImage] = [:]

    /// ブロスタ実物のランクアイコン（cdn.brawlify.com/ranked/tiered/58000000〜58000021.png を
    /// `Resources/RankIcons/rank_<id>.png` として同梱）。
    static func image(_ tier: Int) -> UIImage? {
        guard (1...count).contains(tier) else { return nil }
        if let cached = cache[tier] { return cached }
        let id = 58_000_000 + tier - 1
        guard let url = Bundle.main.url(forResource: "rank_\(id)", withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache[tier] = image
        return image
    }
}

/// ランクのアイコン（ブロスタの実物）＋名前。
struct RankBadge: View {
    let tier: Int
    var size: CGFloat = 22
    var showsLabel = true

    var body: some View {
        HStack(spacing: 4) {
            if let image = RankTier.image(tier) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: size)
            }
            if showsLabel {
                Text(RankTier.label(tier))
                    .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// ブロスタ風のトロフィー数（黒フチの金色トロフィー＋太字の数字）。
struct TrophyLabel: View {
    let trophies: Int
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Image(systemName: "trophy.fill")
                    .font(.system(size: size, weight: .black))
                    .foregroundStyle(.black)
                    .offset(y: 1)
                Image(systemName: "trophy.fill")
                    .font(.system(size: size, weight: .black))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(red: 1, green: 0.9, blue: 0.35), Color(red: 1, green: 0.66, blue: 0.1)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            Text(trophies.formatted())
                .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 0, x: 0, y: 1)
        }
    }
}

/// ランクをアイコンの一覧から選ぶ（ブロスタのランク画面のように並べる）。
struct RankPicker: View {
    @Binding var tier: Int

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(1...RankTier.count, id: \.self) { t in
                Button {
                    tier = t
                } label: {
                    VStack(spacing: 2) {
                        RankBadge(tier: t, size: 34, showsLabel: false)
                        Text(RankTier.label(t))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(tier == t ? Color.yellow.opacity(0.25) : Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(tier == t ? Color.yellow : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

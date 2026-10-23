import SwiftUI
import UIKit

/// ランクを表す自作のエンブレム（盾の形＋段位の色＋ローマ数字）。ゲームの画像は使わない。
struct RankEmblem: View {
    let tier: Int
    var height: CGFloat = 22

    private static let palette: [(Color, Color)] = [
        (Color(red: 0.80, green: 0.50, blue: 0.28), Color(red: 0.50, green: 0.28, blue: 0.14)),   // ブロンズ
        (Color(red: 0.85, green: 0.88, blue: 0.93), Color(red: 0.55, green: 0.60, blue: 0.70)),   // シルバー
        (Color(red: 1.00, green: 0.85, blue: 0.30), Color(red: 0.80, green: 0.55, blue: 0.10)),   // ゴールド
        (Color(red: 0.45, green: 0.80, blue: 1.00), Color(red: 0.20, green: 0.45, blue: 0.85)),   // ダイヤモンド
        (Color(red: 0.95, green: 0.45, blue: 0.55), Color(red: 0.65, green: 0.15, blue: 0.35)),   // ミシック
        (Color(red: 1.00, green: 0.62, blue: 0.25), Color(red: 0.80, green: 0.30, blue: 0.10)),   // レジェンド
        (Color(red: 0.70, green: 0.50, blue: 1.00), Color(red: 0.38, green: 0.20, blue: 0.80)),   // マスター
    ]

    var body: some View {
        let group = min((max(tier, 1) - 1) / 3, Self.palette.count - 1)
        let colors = tier == RankTier.count
            ? (Color(red: 0.25, green: 0.25, blue: 0.3), Color.black)
            : Self.palette[group]
        let numeral = tier == RankTier.count ? "P" : ["Ⅰ", "Ⅱ", "Ⅲ"][(max(tier, 1) - 1) % 3]
        ZStack {
            Image(systemName: "shield.fill")
                .resizable().scaledToFit()
                .foregroundStyle(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
            Image(systemName: "shield")
                .resizable().scaledToFit()
                .foregroundStyle(.black.opacity(0.85))
            Text(numeral)
                .font(.system(size: height * 0.4, weight: .black, design: .rounded))
                .foregroundStyle(tier == RankTier.count ? Color.yellow : .white)
                .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: 1)
                .offset(y: -height * 0.03)
        }
        .frame(width: height * 0.9, height: height)
    }
}

/// ランクのアイコン（自作）＋名前。
struct RankBadge: View {
    let tier: Int
    var size: CGFloat = 22
    var showsLabel = true

    var body: some View {
        HStack(spacing: 4) {
            if (1...RankTier.count).contains(tier) {
                RankEmblem(tier: tier, height: size)
            }
            if showsLabel {
                Text(RankTier.label(tier))
                    .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// トロフィー数（黒フチの金色トロフィー＋太字の数字）。
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

/// ランクをアイコンの一覧から選ぶ。
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

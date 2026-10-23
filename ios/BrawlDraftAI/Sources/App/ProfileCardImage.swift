import SwiftUI

/// プロフィールを 1 枚の画像にする（SNS やフレンドへの共有用）。
/// ブロスタのプロフィール画面に寄せて、上にアイコン・名前・トロフィー・ガチバトル、
/// 下に全キャラのトロフィーをタイルで並べる。
struct ProfileCardImage: View {
    let profile: PlayerProfile
    /// 画像に焼き込むため、ネットのアイコンは先に読み込んで渡す（ImageRenderer は非同期読み込みを待たない）
    let icon: UIImage?

    private var grid: [PlayerProfile.TopBrawler] {
        let all = profile.brawlers ?? profile.topBrawlers
        return all.sorted { ($0.trophies ?? 0) > ($1.trophies ?? 0) }
    }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            infoPanels
            if !grid.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(grid) { tile($0) }
                }
            }
            HStack {
                Text("Brawl Board で作成").font(.system(size: 15, weight: .bold))
                Spacer()
                Text(Date().formatted(date: .numeric, time: .shortened)).font(.system(size: 13))
            }
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(28)
        .frame(width: 1080)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.42), Color(red: 0.08, green: 0.06, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            Group {
                if let icon {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    ProfileAvatar(iconID: nil, size: 120)
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.black, lineWidth: 5))

            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name)
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 0, x: 0, y: 3)
                Text(profile.tag).font(.system(size: 24, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                if let club = profile.club {
                    Label(club, systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                bigStat(title: "現在", value: profile.trophies)
                bigStat(title: "最多", value: profile.highestTrophies)
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(.yellow)
                    .offset(x: -40, y: 18)
            }

            VStack(spacing: 10) {
                if let rank = profile.highestRank, rank > 0 {
                    RankBadge(tier: rank, size: 54, showsLabel: false)
                }
                if let v = profile.rankedHighest { bigStat(title: "ガチバトル最高", value: v) }
                if let v = profile.rankedCurrent { bigStat(title: "現在", value: v) }
                if profile.rankedHighest == nil, let rank = profile.highestRank, rank > 0 {
                    Text(RankTier.label(rank)).font(.system(size: 26, weight: .black)).foregroundStyle(.white)
                }
            }
        }
    }

    /// Brawl Insights のように、基本データと育成状況を並べる
    @ViewBuilder
    private var infoPanels: some View {
        let basic = basicLines()
        let growth = growthLines()
        if !basic.isEmpty || !growth.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                if !basic.isEmpty { panel("基本データ", basic) }
                if !growth.isEmpty { panel("育成状況", growth) }
            }
        }
    }

    private func basicLines() -> [(String, String)] {
        var out: [(String, String)] = []
        if let v = profile.expLevel { out.append(("レベル", "\(v)")) }
        if let v = profile.expPoints { out.append(("経験値", v.formatted())) }
        if let v = profile.trioVictories { out.append(("3vs3 勝利数", v.formatted())) }
        if let v = profile.soloVictories { out.append(("ソロ 勝利数", v.formatted())) }
        if let v = profile.duoVictories { out.append(("デュオ 勝利数", v.formatted())) }
        if let v = profile.bestRoboRumbleTime, v > 0 { out.append(("ロボットパニック最高", ProfileSummary.time(v))) }
        if let v = profile.bestTimeAsBigBrawler, v > 0 { out.append(("ビッグブロウラー最高", ProfileSummary.time(v))) }
        return out
    }

    private func growthLines() -> [(String, String)] {
        guard let g = profile.growth else { return [] }
        var out: [(String, String)] = [("ブロウラー", "\(g.owned)")]
        if let v = g.gadgets { out.append(("ガジェット", "\(v)")) }
        if let v = g.starPowers { out.append(("スターパワー", "\(v)")) }
        if let v = g.gears { out.append(("ギア", "\(v)")) }
        if let v = g.hyperCharges { out.append(("ハイパーチャージ", "\(v)")) }
        if let v = g.buffies { out.append(("バフィー", "\(v)")) }
        out.append(("パワー11", "\(g.power11)"))
        if let a = g.averagePower { out.append(("平均パワー", String(format: "%.2f", a))) }
        return out
    }

    private func panel(_ title: String, _ lines: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14).padding(.vertical, 3)
                .background(Color.black.opacity(0.3), in: Capsule())
            ForEach(lines.indices, id: \.self) { i in
                HStack {
                    Text(lines[i].0).font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text(lines[i].1).font(.system(size: 24, weight: .black).monospacedDigit()).foregroundStyle(.white)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bigStat(title: String, value: Int?) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(.white.opacity(0.65))
            Text(value.map { $0.formatted() } ?? "—")
                .font(.system(size: 40, weight: .black).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 0, x: 0, y: 3)
        }
        .frame(minWidth: 180)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    /// キャラ 1 体のタイル。トロフィーが多いほど色が上がる（1000 以上は紫、750 以上は金）
    private func tile(_ b: PlayerProfile.TopBrawler) -> some View {
        let t = b.trophies ?? 0
        let bg: Color = t >= 1000 ? Color(red: 0.42, green: 0.25, blue: 0.75)
            : t >= 750 ? Color(red: 0.78, green: 0.6, blue: 0.2)
            : Color(red: 0.35, green: 0.38, blue: 0.5)
        return ZStack(alignment: .bottomTrailing) {
            HStack {
                BrawlerIcon(id: b.id, size: 64)
                Spacer(minLength: 0)
            }
            Text(String(t))   // 「2,402」ではなく「2402」（カンマが顔にかぶるため）
                .font(.system(size: 24, weight: .black).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 0, x: 0, y: 2)
                .padding(.trailing, 4)
        }
        .padding(5)
        .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.6), lineWidth: 2))
    }
}

/// 「プロフィール画像を作る」ボタン。押すと画像を作って共有シート（保存・LINE・X など）を出す。
struct ProfileShareButton: View {
    let profile: PlayerProfile
    @State private var image: UIImage?
    @State private var making = false

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: 0).task { await autoMakeForScreenshots() }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                ShareLink(item: Image(uiImage: image),
                          preview: SharePreview("\(profile.name) のプロフィール", image: Image(uiImage: image))) {
                    Label("画像を保存・共有", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.yellow, in: Capsule())
                        .foregroundStyle(.black)
                }
            } else {
                Button {
                    Task { await make() }
                } label: {
                    Label(making ? "作成中…" : "プロフィール画像を作る", systemImage: "photo.artframe")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                        .overlay(Capsule().strokeBorder(.yellow.opacity(0.7)))
                }
                .disabled(making)
                if profile.brawlers == nil {
                    Text("全キャラのトロフィー一覧は、ブロスタから自動取得できたときだけ入ります。")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    @MainActor
    private func autoMakeForScreenshots() async {
        #if DEBUG
        // 見た目確認・スクリーンショット撮影用（BDA_DEMO_CARD=1 のとき開いた時点で画像を作る）
        if ProcessInfo.processInfo.environment["BDA_DEMO_CARD"] != nil, image == nil { await make() }
        #endif
    }

    @MainActor
    private func make() async {
        making = true
        defer { making = false }
        let renderer = ImageRenderer(content: ProfileCardImage(profile: profile, icon: nil))
        renderer.scale = 2
        image = renderer.uiImage
    }
}

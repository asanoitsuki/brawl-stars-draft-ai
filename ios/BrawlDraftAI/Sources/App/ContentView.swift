import PhotosUI
import SwiftUI

/// 画面遷移はすべて値ベース（NavigationLink(value:) + navigationDestination）。
/// 常時描画する重いビューを抱える画面があるため、行が見えた時点で遷移先が
/// 先読み構築されると描画ループが裏で回り続けてアプリ全体が固まる（実機で確認済み）。
enum HomeRoute: Hashable {
    case maps
    case brawlers
    case roster
    case settings
    case setup
}

/// ホーム。主役はスクショ解析で、結果もこの画面にそのまま出す。
/// 入りきる端末ではスクロールさせない。
struct ContentView: View {
    @EnvironmentObject private var store: RulesStore
    @ObservedObject private var analysis = AnalysisStore.shared
    @AppStorage("backTapReady") private var backTapReady = false
    @State private var path = NavigationPath()
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                let compact = geo.size.height < 640
                ZStack {
                    CosmosView(mode: .idle,
                               center: CGPoint(x: 0.5, y: compact ? 0.13 : 0.16),
                               radius: compact ? 0.11 : 0.13,
                               framesPerSecond: 30,
                               isPaused: !path.isEmpty || analysis.current != nil)
                        .ignoresSafeArea()
                        // 結果を読むときは背景を沈める
                        .opacity(analysis.current == nil ? 1 : 0.35)
                        .background(Color.black.ignoresSafeArea())

                    ViewThatFits(in: .vertical) {
                        content(compact: compact)
                        ScrollView { content(compact: compact) }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.settings) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel("設定")
                }
                if analysis.current != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("閉じる") { analysis.clear() }
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .maps: MapListView()
                case .brawlers: BrawlerListView()
                case .roster: BrawlerRosterView()
                case .settings: SettingsView()
                case .setup: BackTapSetupView()
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await analyze(item) }
            }
            .alert("解析できませんでした", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .tint(.cyan)
        #if DEBUG
        // 見た目確認用: SIMCTL_CHILD_BDA_ROUTE=setup などで起動すると直接その画面を開く
        .task {
            let routes: [String: HomeRoute] = ["maps": .maps, "settings": .settings, "setup": .setup]
            if let key = ProcessInfo.processInfo.environment["BDA_ROUTE"], let route = routes[key] {
                path.append(route)
            }
            // BDA_ANALYZE=<画像のパス> で起動すると、その画像を解析した状態で開く
            if let file = ProcessInfo.processInfo.environment["BDA_ANALYZE"],
               let image = try? ScreenshotSource.image(atPath: file) {
                do {
                    try await DraftService.analyze(image: image, announce: false)
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func content(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 14) {
            if let current = analysis.current, case .ready(let rules) = store.state {
                ResultCard(analysis: current, rules: rules)
                Spacer(minLength: 0)
            } else {
                // 球体（背景の CosmosView）のぶんの余白
                Color.clear.frame(height: compact ? 96 : 150)
                BrandTitle()
                dataPill
                Spacer(minLength: compact ? 4 : 10)
                Text("ドラフト画面のスクショから、次に取るキャラを判定します")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }

            analyzeButtons
            if !backTapReady { setupCard }
            HStack(spacing: 10) {
                smallTile(.maps, icon: "map.fill", title: "マップ")
                smallTile(.brawlers, icon: "person.crop.square.fill", title: "キャラ")
                smallTile(.roster, icon: "checklist", title: "持ちキャラ")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var dataPill: some View {
        switch store.state {
        case .ready(let rules):
            let q = rules.document.dataQuality
            let measured = (q.battlesAnalyzed ?? 0) > 0
            HStack(spacing: 6) {
                Circle().fill(measured ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(measured
                     ? "ガチバトル実測 \((q.battlesAnalyzed ?? 0).formatted())試合・\(RulesStore.displayDate(q.statsUpdatedAt ?? rules.generatedAt)) 更新"
                     : "推定データ・\(RulesStore.displayDate(rules.generatedAt)) 更新")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial.opacity(0.7), in: Capsule())
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange)
        default:
            ProgressView().tint(.white)
        }
    }

    // MARK: - 解析ボタン（親指が届く下側に大きく置く）

    private var analyzeButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await analyzeLatest() }
            } label: {
                HStack(spacing: 10) {
                    if busy {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(busy ? "解析中…" : "最新のスクショを解析")
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(LinearGradient(colors: [.mint, .cyan], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .cyan.opacity(0.45), radius: 14, y: 4)
            }
            PhotosPicker(selection: $pickedItem, matching: .screenshots) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .glassCard(tint: .cyan, cornerRadius: 18)
            }
            .accessibilityLabel("写真から選ぶ")
        }
        .disabled(busy)
    }

    private var setupCard: some View {
        NavigationLink(value: HomeRoute.setup) {
            HStack(spacing: 12) {
                Image(systemName: "hand.tap.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("背面タップで解析できるようにする")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("ゲームを閉じずに、2回たたくだけ（設定は1回）")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
            }
            .padding(14)
            .glassCard(tint: .purple, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private func smallTile(_ route: HomeRoute, icon: String, title: String) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glassCard(tint: .white.opacity(0.35), cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 実行（画面で結果を見ているので、通知と読み上げは出さない）

    private func analyze(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false; pickedItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            try await DraftService.analyze(data: data, announce: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func analyzeLatest() async {
        busy = true
        defer { busy = false }
        do {
            try await DraftService.analyzeLatestScreenshot(announce: false)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 解析結果。1 位を大きく出し、読み違えたステージはその場で直せる。
struct ResultCard: View {
    let analysis: AnalysisStore.Analysis
    let rules: LoadedRules

    private var snapshot: DraftSnapshot { analysis.snapshot }
    private var recommendation: Recommendation { analysis.recommendation }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let top = recommendation.advices.first {
                topPick(top)
                ForEach(recommendation.advices.dropFirst()) { advice in
                    AdviceRow(advice: advice)
                        .padding(.horizontal, 4)
                }
            } else {
                Text(recommendation.title).font(.title3.weight(.bold))
                Text(recommendation.body).font(.footnote).foregroundStyle(.secondary)
            }

            detected

            if let caution = recommendation.caution {
                Text(caution).font(.caption2).foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(16)
        .glassCard(tint: .cyan, cornerRadius: 24)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(mapsByMode, id: \.mode) { group in
                    Menu(group.mode) {
                        ForEach(group.maps, id: \.id) { map in
                            Button(map.nameJa ?? map.name) {
                                AnalysisStore.shared.correct(map: map, rules: rules)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "map.fill")
                    Text(stageText).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(snapshot.map == nil ? .orange : .white)
            }
            Spacer(minLength: 0)
            Text(analysis.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var stageText: String {
        if let map = snapshot.map { return "\(map.nameJa ?? map.name)・\(map.modeJa)" }
        if let mode = snapshot.modeJa { return "\(mode)（ステージを選ぶ）" }
        return "ステージを選ぶ"
    }

    private var mapsByMode: [(mode: String, maps: [MapRules])] {
        Dictionary(grouping: rules.document.maps.filter(\.inRotation), by: \.modeJa)
            .map { (mode: $0.key, maps: $0.value.sorted { ($0.nameJa ?? $0.name) < ($1.nameJa ?? $1.name) }) }
            .sorted { $0.mode < $1.mode }
    }

    private func topPick(_ advice: PickAdvice) -> some View {
        HStack(spacing: 14) {
            BrawlerIcon(id: advice.id, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.phase == .ban ? "BAN おすすめ" : "おすすめ")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.mint)
                Text(advice.nameJa ?? advice.name)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(advice.reason.isEmpty ? advice.roleJa : advice.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let wr = advice.winRate {
                WinRateBadge(winRate: wr, games: advice.games)
            }
        }
        .padding(12)
        .background(Color.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 画面から読み取ったキャラ。読み違いにすぐ気づけるように並べる。
    @ViewBuilder
    private var detected: some View {
        let groups = [("味方", snapshot.allies), ("相手", snapshot.enemies), ("BAN", snapshot.bans)]
            .filter { !$0.1.isEmpty }
        if groups.isEmpty {
            Text("画面からキャラは読み取れていません")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 14) {
                ForEach(groups, id: \.0) { label, list in
                    HStack(spacing: 4) {
                        Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(list) { b in
                            BrawlerIcon(id: b.id, size: 26)
                                .overlay(alignment: .topTrailing) {
                                    if !b.isConfident {
                                        Circle().fill(.orange).frame(width: 7, height: 7)
                                    }
                                }
                                .accessibilityLabel(b.name)
                        }
                    }
                }
            }
        }
    }
}

/// 提案 1 体ぶんの行。点数ではなく「実測勝率と試合数」を主役にする。
struct AdviceRow: View {
    let advice: PickAdvice

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BrawlerIcon(id: advice.id, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(advice.nameJa ?? advice.name).font(.subheadline.weight(.semibold))
                    Text(advice.roleJa).font(.caption2).foregroundStyle(.secondary)
                }
                if !advice.reason.isEmpty {
                    Text(advice.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let wr = advice.winRate {
                WinRateBadge(winRate: wr, games: advice.games)
            }
        }
    }
}

/// 勝率を色付きで見せるバッジ。試合数が少ないときは信頼度が低いことも出す。
struct WinRateBadge: View {
    let winRate: Double
    let games: Int?

    private var color: Color {
        switch winRate {
        case 55...: return .green
        case 51..<55: return .mint
        case 48..<51: return .white
        default: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(String(format: "%.1f", winRate))%")
                .font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
            if let games {
                Text("\(games.formatted())戦")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(games < 30 ? .orange : .secondary)
            }
        }
    }
}

/// ロゴ。背景の宇宙（球の水色〜紫の光）と同じ色で、細い「BRAWL」と太い「BOARD」を並べ、
/// ときどき光がすっと横切る。
struct BrandTitle: View {
    @State private var sweep = false

    private var letters: some View {
        HStack(spacing: 12) {
            Text("BRAWL")
                .font(.system(size: 30, weight: .light))
                .tracking(7)
            Text("BOARD")
                .font(.system(size: 30, weight: .black))
                .tracking(3)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            letters
                .foregroundStyle(
                    LinearGradient(colors: [.white,
                                            Color(red: 0.62, green: 0.86, blue: 1),
                                            Color(red: 0.74, green: 0.6, blue: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .overlay {
                    // 光の帯が文字の上だけを横切る
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.95), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: sweep ? geo.size.width * 1.1 : -geo.size.width * 0.45)
                    }
                    .mask(letters)
                }
                .shadow(color: Color.cyan.opacity(0.55), radius: 10)
                .shadow(color: Color.purple.opacity(0.45), radius: 22)

            // ロゴの下の細い光の線
            Capsule()
                .fill(LinearGradient(colors: [.clear, .cyan.opacity(0.8), .purple.opacity(0.8), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 210, height: 1.5)
                .shadow(color: .cyan, radius: 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).delay(0.8).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brawl Board")
    }
}

import PhotosUI
import SwiftUI

/// 画面遷移はすべて値ベース（NavigationLink(value:) + navigationDestination）。
/// 常時描画する重いビューを抱える画面があるため、行が見えた時点で遷移先が
/// 先読み構築されると描画ループが裏で回り続けてアプリ全体が固まる（実機で確認済み）。
enum HomeRoute: Hashable {
    /// 対話モード（未搭載。ホームからは外してある）
    case voiceAssistant
    case teamBoard
    case profile
    case maps
    case brawlers
    case roster
    case settings
}

/// ホーム（Brawl Board）。スクロールさせず 1 画面に収める。
/// 主役はチーム募集。ドラフト用のデータ類は下段の小さなタイルにまとめた。
struct ContentView: View {
    @EnvironmentObject private var store: RulesStore
    @ObservedObject private var profiles = ProfileStore.shared
    @State private var path = NavigationPath()
    @State private var pickedItem: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var showsAnalyzeOptions = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var result: (snapshot: DraftSnapshot, recommendation: Recommendation)?
    @State private var showsResult = false

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                // iPhone SE のような背の低い画面では余白と球を詰めて、必ず 1 画面に収める
                let compact = geo.size.height < 640
                ZStack {
                    CosmosView(mode: .idle,
                               center: CGPoint(x: 0.5, y: compact ? 0.13 : 0.16),
                               radius: compact ? 0.11 : 0.13,
                               framesPerSecond: 30,
                               isPaused: !path.isEmpty)
                        .ignoresSafeArea()

                    VStack(spacing: compact ? 10 : 14) {
                        hero(orbSpace: compact ? 96 : 140)
                        // 大きい画面では余った高さをタイルの上下に配り、下に偏った空白を作らない
                        Spacer(minLength: compact ? 4 : 10)
                        teamCard
                        HStack(spacing: 12) {
                            profileTile
                            analyzeTile
                        }
                        HStack(spacing: 10) {
                            smallTile(.maps, icon: "map.fill", title: "マップ")
                            smallTile(.brawlers, icon: "person.crop.square.fill", title: "キャラ")
                            smallTile(.roster, icon: "checklist", title: "持ちキャラ")
                        }
                        Spacer(minLength: 0)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: HomeRoute.profile) {
                        ProfileAvatar(iconID: profiles.me.iconID, size: 32)
                    }
                    .accessibilityLabel("プロフィール")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: HomeRoute.settings) {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .accessibilityLabel("設定")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .voiceAssistant: VoiceAssistantView()
                case .teamBoard: TeamBoardView()
                case .profile: MyProfileView()
                case .maps: MapListView()
                case .brawlers: BrawlerListView()
                case .roster: BrawlerRosterView()
                case .settings: SettingsView()
                }
            }
            .confirmationDialog("スクショ解析", isPresented: $showsAnalyzeOptions) {
                Button("最新のスクリーンショットを解析") { Task { await analyzeLatest() } }
                Button("写真から選ぶ") { showsPhotoPicker = true }
            }
            .photosPicker(isPresented: $showsPhotoPicker, selection: $pickedItem, matching: .screenshots)
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await analyze(item) }
            }
            .sheet(isPresented: $showsResult) {
                if let result { resultSheet(result) }
            }
            .alert("エラー", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .tint(.cyan)
        #if DEBUG
        // 見た目確認用: SIMCTL_CHILD_BDA_ROUTE=team などで起動すると直接その画面を開く
        .task {
            let routes: [String: HomeRoute] = ["voice": .voiceAssistant, "team": .teamBoard, "profile": .profile,
                                               "maps": .maps, "settings": .settings]
            if let key = ProcessInfo.processInfo.environment["BDA_ROUTE"], let route = routes[key] {
                path.append(route)
            }
        }
        #endif
    }

    // MARK: - ヒーロー

    private func hero(orbSpace: CGFloat) -> some View {
        VStack(spacing: 8) {
            // 球体（背景の CosmosView）のぶんの余白
            Color.clear.frame(height: orbSpace)
            BrandTitle()
            dataPill
        }
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

    // MARK: - タイル

    private var teamCard: some View {
        NavigationLink(value: HomeRoute.teamBoard) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [.mint, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 58, height: 58)
                        .shadow(color: .mint.opacity(0.7), radius: 14)
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.black.opacity(0.8))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("チーム募集")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.white)
                    Text("募集を見て、ブロスタで即参加")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(18)
            .glassCard(tint: .mint, cornerRadius: 24)
        }
        .buttonStyle(.plain)
    }

    private var profileTile: some View {
        NavigationLink(value: HomeRoute.profile) {
            tile(icon: "person.crop.circle.badge.checkmark",
                 title: "プロフィール",
                 subtitle: profiles.me.isEmpty ? "ブロスタと連携" : profiles.me.name,
                 tint: .purple)
        }
        .buttonStyle(.plain)
    }

    private var analyzeTile: some View {
        Button {
            showsAnalyzeOptions = true
        } label: {
            tile(icon: busy ? nil : "camera.viewfinder",
                 title: busy ? "解析中…" : "スクショ解析",
                 subtitle: "ドラフトで次のピック",
                 tint: .cyan)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func tile(icon: String?, title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                } else {
                    ProgressView().tint(tint)
                }
            }
            .frame(height: 24)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(tint: tint, cornerRadius: 22)
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

    // MARK: - 解析結果（固定レイアウトを崩さないようシートで出す）

    private func resultSheet(_ value: (snapshot: DraftSnapshot, recommendation: Recommendation)) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("解析結果").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value.recommendation.title).font(.title3.weight(.bold))
                ForEach(value.recommendation.advices) { advice in
                    AdviceRow(advice: advice)
                }
                if let caution = value.recommendation.caution {
                    Text(caution).font(.caption2).foregroundStyle(.orange.opacity(0.9))
                }
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    // MARK: - 実行

    private func analyze(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false; pickedItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            _ = try await DraftService.analyze(data: data)
            result = DraftService.lastResult
            showsResult = result != nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func analyzeLatest() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await DraftService.analyzeLatestScreenshot()
            result = DraftService.lastResult
            showsResult = result != nil
        } catch {
            errorText = error.localizedDescription
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
                    Text(advice.reason).font(.caption).foregroundStyle(.secondary)
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

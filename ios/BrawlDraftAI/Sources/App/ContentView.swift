import PhotosUI
import SwiftUI

/// 画面遷移はすべて値ベース（NavigationLink(value:) + navigationDestination）。
/// 対話モード・チーム募集は常時描画する重いビューを抱えるため、行が見えた時点で
/// 遷移先が先読み構築されると描画ループが裏で回り続けてアプリ全体が固まる（実機で確認済み）。
enum HomeRoute: Hashable {
    case voiceAssistant
    case teamBoard
    case maps
    case brawlers
    case roster
    case settings
}

/// ホーム。見る場所を「対話」「スクショ解析」「チーム募集」の 3 つに絞り、
/// 設定・手順・規約は SettingsView に逃がしてある。
struct ContentView: View {
    @EnvironmentObject private var store: RulesStore
    @State private var path = NavigationPath()
    @State private var pickedItem: PhotosPickerItem?
    @State private var showsPhotoPicker = false
    @State private var showsAnalyzeOptions = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var result: (snapshot: DraftSnapshot, recommendation: Recommendation)?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                CosmosView(mode: .idle,
                           center: CGPoint(x: 0.5, y: 0.16),
                           radius: 0.13,
                           framesPerSecond: 30,
                           isPaused: !path.isEmpty)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        hero
                        primaryCard
                        HStack(spacing: 12) {
                            analyzeCard
                            teamCard
                        }
                        if let result { resultCard(result) }
                        dataLinks
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar {
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
            .alert("エラー", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .tint(.cyan)
        #if DEBUG
        // 見た目確認用: SIMCTL_CHILD_BDA_ROUTE=voice などで起動すると直接その画面を開く
        .task {
            let routes: [String: HomeRoute] = ["voice": .voiceAssistant, "team": .teamBoard,
                                               "maps": .maps, "settings": .settings]
            if let key = ProcessInfo.processInfo.environment["BDA_ROUTE"], let route = routes[key] {
                path.append(route)
            }
        }
        #endif
    }

    // MARK: - ヒーロー

    private var hero: some View {
        VStack(spacing: 10) {
            // 球体（背景の CosmosView）のぶんの余白
            Color.clear.frame(height: 150)
            Text("ガチバトルピックAI")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color(red: 0.6, green: 0.85, blue: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: .cyan.opacity(0.5), radius: 14)
            dataPill
        }
        .padding(.bottom, 6)
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
                     ? "実測 \((q.battlesAnalyzed ?? 0).formatted())試合・\(RulesStore.displayDate(q.statsUpdatedAt ?? rules.generatedAt)) 更新"
                     : "推定データ・\(RulesStore.displayDate(rules.generatedAt)) 更新")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial.opacity(0.7), in: Capsule())
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.orange)
        default:
            ProgressView().tint(.white)
        }
    }

    // MARK: - メインの 3 枚

    private var primaryCard: some View {
        NavigationLink(value: HomeRoute.voiceAssistant) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 58, height: 58)
                        .shadow(color: .cyan.opacity(0.7), radius: 14)
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("対話モード")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text("状況を話すだけで、次のピックを提案")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(18)
            .glassCard(tint: .cyan, cornerRadius: 24)
        }
        .buttonStyle(.plain)
    }

    private var analyzeCard: some View {
        Button {
            showsAnalyzeOptions = true
        } label: {
            tile(icon: busy ? nil : "camera.viewfinder",
                 title: busy ? "解析中…" : "スクショ解析",
                 subtitle: "ドラフト画面から判定",
                 tint: .purple)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var teamCard: some View {
        NavigationLink(value: HomeRoute.teamBoard) {
            tile(icon: "person.3.fill", title: "チーム募集", subtitle: "招待リンクで合流", tint: .mint)
        }
        .buttonStyle(.plain)
    }

    private func tile(icon: String?, title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                } else {
                    ProgressView().tint(tint)
                }
            }
            .frame(height: 26)
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(tint: tint, cornerRadius: 22)
    }

    // MARK: - 直近の解析結果

    private func resultCard(_ value: (snapshot: DraftSnapshot, recommendation: Recommendation)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("直近の解析").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    result = nil
                } label: {
                    Image(systemName: "xmark").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
            Text(value.recommendation.title)
                .font(.headline)
                .foregroundStyle(.white)
            ForEach(value.recommendation.advices) { advice in
                AdviceRow(advice: advice)
            }
            if let caution = value.recommendation.caution {
                Text(caution).font(.caption2).foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(16)
        .glassCard(tint: .purple, cornerRadius: 22)
    }

    // MARK: - データ

    private var dataLinks: some View {
        VStack(spacing: 0) {
            linkRow(.maps, icon: "map.fill", title: "マップ別データ")
            Divider().overlay(.white.opacity(0.08))
            linkRow(.brawlers, icon: "person.crop.square.fill", title: "キャラ一覧")
            Divider().overlay(.white.opacity(0.08))
            linkRow(.roster, icon: "checklist", title: "持っているキャラ")
        }
        .glassCard(tint: .white.opacity(0.4), cornerRadius: 20)
        .padding(.top, 4)
    }

    private func linkRow(_ route: HomeRoute, icon: String, title: String) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundStyle(.cyan)
                Text(title).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 実行

    private func analyze(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false; pickedItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            _ = try await DraftService.analyze(data: data)
            result = DraftService.lastResult
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

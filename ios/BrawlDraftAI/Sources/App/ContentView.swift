import PhotosUI
import SwiftUI

/// Form 内の NavigationLink(destination:) は、行が画面に出た時点で遷移先を
/// 先読み構築してしまう（SwiftUI の既知の挙動）。対話モードの遷移先は常時
/// 描画し続ける TimelineView を2つ抱えているため、先読みされるとホーム画面が
/// 表示された瞬間からバックグラウンドで描画ループが回り続け、メインスレッドを
/// 圧迫してアプリ全体が固まる（実機で確認済みの不具合）。
/// これを避けるため、このリンクだけ値ベースの遅延遷移にしている。
private enum ContentRoute: Hashable {
    case voiceAssistant
}

struct ContentView: View {
    @EnvironmentObject private var store: RulesStore
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var errorText: String?
    @State private var result: (snapshot: DraftSnapshot, recommendation: Recommendation)?
    @State private var resultExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                dataSection
                testSection
                if let result { resultSection(result) }
                settingsSection
                helpSection
                legalSection
            }
            .navigationTitle("ガチバトルピックAI")
            .navigationDestination(for: ContentRoute.self) { route in
                switch route {
                case .voiceAssistant: VoiceAssistantView()
                }
            }
            .alert("エラー", isPresented: .constant(errorText != nil)) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    // MARK: - データ状態

    private var dataSection: some View {
        Section("ルールデータ") {
            switch store.state {
            case .idle, .loading:
                HStack { ProgressView(); Text("読み込み中 …").foregroundStyle(.secondary) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .ready(let rules):
                NavigationLink {
                    MapListView()
                } label: {
                    LabeledContent("マップ数", value: "\(rules.document.maps.count)")
                }
                NavigationLink {
                    BrawlerListView()
                } label: {
                    LabeledContent("キャラ判定用テンプレ", value: "\(rules.brawlerMatcher.count)")
                }
                LabeledContent("生成日時", value: rules.generatedAt)
                LabeledContent("取得元", value: rules.origin.rawValue)
                LabeledContent("スコアの根拠") {
                    switch rules.document.dataQuality.confidence {
                    case .measured:
                        Text("実測勝率あり").foregroundStyle(.green)
                    case .manualTier(let count):
                        Text("手動ティア \(count) 件で補正")
                            .foregroundStyle(.yellow)
                            .multilineTextAlignment(.trailing)
                    case .roleOnly:
                        Text("役割適性のみ（同点多数）").foregroundStyle(.orange)
                    }
                }
                if case .manualTier = rules.document.dataQuality.confidence {
                    Text("実測勝率は未取得です。data/tier_overrides.json の手入力値で"
                         + "順位を付けています（測定値ではありません）。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let message = store.lastRefreshMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await store.refreshFromRemote(force: true) }
            } label: {
                Label("いま更新する", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - テスト

    private var testSection: some View {
        Section("動作テスト") {
            PhotosPicker(selection: $pickedItem, matching: .screenshots) {
                Label("スクリーンショットを選んで解析", systemImage: "photo.on.rectangle.angled")
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await analyze(item) }
            }

            Button {
                Task { await analyzeLatest() }
            } label: {
                Label("最新のスクショを解析（本番と同じ経路）", systemImage: "bolt.fill")
            }

            NavigationLink {
                CalibrationView()
            } label: {
                Label("枠合わせ（初回は必須）", systemImage: "viewfinder.rectangular")
            }

            NavigationLink {
                BrawlerRosterView()
            } label: {
                Label("持っているキャラを管理", systemImage: "checklist")
            }

            Button {
                SpeechAnnouncer.shared.announceTest()
            } label: {
                Label("読み上げテスト", systemImage: "speaker.wave.2.fill")
            }

            NavigationLink(value: ContentRoute.voiceAssistant) {
                Label("対話モードで質問する", systemImage: "waveform.and.mic")
            }

            if busy { HStack { ProgressView(); Text("解析中 …") } }
        }
    }

    // MARK: - 結果

    private func resultSection(_ value: (snapshot: DraftSnapshot, recommendation: Recommendation)) -> some View {
        Section {
            DisclosureGroup(isExpanded: $resultExpanded) {
                Text(value.recommendation.title).font(.headline)
                ForEach(value.recommendation.advices) { advice in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(advice.name)（\(advice.roleJa)）  \(String(format: "%.2f", advice.score))")
                            .font(.subheadline.weight(.semibold))
                        if !advice.reason.isEmpty {
                            Text(advice.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let caution = value.recommendation.caution {
                    Label(caution, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(value.snapshot.diagnosticSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("直近の解析結果").font(.subheadline)
                    Text(value.recommendation.title)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - 設定

    private var settingsSection: some View {
        Section("設定") {
            VStack(alignment: .leading, spacing: 4) {
                Text("rules.json の URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://raw.githubusercontent.com/…", text: Binding(
                    get: { AppSettings.rulesURL },
                    set: { AppSettings.rulesURL = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote)
                if !AppSettings.isRulesURLConfigured {
                    Text("未設定です。GitHub の raw URL を入れると毎日の更新が反映されます。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            Toggle("通知バナーを出す", isOn: Binding(
                get: { AppSettings.notificationEnabled },
                set: { AppSettings.notificationEnabled = $0 }
            ))
            Toggle("音声で読み上げる", isOn: Binding(
                get: { AppSettings.speechEnabled },
                set: { AppSettings.speechEnabled = $0 }
            ))
            Stepper(value: Binding(
                get: { AppSettings.maxAnnouncedPicks },
                set: { AppSettings.maxAnnouncedPicks = $0 }
            ), in: 1...3) {
                Text("読み上げるキャラ数: \(AppSettings.maxAnnouncedPicks)")
            }
            VStack(alignment: .leading) {
                Text("読み上げ速度: \(String(format: "%.2f", AppSettings.speechRate))")
                    .font(.caption)
                Slider(value: Binding(
                    get: { AppSettings.speechRate },
                    set: { AppSettings.speechRate = $0 }
                ), in: 0.40...0.70)
            }
        }
    }

    private var legalSection: some View {
        Section("このアプリについて") {
            Link(destination: URL(string: "https://asanoitsuki.github.io/brawl-stars-draft-ai/privacy-policy.html")!) {
                Label("プライバシーポリシー", systemImage: "hand.raised")
            }
            Link(destination: URL(string: "https://asanoitsuki.github.io/brawl-stars-draft-ai/terms.html")!) {
                Label("利用規約", systemImage: "doc.text")
            }
            Text("本アプリは Brawl Stars（Supercell社）の非公式ファンツールです。"
                 + "Supercell社とは一切関係ありません。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var helpSection: some View {
        Section("背面タップの設定手順") {
            Text("""
            1. ショートカットアプリで新規ショートカットを作る
            2. アクション「最新スクショでドラフト解析」を追加
            3. 設定 > アクセシビリティ > タッチ > 背面タップ を開く
            4. 「ダブルタップ」→「スクリーンショット」（iOS 標準機能）を選ぶ
            5. 「トリプルタップ」→ さっき作ったショートカットを選ぶ
            6. 対戦中: 背面ダブルタップ（撮影）→ すぐに背面トリプルタップ（解析）
            """)
            .font(.footnote)
        }
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

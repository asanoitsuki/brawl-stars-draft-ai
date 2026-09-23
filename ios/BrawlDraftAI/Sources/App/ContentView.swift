import PhotosUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RulesStore
    @State private var pickedItem: PhotosPickerItem?
    @State private var busy = false
    @State private var errorText: String?
    @State private var result: (snapshot: DraftSnapshot, recommendation: Recommendation)?

    var body: some View {
        NavigationStack {
            Form {
                dataSection
                testSection
                if let result { resultSection(result) }
                settingsSection
                helpSection
            }
            .navigationTitle("ガチバトルピックAI")
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
                LabeledContent("マップ数", value: "\(rules.document.maps.count)")
                LabeledContent("キャラ判定用テンプレ", value: "\(rules.brawlerMatcher.count)")
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

            Button {
                SpeechAnnouncer.shared.announceTest()
            } label: {
                Label("読み上げテスト", systemImage: "speaker.wave.2.fill")
            }

            if busy { HStack { ProgressView(); Text("解析中 …") } }
        }
    }

    // MARK: - 結果

    private func resultSection(_ value: (snapshot: DraftSnapshot, recommendation: Recommendation)) -> some View {
        Section("直近の解析結果") {
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

    private var helpSection: some View {
        Section("背面タップの設定手順") {
            Text("""
            1. ショートカットアプリで新規ショートカットを作る
            2. アクション「最新スクショでドラフト解析」を追加
            3. 設定 > アクセシビリティ > タッチ > 背面タップ > ダブルタップ に \
            そのショートカットを割り当てる
            4. 対戦中: 電源+音量上でスクショ → 背面ダブルタップ
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

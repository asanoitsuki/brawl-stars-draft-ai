import SwiftUI

/// ホーム画面から外した「たまにしか触らないもの」をまとめた画面。
/// データの出どころ・読み上げ設定・背面タップの手順・規約類。
struct SettingsView: View {
    @EnvironmentObject private var store: RulesStore
    @State private var showsAdvanced = false

    var body: some View {
        Form {
            dataSection
            speechSection
            Section {
                NavigationLink {
                    CalibrationView()
                } label: {
                    Label("枠合わせ（スクショ解析の初回のみ）", systemImage: "viewfinder.rectangular")
                }
                DisclosureGroup("背面タップで解析する手順") {
                    Text("""
                    1. ショートカットアプリで新規ショートカットを作る
                    2. アクション「最新スクショでドラフト解析」を追加
                    3. 設定 > アクセシビリティ > タッチ > 背面タップ を開く
                    4.「ダブルタップ」→「スクリーンショット」を選ぶ
                    5.「トリプルタップ」→ さっき作ったショートカットを選ぶ
                    6. 対戦中: 背面ダブルタップ（撮影）→ 背面トリプルタップ（解析）
                    """)
                    .font(.footnote)
                }
            } header: {
                Text("スクショ解析")
            }
            Section {
                DeleteMyDataButton()
            } header: {
                Text("プライバシー")
            } footer: {
                Text("チーム募集で公開したプロフィール・募集・チャットのメッセージを、端末と iCloud から削除します。")
            }
            legalSection
            Section {
                DisclosureGroup("開発者向け", isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("rules.json の URL").font(.caption).foregroundStyle(.secondary)
                        TextField("https://raw.githubusercontent.com/…", text: Binding(
                            get: { AppSettings.rulesURL },
                            set: { AppSettings.rulesURL = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("プロフィール取得サーバー").font(.caption).foregroundStyle(.secondary)
                        TextField("https://brawl-board-api.vercel.app", text: Binding(
                            get: { AppSettings.profileAPIBase },
                            set: { AppSettings.profileAPIBase = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    }
                    if case .ready(let rules) = store.state {
                        LabeledContent("生成日時", value: RulesStore.displayDate(rules.generatedAt))
                        LabeledContent("取得元", value: rules.origin.rawValue)
                        LabeledContent("マップ数", value: "\(rules.document.maps.count)")
                    }
                }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: -

    private var dataSection: some View {
        Section {
            switch store.state {
            case .idle, .loading:
                HStack { ProgressView(); Text("読み込み中 …").foregroundStyle(.secondary) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .ready(let rules):
                let q = rules.document.dataQuality
                if let battles = q.battlesAnalyzed, battles > 0 {
                    LabeledContent("実測データ", value: "約\(battles.formatted())試合")
                    if let updated = q.statsUpdatedAt {
                        LabeledContent("集計日時", value: RulesStore.displayDate(updated))
                    }
                    Text("ガチバトルの実際の対戦結果（Brawl Stars 公式 API の対戦履歴）から、"
                         + "マップ別の勝率・使用率とキャラ同士の相性を毎日集計しています。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("実勝率は未取得（役割相性と手動ティアによる推定）", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
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
        } header: {
            Text("データ")
        } footer: {
            Text("アプリを開くたび、前回から\(Int(AppSettings.autoRefreshHours))時間以上たっていれば自動で最新データに更新します。")
        }
    }

    private var speechSection: some View {
        Section("通知・読み上げ") {
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
            Button {
                SpeechAnnouncer.shared.announceTest()
            } label: {
                Label("読み上げテスト", systemImage: "speaker.wave.2.fill")
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
            Link(destination: URL(string: "https://asanoitsuki.github.io/brawl-stars-draft-ai/support.html")!) {
                Label("サポート・お問い合わせ", systemImage: "questionmark.circle")
            }
            Text("Brawl Board は Brawl Stars（Supercell社）の非公式ファンツールです。"
                 + "Supercell社とは一切関係ありません。ゲーム内の画像・名称はSupercell社に帰属します。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

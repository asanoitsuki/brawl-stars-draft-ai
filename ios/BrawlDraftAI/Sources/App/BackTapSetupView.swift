import SwiftUI
import UserNotifications

/// 背面タップ解析の初期設定。上から順にやれば終わるようにまとめた画面。
///
/// ショートカットの中で「スクリーンショットを撮る」→「ドラフトを解析」とつなぐと、
/// 背面を 2 回たたくだけで撮影から通知まで終わる（写真に画像が残らず、写真の許可も要らない）。
struct BackTapSetupView: View {
    @AppStorage("backTapReady") private var backTapReady = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var testSent = false

    var body: some View {
        Form {
            Section {
                if status == .authorized {
                    Label("通知は許可されています", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if status == .denied {
                    Button("設定アプリで通知を許可する") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                } else {
                    Button("通知を許可する") {
                        Task {
                            await NotificationPresenter.shared.requestAuthorization()
                            await refresh()
                        }
                    }
                }
            } header: {
                Text("手順 1　通知")
            } footer: {
                Text("解析結果は、画面の上に通知で出ます。")
            }

            Section {
                step("1", "「ショートカット」アプリで新しいショートカットを作る")
                step("2", "アクション「スクリーンショットを撮る」を追加")
                step("3", "続けて、Brawl Board の「ドラフトを解析」を追加")
                step("4", "「ドラフトを解析」の「スクリーンショット」の欄に、直前の「スクリーンショット」を指定")
                step("5", "名前を「ドラフト解析」にして保存")
                Button {
                    if let url = URL(string: "shortcuts://create-shortcut") { openURL(url) }
                } label: {
                    Label("ショートカットアプリを開く", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("手順 2　ショートカットを作る")
            }

            Section {
                step("1", "iPhone の「設定」→「アクセシビリティ」→「タッチ」")
                step("2", "いちばん下の「背面タップ」→「ダブルタップ」")
                step("3", "作った「ドラフト解析」を選ぶ")
            } header: {
                Text("手順 3　背面タップに割り当てる")
            } footer: {
                Text("ドラフト画面で iPhone の背面を 2 回たたくと、撮影して解析し、通知で結果が出ます。")
            }

            Section {
                Button {
                    Task {
                        await NotificationPresenter.shared.presentTest()
                        testSent = true
                    }
                } label: {
                    Label(testSent ? "テスト通知を送りました" : "テスト通知を送る", systemImage: "bell.badge")
                }
                .disabled(status != .authorized)
                Toggle("設定できた（ホームの案内を消す）", isOn: $backTapReady)
            } header: {
                Text("手順 4　確認")
            }
        }
        .navigationTitle("背面タップの設定")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        status = await NotificationPresenter.shared.authorizationStatus
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.caption.weight(.black))
                .frame(width: 20, height: 20)
                .background(Color.cyan.opacity(0.25), in: Circle())
            Text(text).font(.subheadline)
        }
    }
}

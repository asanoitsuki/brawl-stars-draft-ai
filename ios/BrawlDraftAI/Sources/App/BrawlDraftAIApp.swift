import SwiftUI

@main
struct BrawlDraftAIApp: App {
    @StateObject private var store = RulesStore.shared
    @State private var urlMessage: String?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    NotificationPresenter.shared.registerDelegate()
                    DraftService.warmUp()
                }
                .onOpenURL { url in handle(url) }
                .overlay(alignment: .top) {
                    if let urlMessage {
                        Text(urlMessage)
                            .font(.footnote)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut, value: urlMessage)
        }
    }

    /// URL スキーム:
    ///   brawldraft://analyze              … 最新のスクリーンショットを解析
    ///   brawldraft://analyze?path=<path>  … 指定ファイルを解析
    ///   brawldraft://refresh              … rules.json を再取得
    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "brawldraft" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.queryItems?.first { $0.name == "path" }?.value

        Task {
            do {
                switch url.host?.lowercased() {
                case "analyze", nil:
                    if let path {
                        try await DraftService.analyze(image: ScreenshotSource.image(atPath: path))
                    } else {
                        try await DraftService.analyzeLatestScreenshot()
                    }
                    await show("解析しました")
                case "refresh":
                    await RulesStore.shared.refreshFromRemote(force: true)
                    await show("ルールを更新しました")
                default:
                    await show("不明な URL: \(url.absoluteString)")
                }
            } catch {
                await NotificationPresenter.shared.presentError(error.localizedDescription)
                await show(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func show(_ text: String) async {
        urlMessage = text
        try? await Task.sleep(for: .seconds(2.5))
        urlMessage = nil
    }
}

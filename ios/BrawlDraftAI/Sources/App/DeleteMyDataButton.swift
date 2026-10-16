import SwiftUI

/// 「プロフィールとデータを削除」ボタン（確認つき）。設定とプロフィール画面で共通。
struct DeleteMyDataButton: View {
    var onDeleted: (() -> Void)? = nil
    @State private var confirming = false
    @State private var working = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(role: .destructive) {
                confirming = true
            } label: {
                Label(working ? "削除中…" : "プロフィールとデータを削除", systemImage: "trash")
            }
            .disabled(working)
            if let result {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("プロフィール・募集・チャットのメッセージを、このアプリと iCloud から削除します。元に戻せません。",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("すべて削除する", role: .destructive) {
                Task {
                    working = true
                    let ok = await ProfileStore.shared.deleteAllMyData()
                    working = false
                    result = ok ? "削除しました" : "端末内のデータは削除しました。iCloud 側は通信できず削除できなかったため、もう一度お試しください"
                    onDeleted?()
                }
            }
        }
    }
}

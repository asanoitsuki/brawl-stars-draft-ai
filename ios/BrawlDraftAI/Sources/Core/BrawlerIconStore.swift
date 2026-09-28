import SwiftUI
import UIKit

/// バンドル同梱のキャラアイコン（`assets/brawler_icons/borders/*.png` → `sync_ios_resources.sh` が
/// `Resources/BrawlerIcons/<id>.png` としてコピーしたもの）を読み込んでキャッシュする。
///
/// ディスク I/O は初回だけ。一覧のスクロールで毎回読み直さないよう、
/// メモリキャッシュに載せてから返す。
enum BrawlerIconStore {
    private static var cache: [Int: UIImage] = [:]

    static func image(for brawlerID: Int) -> UIImage? {
        if let cached = cache[brawlerID] { return cached }
        // xcodegen はフォルダ内の個別ファイルをバンドル直下へフラットに展開するため、
        // サブディレクトリ指定では見つからない（rules.json 等と同じ扱い）。
        guard let url = Bundle.main.url(forResource: "\(brawlerID)", withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        cache[brawlerID] = image
        return image
    }
}

/// キャラアイコンを丸角の正方形で出す共通パーツ。
/// アイコンが無いキャラ（CDN 未反映の新キャラなど）はプレースホルダーを出す。
struct BrawlerIcon: View {
    let id: Int
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image = BrawlerIconStore.image(for: id) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "questionmark")
                        .foregroundStyle(.secondary)
                        .font(.system(size: size * 0.4))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

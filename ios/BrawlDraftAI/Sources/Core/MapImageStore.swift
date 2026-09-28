import SwiftUI
import UIKit

/// バンドル同梱のマップ画像（`assets/map_thumbs/*.png` → `sync_ios_resources.sh` が
/// `Resources/MapThumbs/<id>.png` としてコピーしたもの）を読み込んでキャッシュする。
/// 仕組みは BrawlerIconStore と同じ。
enum MapImageStore {
    private static var cache: [Int: UIImage] = [:]

    static func image(for mapID: Int) -> UIImage? {
        if let cached = cache[mapID] { return cached }
        guard let url = Bundle.main.url(forResource: "\(mapID)", withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        cache[mapID] = image
        return image
    }
}

/// マップ画像を角丸で出す共通パーツ。画像が無ければプレースホルダーを出す。
struct MapThumbnail: View {
    let id: Int
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let image = MapImageStore.image(for: id) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "map")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

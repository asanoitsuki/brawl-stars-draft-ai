import SwiftUI
import UIKit

/// ガジェット・スターパワーの画像（`assets/gadgets` / `assets/star_powers` →
/// `sync_ios_resources.sh` が `Resources/Loadouts/<image>.png` としてコピーしたもの）。
/// ファイル名には Python 側で種別プレフィックス（g/s）が付いているので、
/// ガジェットとスターパワーで ID 帯が重なっていても衝突しない。
enum LoadoutImageStore {
    private static var cache: [String: UIImage] = [:]

    static func image(named filename: String?) -> UIImage? {
        guard let filename else { return nil }
        if let cached = cache[filename] { return cached }
        guard let url = Bundle.main.url(forResource: filename, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        cache[filename] = image
        return image
    }
}

/// ガジェット/スターパワーの画像を正方形で出す共通パーツ。
struct LoadoutIcon: View {
    let filename: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image = LoadoutImageStore.image(named: filename) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "star.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

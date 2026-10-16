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

/// 同梱されていない新キャラのアイコンを、Brawlify の CDN から取ってディスクに残す。
/// 一度取れれば次回からは通信しない。まだ CDN に無いキャラ（404）は、起動中に何度も取りに行かない。
enum RemoteBrawlerIcon {
    private static var memory: [Int: UIImage] = [:]
    private static var missing: Set<Int> = []

    private static func cacheURL(_ id: Int) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("brawler-icon-\(id).png")
    }

    static func cached(_ id: Int) -> UIImage? {
        if let m = memory[id] { return m }
        if let url = cacheURL(id), let img = UIImage(contentsOfFile: url.path) {
            memory[id] = img
            return img
        }
        return nil
    }

    static func fetch(_ id: Int) async -> UIImage? {
        if let c = cached(id) { return c }
        guard !missing.contains(id),
              let url = URL(string: "https://cdn.brawlify.com/brawlers/borders/\(id).png") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data) else {
            missing.insert(id)
            return nil
        }
        if let file = cacheURL(id) { try? data.write(to: file) }
        memory[id] = img
        return img
    }
}

/// キャラアイコンを丸角の正方形で出す共通パーツ。
/// 同梱が無いキャラ（新キャラ）は CDN から取る。CDN にもまだ無ければプレースホルダー。
struct BrawlerIcon: View {
    let id: Int
    var size: CGFloat = 40
    @State private var remote: UIImage?

    private var image: UIImage? {
        BrawlerIconStore.image(for: id) ?? remote ?? RemoteBrawlerIcon.cached(id)
    }

    var body: some View {
        Group {
            if let image {
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
        .task(id: id) {
            guard BrawlerIconStore.image(for: id) == nil, remote == nil else { return }
            remote = await RemoteBrawlerIcon.fetch(id)
        }
    }
}

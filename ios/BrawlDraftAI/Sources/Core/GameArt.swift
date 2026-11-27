import SwiftUI
import UIKit

/// ゲーム本物の画像（Brawlify の CDN）を、自作の表示の上に重ねる。
///
/// 画像はアプリに同梱せず、使うときに読み込んで端末のキャッシュに置く。
/// Debug 構成では読み込まない（自作の表示だけで動作を確かめるため）。
extension View {
    @ViewBuilder
    func gameArt(_ path: String?, fit: Bool = false, background: Color? = nil) -> some View {
        #if REAL_ICONS
        if let path {
            overlay { GameArtImage(path: path, fit: fit, background: background) }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// 通知など、SwiftUI の外で画像そのものが要るとき用。
enum GameArtLoader {
    /// 本物の画像（Personal 構成のみ）。取れなければ nil。
    @MainActor
    static func image(_ path: String) async -> UIImage? {
        #if REAL_ICONS
        return await GameArtCache.load(path)
        #else
        return nil
        #endif
    }

    /// 背面タップの解析は数秒で終わらせたいので、全キャラのアイコンを先に端末へ取っておく。
    @MainActor
    static func prefetchBrawlerIcons(_ ids: [Int]) async {
        #if REAL_ICONS
        for id in ids where GameArtCache.cached("brawlers/borders/\(id)") == nil {
            _ = await GameArtCache.load("brawlers/borders/\(id)")
        }
        #endif
    }
}

#if REAL_ICONS
/// 一度取った画像は端末のキャッシュに残し、次からは通信しない。取れないときは何も重ねない。
@MainActor
private enum GameArtCache {
    static var memory: [String: UIImage] = [:]
    static var missing: Set<String> = []

    static func file(_ path: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("art-" + path.replacingOccurrences(of: "/", with: "-") + ".png")
    }

    static func cached(_ path: String) -> UIImage? {
        if let image = memory[path] { return image }
        guard let url = file(path), let image = UIImage(contentsOfFile: url.path) else { return nil }
        memory[path] = image
        return image
    }

    static func load(_ path: String) async -> UIImage? {
        if let image = cached(path) { return image }
        guard !missing.contains(path),
              let url = URL(string: "https://cdn.brawlify.com/\(path).png"),
              let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
            missing.insert(path)
            return nil
        }
        if let file = file(path) { try? data.write(to: file) }
        memory[path] = image
        return image
    }
}

private struct GameArtImage: View {
    let path: String
    let fit: Bool
    let background: Color?
    @State private var loaded: (path: String, image: UIImage)?

    private var image: UIImage? {
        loaded?.path == path ? loaded?.image : GameArtCache.cached(path)
    }

    var body: some View {
        ZStack {
            if let image {
                // スターパワー・ガジェットは透過画像なので、下の自作の絵が透けないように地を敷く
                if background != nil { Color(white: 0.14) }
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fit || background != nil ? .fit : .fill)
            }
        }
        .task(id: path) {
            if let image = await GameArtCache.load(path) { loaded = (path, image) }
        }
    }
}
#endif

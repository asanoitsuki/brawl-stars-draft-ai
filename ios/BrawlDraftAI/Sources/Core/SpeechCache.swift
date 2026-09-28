import Foundation

/// 音声合成結果（MP3）のディスクキャッシュ。
///
/// キャラ名・役割の立ち回りアドバイス・固定フレーズは語彙が閉じている（100〜150 種類程度）ので、
/// 一度読み上げたフレーズは 2 回目以降ネットワークに触らず即再生できる。
/// 「立ち回りは、〜」のようにスコアの数値を含む動的な文はキャッシュに乗らず毎回合成されるが、
/// 頻度が低いので許容している。
enum SpeechCache {
    private static var directory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).mp3")
    }

    static func cachedFile(for text: String) -> URL? {
        let path = url(for: CloudSpeechClient.cacheKey(for: text))
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    @discardableResult
    static func store(_ data: Data, for text: String) -> URL {
        let path = url(for: CloudSpeechClient.cacheKey(for: text))
        try? data.write(to: path, options: .atomic)
        return path
    }

    /// キャッシュ済みの音声ファイルを URL のまま返す（無ければ合成してから保存する）。
    static func fileURL(for text: String) async throws -> URL {
        if let cached = cachedFile(for: text) { return cached }
        let data = try await CloudSpeechClient.synthesize(text: text)
        return store(data, for: text)
    }

    static var fileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    static var totalBytes: Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    static func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}

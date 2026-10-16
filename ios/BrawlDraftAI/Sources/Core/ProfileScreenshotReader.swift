import UIKit
import Vision

/// ブロスタのプロフィール画面のスクショから、タグ・名前・トロフィー・最高ランクを読み取る。
/// 文字認識は端末内（Vision）だけで行い、画像はどこにも送らない。
///
/// 読み取りは「完全一致の項目名」に頼らず、次の手がかりで拾う:
///   * タグ: `#` で始まるブロスタのタグ文字（0289PYLQGRJCUV）の並び
///   * 名前: タグのすぐ上にある文字
///   * トロフィー / 最高トロフィー: 「トロフィー」「最高」を含む文字のいちばん近くにある数字
///   * 最高ランク: ランク名（マスターⅡ など）。複数あれば「最高」に近いもの、無ければいちばん高いもの
enum ProfileScreenshotReader {
    struct Result: Equatable {
        var tag: String?
        var name: String?
        var trophies: Int?
        var highestTrophies: Int?
        var highestRank: Int?

        var isEmpty: Bool { tag == nil && name == nil && trophies == nil && highestRank == nil }
    }

    private struct Line {
        let text: String
        let box: CGRect   // Vision の正規化座標（左下原点）
        var midY: CGFloat { box.midY }
        var midX: CGFloat { box.midX }
    }

    static func read(_ image: UIImage) async throws -> Result {
        guard let cgImage = image.cgImage else { return Result() }
        let lines = try await recognize(cgImage, orientation: image.imageOrientation)
        return parse(lines)
    }

    private static func recognize(_ cgImage: CGImage, orientation: UIImage.Orientation) async throws -> [Line] {
        // perform は同期で結果を埋めるので、完了ハンドラは使わず終わってから読む
        // （ハンドラとエラーの両方で continuation を 2 回再開してしまう事故を避ける）
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(orientation))
            try handler.perform([request])
            return (request.results ?? []).compactMap { obs -> Line? in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                return Line(text: text, box: obs.boundingBox)
            }
        }.value
    }

    private static func parse(_ lines: [Line]) -> Result {
        var result = Result()

        // タグ
        var tagLine: Line?
        for line in lines {
            let compact = line.text.replacingOccurrences(of: " ", with: "").uppercased()
            if let r = compact.range(of: #"#[0-9A-Z]{5,14}"#, options: .regularExpression) {
                let candidate = ProfileLink.normalize(String(compact[r]))
                if candidate.range(of: #"^#[0289PYLQGRJCUV]{5,14}$"#, options: .regularExpression) != nil {
                    result.tag = candidate
                    tagLine = line
                    break
                }
            }
        }

        // 名前: タグのすぐ上（横位置が重なる、いちばん近い行）
        if let tagLine {
            let above = lines.filter {
                $0.midY > tagLine.midY && $0.midY - tagLine.midY < 0.15
                    && abs($0.box.minX - tagLine.box.minX) < 0.2
                    && !$0.text.contains("#") && number(in: $0.text) == nil
            }
            result.name = above.min { ($0.midY - tagLine.midY) < ($1.midY - tagLine.midY) }?.text
                .trimmingCharacters(in: .whitespaces)
        }

        // トロフィー（「最高」を含まない項目）と最高トロフィー
        let numbers = lines.compactMap { line -> (Line, Int)? in
            guard let n = number(in: line.text), n >= 10 else { return nil }
            return (line, n)
        }
        func nearestNumber(to label: Line) -> Int? {
            // 同じ行に数字があればそれ、無ければ右か下の近いもの
            if let n = number(in: label.text), n >= 10 { return n }
            return numbers
                .filter { $0.0.text != label.text }
                .min { distance(label, $0.0) < distance(label, $1.0) }
                .flatMap { distance(label, $0.0) < 0.25 ? $0.1 : nil }
        }
        for line in lines where line.text.contains("トロフィー") || line.text.uppercased().contains("TROPH") {
            let isHighest = line.text.contains("最高") || line.text.uppercased().contains("HIGHEST")
            if isHighest, result.highestTrophies == nil {
                result.highestTrophies = nearestNumber(to: line)
            } else if !isHighest, result.trophies == nil {
                result.trophies = nearestNumber(to: line)
            }
        }

        // 最高ランク
        let ranks = lines.compactMap { line -> (Line, Int)? in RankTier.parse(line.text).map { (line, $0) } }
        if let label = lines.first(where: { $0.text.contains("最高ランク") || $0.text.uppercased().contains("HIGHEST RANK") }),
           let near = ranks.min(by: { distance(label, $0.0) < distance(label, $1.0) }) {
            result.highestRank = near.1
        } else {
            result.highestRank = ranks.map(\.1).max()
        }
        return result
    }

    /// "38,420" "38 420" "38420" → 38420
    private static func number(in text: String) -> Int? {
        guard let r = text.range(of: #"\d[\d,\.\s]{0,9}\d|\d"#, options: .regularExpression) else { return nil }
        let digits = text[r].filter(\.isNumber)
        return Int(digits)
    }

    private static func distance(_ a: Line, _ b: Line) -> CGFloat {
        let dx = max(0, b.midX - a.midX)      // 右側を優先
        let dy = abs(a.midY - b.midY)
        return dy * 1.5 + dx * 0.5 + (b.midX < a.box.minX ? 0.3 : 0)
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// ブロスタのプロフィール画面や、Brawl Insights などで作ったプロフィール画像から、
/// タグ・名前・クラブ・トロフィー・ガチバトルのポイントを読み取る。
/// 文字認識は端末内（Vision）だけで行い、画像はどこにも送らない。
///
/// 項目名の完全一致に頼らず、位置関係で拾う:
///   * タグ: `#` で始まるブロスタのタグ文字（0289PYLQGRJCUV）の並び
///   * 名前: タグのすぐ上 / クラブ: タグのすぐ下
///   * 「最多」「最高」「現在」「トロフィー」などの見出しの真下（無ければ右）にある数字
///     - 左の列（トロフィー）: 最多 = 最高トロフィー、現在 = 総トロフィー
///     - 右の列（ガチバトル）: 最高 / 現在 = ガチバトルのポイント
///   * ランク名（マスターⅡ など）が文字で書いてあれば最高ランク
enum ProfileScreenshotReader {
    struct Result: Equatable {
        var tag: String?
        var name: String?
        var club: String?
        var trophies: Int?
        var highestTrophies: Int?
        var rankedHighest: Int?
        var rankedCurrent: Int?
        var highestRank: Int?

        var isEmpty: Bool { tag == nil && name == nil && trophies == nil && highestRank == nil }
    }

    struct Line {
        let text: String
        let box: CGRect   // Vision の正規化座標（左下原点、0〜1）
        var midY: CGFloat { box.midY }
        var midX: CGFloat { box.midX }
    }

    #if canImport(UIKit)
    static func read(_ image: UIImage) async throws -> Result {
        guard let cgImage = image.cgImage else { return Result() }
        return try await read(cgImage, orientation: cgOrientation(image.imageOrientation))
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
    #endif

    static func read(_ cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> Result {
        // perform は同期で結果を埋めるので、完了ハンドラは使わず終わってから読む
        let lines: [Line] = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try handler.perform([request])
            return (request.results ?? []).compactMap { obs -> Line? in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                return Line(text: text, box: obs.boundingBox)
            }
        }.value
        return parse(lines)
    }

    // MARK: - 読み取り

    static func parse(_ lines: [Line]) -> Result {
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

        // 名前（タグのすぐ上）とクラブ（タグのすぐ下）
        if let tagLine {
            func neighbor(above: Bool) -> Line? {
                lines.filter {
                    let dy = above ? $0.midY - tagLine.midY : tagLine.midY - $0.midY
                    return dy > 0 && dy < 0.12
                        && abs($0.box.minX - tagLine.box.minX) < 0.12
                        && !$0.text.contains("#")
                }
                .min { abs($0.midY - tagLine.midY) < abs($1.midY - tagLine.midY) }
            }
            result.name = neighbor(above: true).map { clean($0.text) }
            result.club = neighbor(above: false).map { clean($0.text) }
        }

        // 見出しの真下の数字
        let numbers = lines.compactMap { line -> (Line, Int)? in
            guard let n = number(in: line.text), n >= 10 else { return nil }
            return (line, n)
        }
        func valueBelow(_ label: Line) -> Int? {
            // 見出し自体に数字が付いていればそれ（「トロフィー 38,420」型）
            if let n = number(in: label.text), n >= 10 { return n }
            // 見出しの下の値は見出しより大きな文字で書かれている（小さい数字は別の欄の値）
            let below = numbers.filter {
                $0.0.midY < label.midY && label.midY - $0.0.midY < 0.12
                    && $0.0.box.minX < label.box.maxX + 0.05 && $0.0.box.maxX > label.box.minX - 0.05
                    && $0.0.box.height >= label.box.height * 1.2
            }
            if let best = below.min(by: { label.midY - $0.0.midY < label.midY - $1.0.midY }) { return best.1 }
            // 右隣（「トロフィー」の右に数字が並ぶ型）
            let right = numbers.filter {
                abs($0.0.midY - label.midY) < 0.03 && $0.0.midX > label.midX
                    && $0.0.box.minX - label.box.maxX < 0.15   // 同じ欄の中だけ（遠くの別の数字は拾わない）
            }
            return right.min(by: { $0.0.midX < $1.0.midX })?.1
        }

        let mostLabels = lines.filter { isLabel($0.text, ["最多", "HIGHEST TROPHIES", "最高トロフィー"]) }
        let highestLabels = lines.filter { isLabel($0.text, ["最高"]) && !$0.text.contains("トロフィー") }
        let currentLabels = lines.filter { isLabel($0.text, ["現在", "CURRENT"]) }
        let trophyLabels = lines.filter {
            ($0.text.contains("トロフィー") || $0.text.uppercased().contains("TROPH"))
                && !$0.text.contains("最多") && !$0.text.contains("最高")
        }

        // 値が取れた見出しだけを使う（広告欄などの飾りの「最多」を除く）
        let mostHits = mostLabels.compactMap { l in valueBelow(l).map { (l, $0) } }
        let highestHits = highestLabels.compactMap { l in valueBelow(l).map { (l, $0) } }
        if let most = mostHits.map(\.1).max() {
            result.highestTrophies = most
        }
        // 「現在」が 2 つあるとき: 「最多」と同じ列（x が近い）ほうがトロフィー、「最高」と同じ列がガチバトル
        let mostX = mostHits.first?.0.midX
        let highestX = highestHits.first?.0.midX
        for label in currentLabels {
            guard let v = valueBelow(label) else { continue }
            let toTrophy = mostX.map { abs(label.midX - $0) } ?? 1
            let toRanked = highestX.map { abs(label.midX - $0) } ?? 1
            if toTrophy <= toRanked { result.trophies = result.trophies ?? v }
            else { result.rankedCurrent = result.rankedCurrent ?? v }
        }
        if result.trophies == nil {
            result.trophies = trophyLabels.compactMap(valueBelow).first
        }
        result.rankedHighest = highestHits.first?.1

        // ランク名が文字で出ていれば最高ランク。ただし「以前のステータス」（昔のパワーリーグ等）の欄は除く
        let pastLabels = lines.filter { $0.text.contains("以前") || $0.text.uppercased().contains("PREVIOUS") }
        let ranks = lines.filter { line in
            !pastLabels.contains { past in
                line.midY < past.midY && past.midY - line.midY < 0.2 && abs(line.midX - past.midX) < 0.15
            }
        }.compactMap { RankTier.parse($0.text) }
        result.highestRank = ranks.max()
        return result
    }

    private static func isLabel(_ text: String, _ words: [String]) -> Bool {
        let t = text.replacingOccurrences(of: " ", with: "").uppercased()
        return words.contains { t.contains($0.replacingOccurrences(of: " ", with: "")) } && t.count <= 10
    }

    /// 名前の飾り（❄ などの記号）を落とす
    private static func clean(_ text: String) -> String {
        text.unicodeScalars
            .filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
    }

    /// "38,420" "38 420" "38420" → 38420
    private static func number(in text: String) -> Int? {
        guard let r = text.range(of: #"\d[\d,\.]{0,9}\d|\d"#, options: .regularExpression) else { return nil }
        let digits = text[r].filter(\.isNumber)
        return Int(digits)
    }
}

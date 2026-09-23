import CoreGraphics
import Foundation
import Vision

/// モード名の文字を読んでアーキタイプ重みを引くためのオンデバイス OCR。
///
/// ブラインドピック画面にはマップ画像が無く、代わりに「ノックアウト」のような
/// モード名がテキストで表示される。小さいアイコンをテンプレートマッチするより、
/// Vision の日本語 OCR で直接文字を読む方が新モード追加にも強く、境界のズレにも強い。
enum ModeRecognizer {
    /// Vision の初回コールドスタート（モデル読み込み）を、本番解析の前に済ませておく。
    /// 起動時に小さな空画像で軽く空撃ちするだけなので、結果は使わない。
    static func warmUp() {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                  bytesPerRow: 32, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let dummy = ctx.makeImage() else { return }
        _ = recognizeText(dummy)
    }

    /// クロップした領域から、rules.json の modes に載っているモード名を推定する。
    /// 認識できなければ nil（呼び出し側はモード非依存のスコアリングにフォールバックする）。
    static func recognizeMode(in raster: ImageRaster, region: NRect,
                              modes: [String: ModeInfo]) -> String? {
        guard let cgImage = makeCGImage(raster: raster, region: region) else { return nil }
        guard let text = recognizeText(cgImage) else { return nil }
        return bestMatch(for: text, in: modes)
    }

    // MARK: - Vision 呼び出し

    private static func recognizeText(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = false  // モード名は固有名詞なので補正しない方が安定
        request.recognitionLevel = .accurate

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }
        // 複数行（モード名 + サブタイトル）をまとめて 1 文字列にする
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " ")
    }

    /// OCR 結果からもっとも近いモードを選ぶ。
    /// 完全一致・部分一致・簡易編集距離の順で試す（OCR の誤読に強くするため）。
    static func bestMatch(for text: String, in modes: [String: ModeInfo]) -> String? {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }

        // 部分一致（OCR が前後にゴミを拾っても、モード名の連続した文字列は残りやすい）
        for (key, info) in modes where cleaned.contains(info.ja) || info.ja.contains(cleaned) {
            return key
        }

        // 簡易編集距離でいちばん近いものを選ぶ（1〜2 文字の誤読を許容）
        var best: (key: String, distance: Int)?
        for (key, info) in modes {
            let d = levenshtein(cleaned, info.ja)
            if best == nil || d < best!.distance {
                best = (key, d)
            }
        }
        guard let best, best.distance <= max(2, best.key.count / 2) else { return nil }
        return best.key
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : 1 + min(prev[j - 1], prev[j], curr[j - 1])
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    // MARK: - 画像切り出し

    private static func makeCGImage(raster: ImageRaster, region: NRect) -> CGImage? {
        let size = CGSize(width: raster.width, height: raster.height)
        let rect = region.rect(in: size).integral
            .intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        guard rect.width >= 4, rect.height >= 4 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: raster.width, height: raster.height,
            bitsPerComponent: 8, bytesPerRow: raster.width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        raster.buf.withUnsafeBytes { ptr in
            ctx.data?.copyMemory(from: ptr.baseAddress!, byteCount: ptr.count)
        }
        guard let full = ctx.makeImage() else { return nil }
        return full.cropping(to: rect)
    }
}

import CoreGraphics
import Foundation

/// 画像 1 枚ぶんの特徴量。テンプレートも照合対象も同じ形で持つ。
struct Descriptor {
    /// 16x16 の輝度ベクトル。平均 0・ノルム 1 に正規化済み（内積がそのまま相関係数になる）。
    var gray: [Float]
    /// 4x4 ブロックの平均 RGB。同じく正規化済み。
    var color: [Float]
    /// 8x8 dHash。粗いふるい分け用。
    var dhash: UInt64
    /// 正規化前の輝度の標準偏差（0〜1）。空きスロットは平坦なのでこれで弾ける。
    var contrast: Float = 0
}

/// スクリーンショットを 1 度だけ展開した RGBX8 バッファ。
///
/// 切り出しごとに CoreGraphics を呼ぶと描画コストが積み上がるので、
/// 解析の最初に 1 回だけラスタライズし、以降はこのバッファ上の算術だけで済ませる。
struct ImageRaster {
    var buf: [UInt8]      // RGBX8, 4 bytes/px
    var width: Int
    var height: Int

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
}

/// CGImage から `Descriptor` を作る。
///
/// **重要**: ここでの手順は `scripts/download_icons.py` の `build_descriptor()` と
/// 1 対 1 で対応している。どちらかを変えたらもう片方も必ず変えること。
///   1. 指定矩形で切り出す
///   2. 透過はグレー 128 の上に合成する
///   3. 長辺に合わせた正方形へ中央配置（余白もグレー 128）
///   4. **面積平均**で目的の解像度へ縮小
///      （Pillow の BOX フィルタと同じ計算。CoreGraphics の補間に任せると
///        Pillow との差で自己相関が 0.90 程度まで落ち、似たキャラの判別が不安定になる）
///   5. BT.601 で輝度化 → 平均 0 / ノルム 1 へ正規化
enum ImageDescriptor {
    static let graySize = 16
    static let colorSize = 4
    static let hashSize = 8

    private static let padding: Double = 128
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    struct RGBf { var r: Double; var g: Double; var b: Double }

    // MARK: - ラスタライズ

    /// 等倍（または長辺 `maxSide` 以下）で RGBX バッファへ展開する。
    /// 透過はグレー 128 の上に合成される。
    static func rasterize(_ image: CGImage, maxSide: Int? = nil) -> ImageRaster? {
        var w = image.width
        var h = image.height
        guard w > 0, h > 0 else { return nil }

        if let maxSide, max(w, h) > maxSide {
            let scale = Double(maxSide) / Double(max(w, h))
            w = max(1, Int((Double(w) * scale).rounded()))
            h = max(1, Int((Double(h) * scale).rounded()))
        }

        var buf = [UInt8](repeating: UInt8(padding), count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            let gray = CGFloat(padding) / 255
            ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? ImageRaster(buf: buf, width: w, height: h) : nil
    }

    // MARK: - 記述子

    /// ラスタ上の矩形（左上原点のピクセル座標）から記述子を作る。
    static func make(from raster: ImageRaster, crop: CGRect? = nil) -> Descriptor? {
        let region = (crop ?? raster.bounds).integral.intersection(raster.bounds)
        guard region.width >= 2, region.height >= 2 else { return nil }

        let gray16 = boxResize(raster, region: region, outW: graySize, outH: graySize)
        let color4 = boxResize(raster, region: region, outW: colorSize, outH: colorSize)
        let hash9 = boxResize(raster, region: region, outW: hashSize + 1, outH: hashSize)

        let rawGray = gray16.map { Float(luma($0) / 255) }
        let grayVec = normalized(rawGray)
        let colorVec = normalized(color4.flatMap {
            [Float($0.r / 255), Float($0.g / 255), Float($0.b / 255)]
        })

        let mean = rawGray.reduce(0, +) / Float(rawGray.count)
        let contrast = sqrt(rawGray.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(rawGray.count))

        var bits: UInt64 = 0
        for y in 0..<hashSize {
            for x in 0..<hashSize {
                bits <<= 1
                let i = y * (hashSize + 1) + x
                if luma(hash9[i]) > luma(hash9[i + 1]) { bits |= 1 }
            }
        }
        return Descriptor(gray: grayVec, color: colorVec, dhash: bits, contrast: contrast)
    }

    /// 単発利用の便利版（テンプレート生成の検証などで使う）。
    static func make(from image: CGImage, crop: CGRect? = nil) -> Descriptor? {
        guard let raster = rasterize(image) else { return nil }
        return make(from: raster, crop: crop)
    }

    // MARK: - 内部

    private static func luma(_ p: RGBf) -> Double {
        0.299 * p.r + 0.587 * p.g + 0.114 * p.b
    }

    /// 正方形パディングを前提にした面積平均縮小（Pillow の BOX と同じ計算）。
    ///
    /// 出力セルが元画像の外へはみ出すぶんはパディング色（グレー 128）として重み付けする。
    private static func boxResize(_ src: ImageRaster, region: CGRect,
                                  outW: Int, outH: Int) -> [RGBf] {
        let rx = Int(region.origin.x)
        let ry = Int(region.origin.y)
        let rw = Int(region.width)
        let rh = Int(region.height)
        let w = Double(rw)
        let h = Double(rh)
        let side = max(w, h)
        let offsetX = (side - w) / 2
        let offsetY = (side - h) / 2
        let cellW = side / Double(outW)
        let cellH = side / Double(outH)
        let area = cellW * cellH

        var out = [RGBf]()
        out.reserveCapacity(outW * outH)

        src.buf.withUnsafeBufferPointer { px in
            for oy in 0..<outH {
                // 正方形座標 -> 切り出し領域内の座標
                let sy0 = Double(oy) * cellH - offsetY
                let sy1 = sy0 + cellH
                let iy0 = max(0, Int(sy0.rounded(.down)))
                let iy1 = min(rh, Int(sy1.rounded(.up)))

                for ox in 0..<outW {
                    let sx0 = Double(ox) * cellW - offsetX
                    let sx1 = sx0 + cellW
                    let ix0 = max(0, Int(sx0.rounded(.down)))
                    let ix1 = min(rw, Int(sx1.rounded(.up)))

                    var sumR = 0.0, sumG = 0.0, sumB = 0.0, covered = 0.0
                    if iy1 > iy0 && ix1 > ix0 {
                        for py in iy0..<iy1 {
                            let wy = min(sy1, Double(py + 1)) - max(sy0, Double(py))
                            if wy <= 0 { continue }
                            let row = (ry + py) * src.width * 4
                            for pxi in ix0..<ix1 {
                                let wx = min(sx1, Double(pxi + 1)) - max(sx0, Double(pxi))
                                if wx <= 0 { continue }
                                let weight = wx * wy
                                let i = row + (rx + pxi) * 4
                                sumR += Double(px[i]) * weight
                                sumG += Double(px[i + 1]) * weight
                                sumB += Double(px[i + 2]) * weight
                                covered += weight
                            }
                        }
                    }
                    let padArea = max(0, area - covered)
                    let total = covered + padArea
                    out.append(RGBf(
                        r: (sumR + padding * padArea) / total,
                        g: (sumG + padding * padArea) / total,
                        b: (sumB + padding * padArea) / total
                    ))
                }
            }
        }
        return out
    }

    /// 平均 0・ノルム 1 に揃える。これで内積 = 正規化相互相関 (NCC) になる。
    static func normalized(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return values }
        let mean = values.reduce(0, +) / Float(values.count)
        var centered = values.map { $0 - mean }
        let norm = sqrt(centered.reduce(0) { $0 + $1 * $1 })
        if norm > 1e-6 {
            for i in centered.indices { centered[i] /= norm }
        }
        return centered
    }
}

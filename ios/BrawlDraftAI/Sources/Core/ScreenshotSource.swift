import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// 解析対象のスクリーンショットをどこから取るか。
enum ScreenshotSource {
    enum Failure: LocalizedError {
        case photoAccessDenied
        case noScreenshotFound
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .photoAccessDenied:
                return "写真へのアクセスが許可されていません（設定 > プライバシー > 写真）"
            case .noScreenshotFound:
                return "スクリーンショットが見つかりませんでした"
            case .decodeFailed:
                return "画像を読み込めませんでした"
            }
        }
    }

    /// バイト列から CGImage を作る（ショートカットが渡してくる IntentFile 用）。
    static func image(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: false
              ] as CFDictionary)
        else { throw Failure.decodeFailed }
        return image
    }

    /// 写真ライブラリの「最新のスクリーンショット」を取る。
    ///
    /// 背面タップ → スクリーンショット撮影 → 背面タップでショートカット、という
    /// 運用のときはこちらが入口になる。
    static func latestScreenshot(maxSide: CGFloat = 1600) async throws -> CGImage {
        try await ensurePhotoAccess()

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        guard let asset = assets.firstObject else { throw Failure.noScreenshotFound }

        let scale = maxSide / CGFloat(max(asset.pixelWidth, asset.pixelHeight))
        let target = scale < 1
            ? CGSize(width: CGFloat(asset.pixelWidth) * scale,
                     height: CGFloat(asset.pixelHeight) * scale)
            : CGSize(width: asset.pixelWidth, height: asset.pixelHeight)

        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .exact
        requestOptions.isNetworkAccessAllowed = false

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: target, contentMode: .aspectFit, options: requestOptions
            ) { image, _ in
                if let cg = image?.cgImage {
                    continuation.resume(returning: cg)
                } else {
                    continuation.resume(throwing: Failure.decodeFailed)
                }
            }
        }
    }

    /// ファイルパスから読む（ショートカットが App Group へ書き出した場合など）。
    static func image(atPath path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.decodeFailed }
        return image
    }

    private static func ensurePhotoAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard granted == .authorized || granted == .limited else {
                throw Failure.photoAccessDenied
            }
        default:
            throw Failure.photoAccessDenied
        }
    }
}

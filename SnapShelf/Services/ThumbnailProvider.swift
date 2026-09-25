import AppKit
import ImageIO
import SwiftUI

/// Decodes and caches thumbnail images for screenshot files. Decoding happens off the main actor;
/// the `NSCache` itself is only ever touched from the main actor.
@MainActor
@Observable
final class ThumbnailProvider {
    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image = await Task.detached(priority: .userInitiated) {
            Self.decodeThumbnail(at: url, maxPixelSize: maxPixelSize)
        }.value

        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    /// Test-only seam: seeds the cache for a URL/size pair that `thumbnail(for:maxPixelSize:)`
    /// would otherwise have to decode from disk. Lets a rendering test give `ScreenshotThumbnail`
    /// real, already-decoded image content synchronously instead of racing its `.task` against a
    /// snapshot renderer that doesn't wait for async work. Production code never calls this.
    func preloadForTesting(_ image: NSImage, url: URL, maxPixelSize: CGFloat) {
        cache.setObject(image, forKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize))
    }

    nonisolated private static func cacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        "\(url.path)|\(Int(maxPixelSize))" as NSString
    }

    nonisolated private static func decodeThumbnail(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Loads and displays a screenshot's thumbnail, decoding off the main thread and reloading
/// whenever the source URL changes.
struct ScreenshotThumbnail: View {
    let url: URL
    var maxPixelSize: CGFloat = 240
    var contentMode: ContentMode = .fill

    @Environment(ThumbnailProvider.self) private var thumbnailProvider
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(.quaternary)
            }
        }
        .task(id: url) {
            image = await thumbnailProvider.thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

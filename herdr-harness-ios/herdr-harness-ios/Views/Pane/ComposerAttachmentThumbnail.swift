import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Produces a small encoded preview without retaining the full-size source or a
/// decoded UI image. Preview generation happens before upload cleanup.
enum ComposerAttachmentThumbnail {
    static let maximumPixelDimension = 96
    static let maximumEncodedBytes = 64 * 1_024

    static func encodedData(at url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return encodedData(from: source)
    }

    static func encodedData(from data: Data) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return encodedData(from: source)
    }

    /// Uses ImageIO's thumbnail path even if malformed state supplies compressed
    /// data with unexpectedly large pixel dimensions.
    static func boundedImage(from data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let image = thumbnail(from: source)
        else { return nil }
        return UIImage(cgImage: image)
    }

    private static func encodedData(from source: CGImageSource) -> Data? {
        guard let image = thumbnail(from: source) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.72,
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = output as Data
        return data.count <= maximumEncodedBytes ? data : nil
    }

    private static func thumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

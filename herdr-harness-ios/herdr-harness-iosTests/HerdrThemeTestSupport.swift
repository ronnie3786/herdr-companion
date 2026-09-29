import CryptoKit
import SwiftUI
import Testing
import UIKit
@testable import herdr_harness_ios

enum ThemeContrast {
    typealias RGB = SIMD3<Double>

    static func rgb(_ color: Color) -> RGB {
        let value = color.resolve(in: EnvironmentValues())
        return RGB(Double(value.red), Double(value.green), Double(value.blue)) * 255
    }

    static func over(_ fill: Color, _ background: RGB) -> RGB {
        let alpha = Double(fill.resolve(in: EnvironmentValues()).opacity)
        return rgb(fill) * alpha + background * (1 - alpha)
    }

    static func luminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            let value = channel / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }

    static func ratio(_ first: RGB, _ second: RGB) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

struct ThemeRaster {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let cg = try #require(image.cgImage)
        width = cg.width
        height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let width = width, height = height
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        bytes = pixels
    }

    var isOpaque: Bool { stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 } }
    var sha256: String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }

    var brightest: ThemeContrast.RGB {
        stride(from: 0, to: bytes.count, by: 4).map { i in
            ThemeContrast.RGB(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2]))
        }.max { ThemeContrast.luminance($0) < ThemeContrast.luminance($1) } ?? .zero
    }
}

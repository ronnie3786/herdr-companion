import SwiftUI
import UIKit

/// The Mac face's drawing and glow, rasterized once. A small fixed frame bank
/// keeps the glow out of live rendering during a blink or list scroll.
/// The blink schedule and 10% closed-eye geometry remain the Mac's; only the
/// raster selection is quantized, to at most 0.18 design points of eye height.
/// Core Graphics builds these frames independently of the live SwiftUI render
/// pass, including when the cache is first requested from TimelineView.
@MainActor
enum FirstMateFaceArtwork {
    static let frameCount = 31

    static func image(eyeScale: CGFloat) -> UIImage {
        let scale = eyeScale.isFinite ? min(1, max(0.1, eyeScale)) : 1
        let index = Int(((scale - 0.1) / 0.9 * CGFloat(frameCount - 1)).rounded())
        return frames[index]
    }

    private static let frames: [UIImage] = (0..<frameCount).map { index in
        render(eyeScale: 0.1 + 0.9 * CGFloat(index) / CGFloat(frameCount - 1))
    }

    private static func render(eyeScale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format)
        return renderer.image { output in
            let context = output.cgContext
            context.translateBy(x: 48, y: 48)
            context.scaleBy(x: 2, y: 2)
            context.setShadow(offset: .zero, blur: 2, color: UIColor(HerdrTheme.accent.opacity(0.8)).cgColor)
            context.setFillColor(UIColor(FirstMateFaceOrb.faceColor).cgColor)
            let height: CGFloat = 12 * eyeScale
            for x: CGFloat in [-12.5, 4.5] {
                let eye = CGRect(x: x, y: -4 - height / 2, width: 8, height: height)
                let radius = min(4, height / 2)
                context.addPath(CGPath(roundedRect: eye, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
            context.move(to: CGPoint(x: -5.5, y: 9.5))
            context.addQuadCurve(to: CGPoint(x: 5.5, y: 9.5), control: CGPoint(x: 0, y: 13.5))
            context.setStrokeColor(UIColor(FirstMateFaceOrb.faceColor).cgColor)
            context.setLineWidth(2.2)
            context.setLineCap(.round)
            context.strokePath()
        }
    }
}

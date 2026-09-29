import SwiftUI
import UIKit

/// The Mac face's drawing and glow, rasterized once. A small fixed frame bank
/// keeps the glow out of live Canvas rendering during a blink or list scroll.
/// The blink schedule and 10% closed-eye geometry remain the Mac's; only the
/// raster selection is quantized, to at most 0.18 design points of eye height.
@MainActor
enum FirstMateFaceArtwork {
    static let frameCount = 31

    static func image(eyeScale: CGFloat) -> UIImage {
        let scale = eyeScale.isFinite ? min(1, max(0.1, eyeScale)) : 1
        let index = Int(((scale - 0.1) / 0.9 * CGFloat(frameCount - 1)).rounded())
        return frames[index]
    }

    private static let frames: [UIImage] = (0..<frameCount).map { index in
        let scale = 0.1 + 0.9 * CGFloat(index) / CGFloat(frameCount - 1)
        let renderer = ImageRenderer(content: FirstMateFaceDrawing(eyeScale: scale).frame(width: 96, height: 96))
        renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }
}

/// Offscreen only. Shapes and shadow retain the Mac's 48-unit coordinates.
private struct FirstMateFaceDrawing: View {
    let eyeScale: CGFloat

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 48
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: unit, y: unit)
            context.addFilter(.shadow(color: HerdrTheme.accent.opacity(0.8), radius: 2))
            let height: CGFloat = 12 * eyeScale
            for x: CGFloat in [-12.5, 4.5] {
                let eye = CGRect(x: x, y: -4 - height / 2, width: 8, height: height)
                context.fill(Path(roundedRect: eye, cornerRadius: min(4, height / 2)), with: .color(FirstMateFaceOrb.faceColor))
            }
            var mouth = Path()
            mouth.move(to: CGPoint(x: -5.5, y: 9.5))
            mouth.addQuadCurve(to: CGPoint(x: 5.5, y: 9.5), control: CGPoint(x: 0, y: 13.5))
            context.stroke(mouth, with: .color(FirstMateFaceOrb.faceColor),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }
}

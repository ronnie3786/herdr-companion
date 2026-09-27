import AppKit
import CoreImage
import SwiftUI

/// Legible glass: Herdr's dusk backdrop shows softly through the sidebar
/// (base at 80%), the pane (75%) and the HUD (78%). The backdrop is one
/// Herdr-owned image drawn once and stretched, not the desktop: the system's
/// behind-window materials flatten any wallpaper to gray, and a true desktop
/// blur needs private window APIs. No live blur runs anywhere.
///
/// Glass is on when the person has it on in Settings → General → Appearance,
/// Reduce Transparency is off, and the window is dark. First Mate's light
/// appearance stays opaque.
enum HerdrGlass {
    static func isActive(enabled: Bool, reduceTransparency: Bool, colorScheme: ColorScheme) -> Bool {
        enabled && !reduceTransparency && colorScheme == .dark
    }
}

extension EnvironmentValues {
    /// True inside the main window while its surfaces are glass. Screens in
    /// the detail column then leave their background to the shell.
    @Entry var herdrGlassActive = false
    /// True when the Haze band should show behind the chat (needs glass).
    @Entry var herdrHazeActive = false
}

/// A glass surface: `base` at `level` over the dusk backdrop, or an opaque
/// `base` when glass is off.
struct HerdrGlassBackground: View {
    let level: Double
    var base: Color = HerdrTheme.windowBackground
    var cornerRadius: CGFloat = 0
    /// Draws its own dusk under the base. A floating panel (the HUD) needs
    /// this; the main window draws one dusk behind both columns instead, so
    /// the sidebar and pane share a single continuous backdrop.
    var drawsDusk = false
    var duskRegion: HerdrDuskBackdrop.Region = .whole
    @Environment(\.herdrGlassActive) private var isActive

    var body: some View {
        if isActive {
            ZStack {
                if drawsDusk { HerdrDuskBackdrop(region: duskRegion) }
                base.opacity(level)
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
        } else {
            base.clipShape(.rect(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    /// A detail screen's own background: opaque base, or nothing while the
    /// shell's pane glass shows through.
    func herdrPaneBackground(_ color: Color = HerdrTheme.windowBackground, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View {
        modifier(HerdrPaneBackgroundModifier(color: color, edges: edges))
    }
}

private struct HerdrPaneBackgroundModifier: ViewModifier {
    let color: Color
    let edges: Edge.Set
    @Environment(\.herdrGlassActive) private var isActive

    func body(content: Content) -> some View {
        content.background(isActive ? Color.clear : color, ignoresSafeAreaEdges: edges)
    }
}

/// The dusk backdrop under Legible glass: violet from the top left, rose at
/// the top right, indigo along the bottom. One cached image, stretched to the
/// surface like the study's percentage-based gradients.
struct HerdrDuskBackdrop: View {
    enum Region {
        /// The whole scene, for the main window.
        case whole
        /// The right half (rose above, indigo below), for the HUD, which sits
        /// at the top right of the screen.
        case trailingHalf
    }

    var region: Region = .whole

    var body: some View {
        Image(nsImage: region == .whole ? HerdrDusk.image : HerdrDusk.trailingHalf)
            .resizable()
            .interpolation(.high)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum HerdrDusk {
    /// The study's desktop art (`DESK` in theme-study-v2), blurred the way
    /// the study blurs it (24pt across a 1336pt window) and saturated 110%.
    @MainActor static let image: NSImage = render(size: CGSize(width: 640, height: 400))
    @MainActor static let trailingHalf: NSImage = {
        let size = image.size
        guard let whole = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let half = whole.cropping(to: CGRect(x: whole.width / 2, y: 0, width: whole.width / 2, height: whole.height))
        else { return image }
        return NSImage(cgImage: half, size: CGSize(width: size.width / 2, height: size.height))
    }()

    /// A CSS `radial-gradient(rx% ry% at x% y%, color, transparent stop%)`.
    struct Glow {
        var center: CGPoint
        var radii: CGSize
        var stop: CGFloat
        var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    }

    /// Top of the stack last. Positions and radii are fractions of the size,
    /// measured from the top left.
    static let glows: [Glow] = [
        Glow(center: CGPoint(x: 0.20, y: 0.95), radii: CGSize(width: 0.60, height: 0.60), stop: 0.60,
             red: 96, green: 58, blue: 160, alpha: 0.65),
        Glow(center: CGPoint(x: 0.70, y: 1.00), radii: CGSize(width: 0.80, height: 0.70), stop: 0.65,
             red: 52, green: 70, blue: 168, alpha: 0.80),
        Glow(center: CGPoint(x: 0.88, y: 0.06), radii: CGSize(width: 0.55, height: 0.50), stop: 0.60,
             red: 214, green: 120, blue: 178, alpha: 0.60),
        Glow(center: CGPoint(x: 0.12, y: 0.08), radii: CGSize(width: 0.70, height: 0.60), stop: 0.62,
             red: 132, green: 98, blue: 222, alpha: 0.95),
    ]

    private static func render(size: CGSize) -> NSImage {
        let width = Int(size.width), height = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }

        // #2a1d4a at the top, #171a36 at 55%, #0f1226 at the bottom.
        let sky = [
            CGColor(srgbRed: 42 / 255, green: 29 / 255, blue: 74 / 255, alpha: 1),
            CGColor(srgbRed: 23 / 255, green: 26 / 255, blue: 54 / 255, alpha: 1),
            CGColor(srgbRed: 15 / 255, green: 18 / 255, blue: 38 / 255, alpha: 1),
        ]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        }
        for glow in glows {
            let color = CGColor(srgbRed: glow.red / 255, green: glow.green / 255, blue: glow.blue / 255, alpha: glow.alpha)
            guard let clear = color.copy(alpha: 0),
                  let gradient = CGGradient(colorsSpace: space, colors: [color, clear] as CFArray, locations: [0, 1])
            else { continue }
            let radiusX = glow.radii.width * size.width
            let radiusY = glow.radii.height * size.height
            context.saveGState()
            // Bitmap y runs up; the study measures from the top.
            context.translateBy(x: glow.center.x * size.width, y: (1 - glow.center.y) * size.height)
            context.scaleBy(x: 1, y: radiusY / radiusX)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: radiusX * glow.stop, options: [])
            context.restoreGState()
        }
        guard let drawn = context.makeImage() else { return NSImage(size: size) }

        let input = CIImage(cgImage: drawn)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 24 * size.width / 1336)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
            .cropped(to: input.extent)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = ciContext.createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: space) else {
            return NSImage(cgImage: drawn, size: size)
        }
        return NSImage(cgImage: output, size: size)
    }
}

/// MonoCode's Haze: a soft dusk band at the top of the chat, drawn once from
/// a built-in gradient that is blurred with Core Image and cached. It is one
/// static image behind the transcript, never a per-row or live blur.
struct HerdrHazeBand: View {
    var height: CGFloat = 280
    @Environment(\.herdrHazeActive) private var isActive

    var body: some View {
        if isActive {
            Image(nsImage: HerdrHaze.image)
                .resizable()
                .interpolation(.medium)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .opacity(0.24)
                .mask {
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

enum HerdrHaze {
    /// A 480×180 dusk gradient (violet, magenta, indigo), blurred once.
    @MainActor static let image: NSImage = render(size: CGSize(width: 480, height: 180))

    private static func render(size: CGSize) -> NSImage {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage(size: size) }
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.11, blue: 0.29, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let blobs: [(CGPoint, CGFloat, CGColor)] = [
            (CGPoint(x: size.width * 0.18, y: size.height * 0.85), size.width * 0.45,
             CGColor(srgbRed: 0.52, green: 0.38, blue: 0.87, alpha: 1)),
            (CGPoint(x: size.width * 0.82, y: size.height * 0.9), size.width * 0.4,
             CGColor(srgbRed: 0.56, green: 0.30, blue: 0.55, alpha: 1)),
            (CGPoint(x: size.width * 0.5, y: size.height * 0.1), size.width * 0.5,
             CGColor(srgbRed: 0.14, green: 0.18, blue: 0.42, alpha: 1)),
        ]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (center, radius, color) in blobs {
            let clear = color.copy(alpha: 0) ?? color
            guard let gradient = CGGradient(colorsSpace: space, colors: [color, clear] as CFArray, locations: [0, 1]) else { continue }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        guard let drawn = context.makeImage() else { return NSImage(size: size) }
        let input = CIImage(cgImage: drawn)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 18)
            .cropped(to: input.extent)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = ciContext.createCGImage(blurred, from: input.extent) else {
            return NSImage(cgImage: drawn, size: size)
        }
        return NSImage(cgImage: output, size: size)
    }
}

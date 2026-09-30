import AppKit
import CoreImage
import SwiftUI

/// Legible glass: Herdr's dusk backdrop shows softly through the sidebar
/// and the pane (base at 80%) and the HUD (78%). The backdrop is one
/// Herdr-owned image drawn once and stretched. The standalone First Mate
/// window also lets a little native behind-window material show through;
/// the other windows retain their painted backdrop.
///
/// Glass is on when the person has it on in Settings → General → Appearance,
/// Reduce Transparency is off, and the window is dark. First Mate's light
/// appearance stays opaque.
enum HerdrGlass {
    /// Herdr's one background-brightness factor. Every background the purple
    /// glass and haze theme draws — the cached dusk artwork, the cached Haze
    /// artwork, and the `base` color of an active `HerdrGlassBackground` — is
    /// multiplied by this once, in encoded sRGB. That deepens the purple about
    /// 20% while preserving hue, alpha, the gradient geometry, blur,
    /// saturation, cropping, glass levels, and the opaque Glass-off, First Mate
    /// light, and Reduce Transparency branches. Foreground text, icons, and
    /// status colors are untouched, so reading text gains contrast.
    static let backgroundBrightness = 0.80

    /// Keep 88% of the authored purple surface above the native desktop blur.
    /// This affects backgrounds only, never text or controls.
    static let desktopSurfaceOpacity = 0.88

    /// With the column's base drawn at `level * desktopSurfaceOpacity`, this
    /// leaves exactly 12% for the native material and retains the dusk's hue.
    static func desktopDuskOpacity(level: Double = HerdrTheme.Glass.pane) -> Double {
        (1 - level) * desktopSurfaceOpacity / (1 - level * desktopSurfaceOpacity)
    }

    static func isActive(enabled: Bool, reduceTransparency: Bool, colorScheme: ColorScheme) -> Bool {
        enabled && !reduceTransparency && colorScheme == .dark
    }

    /// `color` with every sRGB channel multiplied once by `brightness`, keeping
    /// its alpha. Only an active `HerdrGlassBackground` composes its base this
    /// way; foreground tokens and the opaque Glass-off branch use `color`
    /// unchanged.
    static func darkened(_ color: Color, scheme: ColorScheme, brightness: Double = backgroundBrightness) -> Color {
        let value = HerdrTheme.resolved(color, scheme: scheme)
        return Color(
            .sRGB,
            red: value.redComponent * brightness,
            green: value.greenComponent * brightness,
            blue: value.blueComponent * brightness,
            opacity: value.alphaComponent
        )
    }
}

/// Multiplies an opaque sRGB bitmap's channels by `factor` once, in encoded
/// sRGB, and preserves alpha. The authored gradient inputs never change: the
/// study's colors and geometry render exactly as before, then the cached
/// artwork itself carries the deeper shade. Applied to whichever bitmap a
/// render ends with, so image-rendering fallback paths darken too.
private func herdrDarkened(_ image: CGImage, by factor: Double) -> CGImage {
    let width = image.width, height = image.height
    guard factor != 1,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return image }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return image }
    let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for index in stride(from: 0, to: width * height * 4, by: 4) {
        buffer[index] = UInt8((Double(buffer[index]) * factor).rounded())
        buffer[index + 1] = UInt8((Double(buffer[index + 1]) * factor).rounded())
        buffer[index + 2] = UInt8((Double(buffer[index + 2]) * factor).rounded())
        // Alpha stays: the factor darkens color only.
    }
    return context.makeImage() ?? image
}

extension EnvironmentValues {
    /// True inside the main window while its surfaces are glass. Screens in
    /// the detail column then leave their background to the shell.
    @Entry var herdrGlassActive = false
    /// True when the Haze band should show behind the chat (needs glass).
    @Entry var herdrHazeActive = false
    /// Only the standalone First Mate scene opts into desktop translucency.
    @Entry var herdrDesktopGlassActive = false
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
    /// Internal rendering seam for deterministic tests: `1` composes the
    /// authored baseline. Production always uses
    /// ``HerdrGlass/backgroundBrightness``.
    var brightness: Double = HerdrGlass.backgroundBrightness
    @Environment(\.herdrGlassActive) private var isActive
    @Environment(\.herdrDesktopGlassActive) private var desktopGlass
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isActive {
            ZStack {
                if drawsDusk { HerdrDuskBackdrop(region: duskRegion, brightness: brightness) }
                HerdrGlass.darkened(base, scheme: colorScheme, brightness: brightness)
                    .opacity(level * (desktopGlass ? HerdrGlass.desktopSurfaceOpacity : 1))
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
///
/// Its brightest point sets the text floor: `HerdrThemeAccessibilityTests`
/// checks every text level on the pane's fills over it.
struct HerdrDuskBackdrop: View {
    enum Region {
        /// The whole scene, for the main window.
        case whole
        /// The right half (rose above, indigo below), for the HUD, which sits
        /// at the top right of the screen.
        case trailingHalf
    }

    var region: Region = .whole
    /// Internal rendering seam for deterministic tests: `1` draws the unscaled
    /// baseline. Production always draws the cached darkened artwork.
    var brightness: Double = HerdrGlass.backgroundBrightness

    var body: some View {
        Image(nsImage: artwork)
            .resizable()
            .interpolation(.high)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var artwork: NSImage {
        let baseline = brightness == 1
        switch region {
        case .whole: return baseline ? HerdrDusk.baselineImage : HerdrDusk.image
        case .trailingHalf: return baseline ? HerdrDusk.baselineTrailingHalf : HerdrDusk.trailingHalf
        }
    }
}

enum HerdrDusk {
    static let size = CGSize(width: 640, height: 400)

    /// The study's sky, top to bottom: #2a1d4a, #171a36 at 55%, #0f1226.
    /// Kept as authored; the brightness factor applies after drawing.
    struct SkyStop {
        var location: CGFloat
        var red: Double, green: Double, blue: Double
    }

    static let sky: [SkyStop] = [
        SkyStop(location: 0, red: 42, green: 29, blue: 74),
        SkyStop(location: 0.55, red: 23, green: 26, blue: 54),
        SkyStop(location: 1, red: 15, green: 18, blue: 38),
    ]

    /// The study's blur: 24pt across a 1336pt window, and its 110% saturation.
    static let blurSigma: CGFloat = 24
    static let blurReferenceWidth: CGFloat = 1336
    static let saturation: CGFloat = 1.1

    /// The study's desktop art (`DESK` in theme-study-v2), blurred the way
    /// the study blurs it (24pt across a 1336pt window) and saturated 110%.
    /// The violet glow is at 80% rather than the study's 95%, so tertiary text
    /// on a selected card at its center still reads at 4.5:1.
    ///
    /// Tests pin ``baselineImage`` and compare the cached ``image``, which is
    /// the baseline with ``HerdrGlass/backgroundBrightness`` applied once.
    @MainActor static let baselineImage: NSImage = artwork(brightness: 1)
    @MainActor static let image: NSImage = artwork(brightness: HerdrGlass.backgroundBrightness)

    /// The right half of the same artwork, for the HUD, which sits at the top
    /// right of the screen.
    @MainActor static let trailingHalf: NSImage = cropped(image)
    @MainActor static let baselineTrailingHalf: NSImage = cropped(baselineImage)

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
             red: 132, green: 98, blue: 222, alpha: 0.80),
    ]

    @MainActor private static let drawnArtwork: CGImage? = render(size: size)

    @MainActor private static func artwork(brightness: Double) -> NSImage {
        guard let drawnArtwork else { return NSImage(size: size) }
        let image = brightness == 1 ? drawnArtwork : herdrDarkened(drawnArtwork, by: brightness)
        return NSImage(cgImage: image, size: size)
    }

    @MainActor private static func cropped(_ image: NSImage) -> NSImage {
        let size = image.size
        guard let whole = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let half = whole.cropping(to: CGRect(x: whole.width / 2, y: 0, width: whole.width / 2, height: whole.height))
        else { return image }
        return NSImage(cgImage: half, size: CGSize(width: size.width / 2, height: size.height))
    }

    private static func render(size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let skyColors = sky.map {
            CGColor(srgbRed: $0.red / 255, green: $0.green / 255, blue: $0.blue / 255, alpha: 1)
        }
        if let gradient = CGGradient(colorsSpace: space, colors: skyColors as CFArray, locations: sky.map(\.location)) {
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
        guard let drawn = context.makeImage() else { return nil }

        let input = CIImage(cgImage: drawn)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: blurSigma * size.width / blurReferenceWidth)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
            .cropped(to: input.extent)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = ciContext.createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: space) else {
            return drawn
        }
        return output
    }
}

/// MonoCode's Haze: a soft dusk band at the top of the chat, drawn once from
/// a built-in gradient that is blurred with Core Image and cached. It is one
/// static image behind the transcript, never a per-row or live blur.
struct HerdrHazeBand: View {
    /// 6%, not the study's 24%: the band now sits over the dusk, and its
    /// violet lands on the dusk's own. The contrast tests hold it to 4.5:1.
    static let opacity = 0.06
    var height: CGFloat = 280
    /// Internal rendering seam for deterministic tests: `1` draws the unscaled
    /// baseline. Production always draws the cached darkened artwork.
    var brightness: Double = HerdrGlass.backgroundBrightness
    @Environment(\.herdrHazeActive) private var isActive

    var body: some View {
        if isActive {
            Image(nsImage: brightness == 1 ? HerdrHaze.baselineImage : HerdrHaze.image)
                .resizable()
                .interpolation(.medium)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .opacity(Self.opacity)
                .mask {
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

enum HerdrHaze {
    static let size = CGSize(width: 480, height: 180)

    /// The gradient's flat base color. Kept as authored; the brightness factor
    /// applies after drawing.
    static let base = (red: 0.16, green: 0.11, blue: 0.29)

    /// A radial blob: center and radius as fractions of the artwork size, from
    /// the bottom left, with its color.
    struct Blob {
        var x: CGFloat, y: CGFloat, radiusFraction: CGFloat
        var red: Double, green: Double, blue: Double
    }

    static let blobs: [Blob] = [
        Blob(x: 0.18, y: 0.85, radiusFraction: 0.45, red: 0.52, green: 0.38, blue: 0.87),
        Blob(x: 0.82, y: 0.90, radiusFraction: 0.40, red: 0.56, green: 0.30, blue: 0.55),
        Blob(x: 0.50, y: 0.10, radiusFraction: 0.50, red: 0.14, green: 0.18, blue: 0.42),
    ]

    static let blurSigma: CGFloat = 18

    /// A 480×180 dusk gradient (violet, magenta, indigo), blurred once. Tests
    /// pin ``baselineImage`` and compare the cached ``image``, which is the
    /// baseline with ``HerdrGlass/backgroundBrightness`` applied once.
    @MainActor static let baselineImage: NSImage = artwork(brightness: 1)
    @MainActor static let image: NSImage = artwork(brightness: HerdrGlass.backgroundBrightness)

    @MainActor private static let drawnArtwork: CGImage? = render(size: size)

    @MainActor private static func artwork(brightness: Double) -> NSImage {
        guard let drawnArtwork else { return NSImage(size: size) }
        let image = brightness == 1 ? drawnArtwork : herdrDarkened(drawnArtwork, by: brightness)
        return NSImage(cgImage: image, size: size)
    }

    private static func render(size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: base.red, green: base.green, blue: base.blue, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        for blob in blobs {
            let center = CGPoint(x: size.width * blob.x, y: size.height * blob.y)
            let radius = size.width * blob.radiusFraction
            let color = CGColor(srgbRed: blob.red, green: blob.green, blue: blob.blue, alpha: 1)
            let clear = color.copy(alpha: 0) ?? color
            guard let gradient = CGGradient(colorsSpace: space, colors: [color, clear] as CFArray, locations: [0, 1]) else { continue }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        guard let drawn = context.makeImage() else { return nil }
        let input = CIImage(cgImage: drawn)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: blurSigma)
            .cropped(to: input.extent)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = ciContext.createCGImage(blurred, from: input.extent) else {
            return drawn
        }
        return output
    }
}

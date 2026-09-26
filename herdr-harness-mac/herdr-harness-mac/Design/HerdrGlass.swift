import AppKit
import CoreImage
import SwiftUI

/// Legible glass: the blurred desktop shows softly through the sidebar (base
/// at 80%), the pane (75%) and the HUD (78%). Behind-window blur comes from
/// `NSVisualEffectView`; no private window APIs, no live SwiftUI blur.
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
    /// Render tests only: offscreen captures never include behind-window
    /// blur, so they draw the glass levels over their own stand-in desktop.
    @Entry var herdrGlassDrawsBlur = true
}

/// A glass surface: behind-window blur with `base` at `level` over it, or an
/// opaque `base` when glass is off.
struct HerdrGlassBackground: View {
    let level: Double
    var base: Color = HerdrTheme.windowBackground
    /// Rounded panels (the HUD) mask the blur itself: a SwiftUI clip does not
    /// reliably clip a behind-window view.
    var cornerRadius: CGFloat = 0
    var material: NSVisualEffectView.Material = .underWindowBackground
    @Environment(\.herdrGlassActive) private var isActive
    @Environment(\.herdrGlassDrawsBlur) private var drawsBlur

    var body: some View {
        if isActive {
            ZStack {
                if drawsBlur {
                    HerdrBehindWindowBlur(material: material, cornerRadius: cornerRadius)
                }
                base.opacity(level)
                    .clipShape(.rect(cornerRadius: cornerRadius))
            }
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

/// `NSVisualEffectView` blending with whatever is behind the window. It never
/// takes clicks or drops, and stays active while the window is in the
/// background so the glass does not flatten.
struct HerdrBehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> PassthroughEffectView {
        let view = PassthroughEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.isEmphasized = false
        view.maskImage = cornerRadius > 0 ? Self.mask(radius: cornerRadius) : nil
        return view
    }

    func updateNSView(_ view: PassthroughEffectView, context: Context) {
        if view.material != material { view.material = material }
    }

    /// A stretchable rounded-rect mask with the radius in its cap insets.
    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

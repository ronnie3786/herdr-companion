import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The purple Glass and Haze backgrounds are exactly one 0.80
/// background-brightness factor darker, in encoded sRGB, while their geometry,
/// color inputs, alpha, cropping, glass levels, and Haze fade stay put. The
/// unscaled `baselineImage` seams on `HerdrDusk` and `HerdrHaze` are for these
/// deterministic comparisons only; production never draws them.
@Suite("Glass and Haze background brightness", .serialized)
@MainActor
struct HerdrGlassBackgroundTests {
    private static let factor = HerdrGlass.backgroundBrightness
    private typealias ColorChannels = (red: Double, green: Double, blue: Double)

    // MARK: The factor and the activation matrix

    @Test("The documented background-brightness factor is 0.80")
    func documentedFactor() {
        #expect(HerdrGlass.backgroundBrightness == 0.80)
    }

    @Test("Glass activation keeps its enabled, Reduce Transparency, and appearance rules")
    func activationMatrix() {
        for enabled in [false, true] {
            for reduceTransparency in [false, true] {
                for scheme in [ColorScheme.dark, .light] {
                    let active = HerdrGlass.isActive(
                        enabled: enabled, reduceTransparency: reduceTransparency, colorScheme: scheme
                    )
                    #expect(active == (enabled && !reduceTransparency && scheme == .dark))
                }
            }
        }
    }

    // MARK: Baseline-pinned inputs

    @Test("Dusk gradient stops, glow geometry, blur, and saturation stay as authored")
    func duskInputsPinned() {
        #expect(HerdrDusk.size == CGSize(width: 640, height: 400))
        #expect(HerdrDusk.sky.map(\.location) == [0, 0.55, 1])
        let sky: [(Double, Double, Double)] = [(42, 29, 74), (23, 26, 54), (15, 18, 38)]
        #expect(HerdrDusk.sky.count == sky.count)
        for (stop, pin) in zip(HerdrDusk.sky, sky) {
            #expect(stop.red == pin.0 && stop.green == pin.1 && stop.blue == pin.2)
        }
        let glows: [(CGPoint, CGSize, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (CGPoint(x: 0.20, y: 0.95), CGSize(width: 0.60, height: 0.60), 0.60, 96, 58, 160, 0.65),
            (CGPoint(x: 0.70, y: 1.00), CGSize(width: 0.80, height: 0.70), 0.65, 52, 70, 168, 0.80),
            (CGPoint(x: 0.88, y: 0.06), CGSize(width: 0.55, height: 0.50), 0.60, 214, 120, 178, 0.60),
            (CGPoint(x: 0.12, y: 0.08), CGSize(width: 0.70, height: 0.60), 0.62, 132, 98, 222, 0.80),
        ]
        #expect(HerdrDusk.glows.count == glows.count)
        for (glow, pin) in zip(HerdrDusk.glows, glows) {
            #expect(glow.center == pin.0)
            #expect(glow.radii == pin.1)
            #expect(glow.stop == pin.2)
            #expect(glow.red == pin.3 && glow.green == pin.4 && glow.blue == pin.5)
            #expect(glow.alpha == pin.6)
        }
        #expect(HerdrDusk.blurSigma == 24)
        #expect(HerdrDusk.blurReferenceWidth == 1336)
        #expect(HerdrDusk.saturation == 1.1)
    }

    @Test("Haze color inputs, geometry, blur, height, and opacity stay as authored")
    func hazeInputsPinned() {
        #expect(HerdrHaze.size == CGSize(width: 480, height: 180))
        #expect(HerdrHaze.base == (red: 0.16, green: 0.11, blue: 0.29))
        let blobs: [(CGFloat, CGFloat, CGFloat, Double, Double, Double)] = [
            (0.18, 0.85, 0.45, 0.52, 0.38, 0.87),
            (0.82, 0.90, 0.40, 0.56, 0.30, 0.55),
            (0.50, 0.10, 0.50, 0.14, 0.18, 0.42),
        ]
        #expect(HerdrHaze.blobs.count == blobs.count)
        for (blob, pin) in zip(HerdrHaze.blobs, blobs) {
            #expect(blob.x == pin.0 && blob.y == pin.1 && blob.radiusFraction == pin.2)
            #expect(blob.red == pin.3 && blob.green == pin.4 && blob.blue == pin.5)
        }
        #expect(HerdrHaze.blurSigma == 18)
        #expect(HerdrHazeBand.opacity == 0.06)
        #expect(HerdrHazeBand().height == 280)
    }

    // MARK: Cached artwork

    @Test("The cached dusk is the baseline darkened once, opaque, and still cached")
    func duskImageDarkening() throws {
        let baseline = try Raster(HerdrDusk.baselineImage)
        let darkened = try Raster(HerdrDusk.image)
        #expect(baseline.width == 640 && baseline.height == 400)
        #expect(darkened.width == baseline.width && darkened.height == baseline.height)
        #expect(baseline.isOpaque, "The dusk baseline must be opaque")
        #expect(darkened.isOpaque, "The darkened dusk must be opaque")
        expectScaled(darkened, equals: baseline, by: Self.factor, context: "dusk image")
        #expect(HerdrDusk.image === HerdrDusk.image, "The dusk must stay a cached image")
    }

    @Test("The cached Haze is the baseline darkened once, opaque, and still cached")
    func hazeImageDarkening() throws {
        let baseline = try Raster(HerdrHaze.baselineImage)
        let darkened = try Raster(HerdrHaze.image)
        #expect(baseline.width == 480 && baseline.height == 180)
        #expect(darkened.width == baseline.width && darkened.height == baseline.height)
        #expect(baseline.isOpaque, "The Haze baseline must be opaque")
        #expect(darkened.isOpaque, "The darkened Haze must be opaque")
        expectScaled(darkened, equals: baseline, by: Self.factor, context: "Haze image")
        #expect(HerdrHaze.image === HerdrHaze.image, "The Haze must stay a cached image")
    }

    @Test("The HUD crop is the right half of the whole scene at both brightnesses")
    func hudCrop() throws {
        let crops: [(String, Raster, Raster)] = [
            ("baseline", try Raster(HerdrDusk.baselineImage), try Raster(HerdrDusk.baselineTrailingHalf)),
            ("darkened", try Raster(HerdrDusk.image), try Raster(HerdrDusk.trailingHalf)),
        ]
        for (name, whole, half) in crops {
            #expect(half.width == whole.width / 2 && half.height == whole.height, "\(name) crop size changed")
            #expect(half.isOpaque, "\(name) crop must be opaque")
            var mismatches = 0
            for y in stride(from: 0, to: whole.height, by: 7) {
                for x in stride(from: 0, to: half.width, by: 7) {
                    if half.pixel(x: x, y: y) != whole.pixel(x: x + half.width, y: y) { mismatches += 1 }
                }
            }
            #expect(mismatches == 0, "\(name) crop is not the right half of the whole scene")
        }
    }

    // MARK: Composed surfaces

    @Test("Sidebar, pane, both HUD dusk regions, and Haze on/off darken exactly once")
    func composedSurfaces() throws {
        try expectComposition(
            "sidebar glass",
            baseline: glassScene(brightness: 1, level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground),
            updated: glassScene(brightness: Self.factor, level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground)
        )
        try expectComposition(
            "pane glass",
            baseline: glassScene(brightness: 1, level: HerdrTheme.Glass.pane),
            updated: glassScene(brightness: Self.factor, level: HerdrTheme.Glass.pane)
        )
        try expectComposition(
            "agent HUD trailing-half dusk",
            baseline: glassScene(brightness: 1, level: HerdrTheme.Glass.hud, drawsDusk: true, duskRegion: .trailingHalf),
            updated: glassScene(brightness: Self.factor, level: HerdrTheme.Glass.hud, drawsDusk: true, duskRegion: .trailingHalf)
        )
        try expectComposition(
            "First Mate HUD whole dusk",
            baseline: glassScene(brightness: 1, level: HerdrTheme.Glass.hud, drawsDusk: true, duskRegion: .whole),
            updated: glassScene(brightness: Self.factor, level: HerdrTheme.Glass.hud, drawsDusk: true, duskRegion: .whole)
        )
        try expectComposition(
            "pane with Haze",
            baseline: glassScene(brightness: 1, level: HerdrTheme.Glass.pane, haze: true),
            updated: glassScene(brightness: Self.factor, level: HerdrTheme.Glass.pane, haze: true)
        )
        try expectComposition(
            "pane without Haze",
            baseline: glassScene(brightness: 1, level: HerdrTheme.Glass.pane, haze: false),
            updated: glassScene(brightness: Self.factor, level: HerdrTheme.Glass.pane, haze: false)
        )
    }

    @Test("Haze keeps its soft top-to-bottom fade")
    func hazeFade() throws {
        let size = CGSize(width: 64, height: 280)
        let without = try render(glassScene(brightness: Self.factor, level: HerdrTheme.Glass.pane, haze: false), size: size)
        let with = try render(glassScene(brightness: Self.factor, level: HerdrTheme.Glass.pane, haze: true), size: size)
        func difference(_ y: Int) -> Int {
            let before = without.pixel(x: 32, y: y), after = with.pixel(x: 32, y: y)
            return abs(before.red - after.red) + abs(before.green - after.green) + abs(before.blue - after.blue)
        }
        let top = difference(8), middle = difference(140), bottom = difference(272)
        #expect(top > middle, "Haze must be strongest at the top (\(top) vs \(middle))")
        #expect(middle >= bottom, "Haze must keep fading downward (\(middle) vs \(bottom))")
        #expect(bottom <= 1, "The Haze mask must reach clear at the bottom (\(bottom))")
        #expect(top > 0, "Haze must actually show at the top")
    }

    // MARK: Foreground sentinels

    @Test("Text, accent, and status ink above the darkened background keep their exact colors")
    func foregroundSentinels() throws {
        let tokens: [(String, Color)] = [
            ("primary text", HerdrTheme.primaryText),
            ("accent", HerdrTheme.accent),
            ("working status", HerdrTheme.working),
        ]
        for (name, token) in tokens {
            let expected = rgb(token)
            func sentinel(_ brightness: Double) throws -> Raster.Pixel {
                try render(
                    ZStack {
                        glassScene(brightness: brightness, level: HerdrTheme.Glass.pane)
                        Rectangle().fill(token).frame(width: 16, height: 16)
                    }
                    .environment(\.colorScheme, .dark),
                    size: CGSize(width: 32, height: 32)
                ).pixel(x: 16, y: 16)
            }
            let baseline = try sentinel(1)
            let updated = try sentinel(Self.factor)
            #expect(updated == baseline, "\(name) changed with the darkened background: \(baseline) → \(updated)")
            #expect(close(Double(updated.red), expected.red) && close(Double(updated.green), expected.green) && close(Double(updated.blue), expected.blue),
                    "\(name) rendered \(updated) instead of \(expected)")
        }
    }

    @Test("Darkening keeps alpha and applies exactly once to the base color")
    func darkenedColorPreservesAlpha() throws {
        let translucent = Color(.sRGB, red: 1, green: 0.5, blue: 0.25, opacity: 0.4)
        let darkened = HerdrTheme.resolved(HerdrGlass.darkened(translucent, scheme: .dark), scheme: .dark)
        #expect(close(darkened.redComponent, 0.8))
        #expect(close(darkened.greenComponent, 0.4))
        #expect(close(darkened.blueComponent, 0.2))
        #expect(close(darkened.alphaComponent, 0.4), "Alpha must be preserved")
        let baseline = HerdrTheme.resolved(HerdrGlass.darkened(translucent, scheme: .dark, brightness: 1), scheme: .dark)
        #expect(close(baseline.redComponent, 1))
        #expect(close(baseline.greenComponent, 0.5))
        #expect(close(baseline.alphaComponent, 0.4))
    }

    // MARK: Enabled / disabled / light / Reduce Transparency

    @Test("Glass off, Reduce Transparency, and First Mate light keep the opaque base unchanged")
    func inactiveBranches() throws {
        let entries: [(Bool, Bool, ColorScheme)] = [
            (false, false, .dark),
            (true, true, .dark),
            (false, false, .light),
            (true, false, .light),
        ]
        for (enabled, reduceTransparency, scheme) in entries {
            let active = HerdrGlass.isActive(enabled: enabled, reduceTransparency: reduceTransparency, colorScheme: scheme)
            #expect(!active)
            let raster = try render(
                HerdrGlassBackground(level: HerdrTheme.Glass.pane, base: HerdrTheme.windowBackground)
                    .environment(\.herdrGlassActive, active)
                    .environment(\.colorScheme, scheme),
                size: CGSize(width: 16, height: 16)
            )
            let expected = rgb(HerdrTheme.windowBackground, scheme)
            let pixel = raster.pixel(x: 8, y: 8)
            #expect(raster.isOpaque, "The opaque branch must be opaque")
            #expect(close(Double(pixel.red), expected.red)
                    && close(Double(pixel.green), expected.green)
                    && close(Double(pixel.blue), expected.blue),
                    "Inactive glass rendered \(pixel) instead of the opaque base \(expected)")
        }
    }

    @Test("An active dark surface draws the darkened base over the darkened dusk")
    func activeComposition() throws {
        let size = CGSize(width: 640, height: 400)
        let raster = try render(
            glassScene(brightness: Self.factor, level: HerdrTheme.Glass.pane, drawsDusk: true),
            size: size
        )
        let x = 320, y = 200
        let dusk = try Raster(HerdrDusk.image).pixel(x: x, y: y)
        let base = rgb(HerdrTheme.windowBackground)
        let level = HerdrTheme.Glass.pane
        let pixel = raster.pixel(x: x, y: y)
        let expected = Raster.Pixel(
            red: Int((base.red * Self.factor * level + Double(dusk.red) * (1 - level)).rounded()),
            green: Int((base.green * Self.factor * level + Double(dusk.green) * (1 - level)).rounded()),
            blue: Int((base.blue * Self.factor * level + Double(dusk.blue) * (1 - level)).rounded()),
            alpha: 255
        )
        #expect(close(pixel.red, expected.red, tolerance: 2)
                && close(pixel.green, expected.green, tolerance: 2)
                && close(pixel.blue, expected.blue, tolerance: 2),
                "Active glass rendered \(pixel) instead of \(expected)")
    }

    // MARK: Helpers

    /// The shared production composition with only the internal brightness
    /// seam changed, so baseline and updated differ by the factor alone.
    private func glassScene(
        brightness: Double,
        level: Double,
        base: Color = HerdrTheme.windowBackground,
        drawsDusk: Bool = false,
        duskRegion: HerdrDuskBackdrop.Region = .whole,
        haze: Bool = false
    ) -> some View {
        ZStack(alignment: .top) {
            if !drawsDusk { HerdrDuskBackdrop(brightness: brightness) }
            HerdrGlassBackground(
                level: level, base: base, drawsDusk: drawsDusk, duskRegion: duskRegion, brightness: brightness
            )
            if haze { HerdrHazeBand(brightness: brightness) }
        }
        .environment(\.herdrGlassActive, true)
        .environment(\.herdrHazeActive, haze)
        .environment(\.colorScheme, .dark)
    }

    private func expectComposition(
        _ name: String,
        size: CGSize = CGSize(width: 64, height: 64),
        baseline: some View,
        updated: some View
    ) throws {
        let before = try render(baseline, size: size)
        let after = try render(updated, size: size)
        #expect(before.isOpaque && after.isOpaque, "\(name) compositions must be opaque")
        expectScaled(after, equals: before, by: Self.factor, context: name)
    }

    private func render(_ view: some View, size: CGSize) throws -> Raster {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { throw RasterError.unavailable }
        return try Raster(cgImage)
    }

    private func expectScaled(_ updated: Raster, equals baseline: Raster, by factor: Double, context: String,
                              tolerance: Int = 2) {
        #expect(updated.width == baseline.width && updated.height == baseline.height, "\(context) size changed")
        var mismatches = 0
        var largest = 0
        var first = ""
        for y in 0..<baseline.height {
            for x in 0..<baseline.width {
                let before = baseline.pixel(x: x, y: y)
                let after = updated.pixel(x: x, y: y)
                let channels: [(String, Int, Int)] = [
                    ("red", before.red, after.red), ("green", before.green, after.green), ("blue", before.blue, after.blue),
                ]
                for (channel, from, to) in channels {
                    let expected = Int((Double(from) * factor).rounded())
                    let delta = abs(expected - to)
                    if delta > largest { largest = delta }
                    if delta > tolerance {
                        mismatches += 1
                        if first.isEmpty { first = "\(context) \(channel) at (\(x), \(y)): \(from) → \(to), expected \(expected)" }
                    }
                }
                if before.alpha != after.alpha {
                    mismatches += 1
                    if first.isEmpty { first = "\(context) alpha at (\(x), \(y)): \(before.alpha) → \(after.alpha)" }
                }
            }
        }
        #expect(mismatches == 0, "\(first); largest channel delta was \(largest)")
    }

    private func rgb(_ color: Color, _ scheme: ColorScheme = .dark) -> ColorChannels {
        let value = HerdrTheme.resolved(color, scheme: scheme)
        return (value.redComponent * 255, value.greenComponent * 255, value.blueComponent * 255)
    }

    private func close(_ first: Double, _ second: Double, tolerance: Double = 1.5) -> Bool {
        abs(first - second) <= tolerance
    }

    private func close(_ first: Int, _ second: Int, tolerance: Int = 2) -> Bool {
        abs(first - second) <= tolerance
    }
}

// MARK: Pixel helpers

private enum RasterError: Error {
    case unavailable
}

/// Pixel bytes drawn into one sRGB bitmap, row 0 at the image top.
private struct Raster {
    struct Pixel: Equatable, CustomStringConvertible {
        let red: Int, green: Int, blue: Int, alpha: Int

        var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }
    }

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: NSImage) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RasterError.unavailable
        }
        try self.init(cgImage)
    }

    init(_ cgImage: CGImage) throws {
        let width = cgImage.width, height = cgImage.height
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw RasterError.unavailable }
        bytes = pixels
    }

    var isOpaque: Bool { (0..<(width * height)).allSatisfy { bytes[$0 * 4 + 3] == 255 } }

    func pixel(x: Int, y: Int) -> Pixel {
        let index = (y * width + x) * 4
        return Pixel(
            red: Int(bytes[index]), green: Int(bytes[index + 1]),
            blue: Int(bytes[index + 2]), alpha: Int(bytes[index + 3])
        )
    }
}

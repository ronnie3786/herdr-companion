import SwiftUI
import Testing
import UIKit
@testable import herdr_harness_ios

@Suite("iOS cached dusk and haze", .serialized)
@MainActor
struct HerdrGlassBackgroundTests {
    @Test("Cached artwork hashes pin the iOS Core Image raster")
    func bitmapHashes() throws {
        // Canonical sRGB RGBA8 bytes, not PNG metadata. Changes require visual
        // review on a simulator; never silently accept a new rendering engine.
        // Each iOS release's Core Image gets its own reviewed set. iOS 27 differs
        // from 26 by one level in at most 100 channels of each image.
        let reviewed: [Int: [String]] = [
            26: ["b137ac8653010c22c26fd5a486e87f63b91c47fc6927108561b5257025f30ca0",
                 "55c25e8988e8de0cdda8cff6c793b847a0655c7624b49f9ea6897689df56a1e5",
                 "eb7e1b0bee1e6b83f6c8539cf3c5fb592421c68f1bb856920e70036f4d5d092e",
                 "1865cbac9760af1f78fbf2bce37b6da5faac352c45bc5a629db448dc904e7fe2"],
            27: ["a0a09dceefd42cb2ec1a11365c7ab0c997e473f4cbd7f91d42619a1df524b09e",
                 "b18b6313f9ac5129f09b5d31677fe54e1fdad22e8b68fdcad79bbedf52e5e1f2",
                 "4d4b481ba12ac67df23f74bc98d38ddb77c721dbee60ca3960f3ff409ca30759",
                 "36d1682236b42ef2e03ea1c41711cea4bf4be62910bd5e2832f420de7ebb2540"],
        ]
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let expected = try #require(reviewed[major], "No reviewed dusk rasters for iOS \(major)")
        let hashes = try [HerdrDusk.baselineImage, HerdrDusk.image, HerdrHaze.baselineImage, HerdrHaze.image]
            .map { try ThemeRaster($0).sha256 }
        #expect(hashes == expected)
    }

    @Test("The exact authored artwork is darkened once, with alpha and cache identity intact")
    func brightnessAndCache() throws {
        #expect(HerdrGlass.backgroundBrightness == 0.80)
        #expect(HerdrDusk.image === HerdrDusk.image)
        #expect(HerdrHaze.image === HerdrHaze.image)
        #expect(HerdrDusk.size == CGSize(width: 640, height: 400))
        #expect(HerdrHaze.size == CGSize(width: 480, height: 180))
        #expect(HerdrDusk.sky.map(\.location) == [0, 0.55, 1])
        #expect(HerdrDusk.blurSigma == 24 && HerdrDusk.saturation == 1.1)
        #expect(HerdrHaze.blurSigma == 18 && HerdrHazeBand.opacity == 0.06)
        #expect(HerdrHazeBand().height == 280)
        for (baseline, image) in [(HerdrDusk.baselineImage, HerdrDusk.image), (HerdrHaze.baselineImage, HerdrHaze.image)] {
            let before = try ThemeRaster(baseline), after = try ThemeRaster(image)
            #expect(before.isOpaque && after.isOpaque)
            #expect(before.width == after.width && before.height == after.height)
            let mismatches = before.bytes.indices.filter { i in
                i % 4 == 3 ? before.bytes[i] != after.bytes[i]
                    : abs(Int((Double(before.bytes[i]) * 0.8).rounded()) - Int(after.bytes[i])) > 1
            }
            #expect(mismatches.isEmpty, "Brightness was not applied once: \(mismatches.count) channels differ")
        }
    }

    @Test("Glass off and Reduce Transparency render the unmodified opaque base")
    func opaqueFallbacks() throws {
        for (enabled, reduced) in [(false, false), (true, true), (false, true)] {
            let active = HerdrGlass.isActive(enabled: enabled, reduceTransparency: reduced, colorScheme: .dark)
            #expect(!active)
            let renderer = ImageRenderer(content:
                HerdrGlassBackground(level: 0.8, drawsDusk: true)
                    .environment(\.herdrGlassActive, active)
                    .frame(width: 20, height: 20)
            )
            let raster = try ThemeRaster(#require(renderer.uiImage))
            #expect(raster.isOpaque)
            #expect(raster.bytes[0...3] == [21, 21, 25, 255])
        }
        #expect(HerdrGlass.isActive(enabled: true, reduceTransparency: false, colorScheme: .dark))
    }

    @Test("Haze fades to clear instead of becoming a repeated row effect")
    func hazeFade() throws {
        func raster(haze: Bool) throws -> ThemeRaster {
            let renderer = ImageRenderer(content:
                ZStack(alignment: .top) {
                    HerdrGlassBackground(level: 0.8, drawsDusk: true)
                    HerdrHazeBand()
                }
                .environment(\.herdrGlassActive, true)
                .environment(\.herdrHazeActive, haze)
                .frame(width: 64, height: 280)
            )
            renderer.scale = 1
            return try ThemeRaster(#require(renderer.uiImage))
        }
        let before = try raster(haze: false), after = try raster(haze: true)
        func difference(_ y: Int) -> Int {
            let start = (y * before.width + 32) * 4
            return (start..<start + 3).reduce(0) { $0 + abs(Int(before.bytes[$1]) - Int(after.bytes[$1])) }
        }
        #expect(difference(8) > difference(140))
        #expect(difference(140) >= difference(272))
        #expect(difference(272) <= 1)
    }

    @Test("Dusk controls preserve alpha, defaults and separate phone preference keys")
    func controls() {
        let color = Color(.sRGB, red: 1, green: 0.5, blue: 0.25, opacity: 0.4)
        let result = HerdrGlass.darkened(color, scheme: .dark).resolve(in: EnvironmentValues())
        #expect(abs(result.red - 0.8) < 0.001 && abs(result.green - 0.4) < 0.001)
        #expect(abs(result.blue - 0.2) < 0.001 && abs(result.opacity - 0.4) < 0.001)
        #expect(HerdrAppearancePreferences.glassDefault && HerdrAppearancePreferences.hazeDefault)
        #expect(HerdrAppearancePreferences.glassKey == "herdr.ios.appearance.glass")
        #expect(HerdrAppearancePreferences.hazeKey == "herdr.ios.appearance.haze")
    }
}
